defmodule PostHog.Emails.Batch do
  @moduledoc false

  alias PostHog.Emails
  alias PostHog.Emails.BatchEmailResult
  alias PostHog.Emails.BatchError
  alias PostHog.Emails.BatchResult
  alias PostHog.Emails.Error

  @batch_path "/api/messaging/send/email_batch/"
  @status_by_key_path "/api/messaging/emails/status/"
  @max_recipients 100
  @max_body_bytes 4 * 1024 * 1024
  @min_timeout_ms 45_000
  @unconfirmed_codes ["idempotency_key_in_flight", "delivery_unavailable", "api_error"]
  @recipient_fields [:to, :distinct_id, :idempotency_key, :template_data]
  @template_fields [:recipients, :max_retries, :template_id, :template_data]
  @code_fields [
    :recipients,
    :max_retries,
    :template_key,
    :subject,
    :html,
    :text,
    :from,
    :reply_to,
    :sensitive,
    :tracking,
    :capture_engagement
  ]
  @send_each "send each email the batch didn't queue with PostHog.Emails.send/2 and its recipient's idempotency_key."

  @spec batch(PostHog.supervisor_name(), [Emails.batch_option()] | map()) ::
          {:ok, BatchResult.t()} | {:error, BatchError.t() | Error.t()}
  def batch(name, options) do
    with {:ok, run} <- prepare(options),
         {:ok, connection} <- Emails.connect(name, :send) do
      connection = %{connection | nothing_done: "the rest of the batch wasn't sent"}

      run
      |> send_chunks(connection)
      |> finish()
    end
  rescue
    exception -> {:error, Emails.unexpected(exception, "Sending the batch failed unexpectedly.")}
  end

  defp prepare(options) do
    with {:ok, options} <- options(options),
         {:ok, form} <- form(options),
         :ok <- refuse_fields(options, form),
         {:ok, recipients} <- fetch_recipients(options),
         {:ok, max_retries} <- Emails.max_retries(options),
         {:ok, shared} <- Emails.content(Map.drop(options, [:recipients, :max_retries])),
         {:ok, shared} <- Emails.encode(shared, options),
         {:ok, members} <- members(recipients, options) do
      {:ok, split(members, shared, max_retries)}
    end
  end

  defp options(options) when is_map(options), do: {:ok, normalize(options)}

  defp options(options) when is_list(options) do
    if Keyword.keyword?(options),
      do: {:ok, normalize(options)},
      else: invalid("invalid_form", "batch takes a keyword list or a map of options.", nil)
  end

  defp options(_options),
    do: invalid("invalid_form", "batch takes a keyword list or a map of options.", nil)

  defp normalize(options), do: options |> Enum.reject(&Emails.left_out?/1) |> Map.new()

  defp form(%{template_id: _, template_key: _}), do: invalid_form()
  defp form(%{template_id: _}), do: {:ok, :template}
  defp form(%{template_key: _}), do: {:ok, :code}
  defp form(_options), do: invalid_form()

  defp invalid_form,
    do:
      invalid(
        "invalid_form",
        "Send a batch with either template_id, or template_key with subject and html or text.",
        nil
      )

  defp refuse_fields(options, form) do
    {fields, form_field} =
      if form == :template,
        do: {@template_fields, "template_id"},
        else: {@code_fields, "template_key"}

    case options |> Map.keys() |> Enum.sort() |> Enum.find(&(&1 not in fields)) do
      nil ->
        :ok

      field ->
        {:error,
         Error.new(
           "invalid_form",
           "A batch with #{form_field} doesn't take #{field}, so no email was sent.",
           field: to_string(field),
           why:
             "A batch takes no scheduled_at, cc, bcc or attachments, and each recipient's to, distinct_id and idempotency_key go in recipients.",
           fix: "Remove #{field}, or send each email with PostHog.Emails.send/2."
         )}
    end
  end

  defp fetch_recipients(%{recipients: [_ | _] = recipients}), do: {:ok, recipients}

  defp fetch_recipients(%{recipients: []}),
    do:
      invalid("invalid_recipients", "recipients must hold at least one recipient.", "recipients")

  defp fetch_recipients(_options),
    do:
      invalid(
        "invalid_recipients",
        "recipients must be a list of recipients, each a map with to.",
        "recipients"
      )

  defp members(recipients, options), do: members(recipients, options, 0, %{}, [])

  defp members([], _options, _index, _keys, members), do: {:ok, Enum.reverse(members)}

  defp members([recipient | recipients], options, index, keys, members) do
    with {:ok, member} <- member(recipient, index, options),
         :ok <- unique_key(member, keys) do
      keys = Map.put(keys, member.idempotency_key, index)
      members(recipients, options, index + 1, keys, [member | members])
    end
  end

  defp member(recipient, index, options) do
    with {:ok, recipient} <- recipient(recipient, index),
         :ok <- known_fields(recipient, index),
         :ok <- at(Emails.check_recipient(recipient), index),
         {:ok, key} <- at(Emails.idempotency_key(recipient), index),
         {:ok, wire} <- wire(recipient, key, index, options),
         {:ok, wire} <- at(Emails.encode(wire, options), index) do
      {:ok, %{index: index, to: recipient.to, idempotency_key: key, wire: wire}}
    end
  end

  defp recipient(recipient, _index) when is_map(recipient), do: {:ok, normalize(recipient)}

  defp recipient([{_key, _value} | _] = recipient, index) do
    if Keyword.keyword?(recipient), do: {:ok, normalize(recipient)}, else: not_a_recipient(index)
  end

  defp recipient(_recipient, index), do: not_a_recipient(index)

  defp not_a_recipient(index),
    do:
      invalid(
        "invalid_recipient",
        "recipients[#{index}] must be a map with to, such as %{to: \"user@example.com\"}.",
        "recipients__#{index}"
      )

  defp known_fields(recipient, index) do
    case recipient |> Map.keys() |> Enum.sort() |> Enum.find(&(&1 not in @recipient_fields)) do
      nil ->
        :ok

      field ->
        invalid(
          "invalid_form",
          "recipients[#{index}] takes only to, distinct_id, idempotency_key and template_data, not #{field}.",
          "recipients__#{index}__#{field}"
        )
    end
  end

  defp wire(recipient, key, index, options) do
    wire = recipient |> Map.take([:to, :distinct_id]) |> Map.put(:idempotency_key, key)

    case Map.fetch(recipient, :template_data) do
      :error ->
        {:ok, wire}

      {:ok, _data} when not is_map_key(options, :template_id) ->
        invalid(
          "invalid_form",
          "recipients[#{index}] has template_data, but a batch with template_key sends the same content to every recipient. Send personalized content with a template_id batch or with PostHog.Emails.send/2.",
          "recipients__#{index}__template_data"
        )

      {:ok, data} when is_map(data) ->
        {:ok, Map.put(wire, :message_data, data)}

      {:ok, _data} ->
        invalid(
          "invalid_template_data",
          "recipients[#{index}]: template_data must be a map.",
          "recipients__#{index}__template_data"
        )
    end
  end

  defp unique_key(%{idempotency_key: key, index: index}, keys) do
    case Map.fetch(keys, key) do
      :error ->
        :ok

      {:ok, first} ->
        invalid(
          "invalid_idempotency_key",
          "recipients[#{index}] has the same idempotency_key as recipients[#{first}]. Give each recipient its own key.",
          "recipients__#{index}__idempotency_key"
        )
    end
  end

  defp at({:error, %Error{} = error}, index) do
    field =
      if error.field, do: "recipients__#{index}__#{error.field}", else: "recipients__#{index}"

    {:error, %{error | message: "recipients[#{index}]: #{error.message}", field: field}}
  end

  defp at(ok, _index), do: ok

  defp invalid(code, message, field), do: {:error, Error.new(code, message, field: field)}

  defp split(members, shared, max_retries) do
    head = binary_part(shared, 0, byte_size(shared) - 1) <> ~s(,"recipients":[)
    empty = byte_size(head) + 2

    run = %{
      members: Map.new(members, &{&1.index, &1}),
      chunks: [],
      results: %{},
      maybe_queued: MapSet.new(),
      warnings: [],
      max_retries: max_retries
    }

    {run, current, _size} =
      Enum.reduce(members, {run, [], empty}, fn member, {run, current, size} ->
        wire_size = byte_size(member.wire)

        cond do
          empty + wire_size > @max_body_bytes ->
            {set(run, member.index, "failed", error: too_large()), current, size}

          current == [] ->
            {run, [member], empty + wire_size}

          length(current) == @max_recipients or size + 1 + wire_size > @max_body_bytes ->
            {add_chunk(run, head, current), [member], empty + wire_size}

          true ->
            {run, [member | current], size + 1 + wire_size}
        end
      end)

    run = if current == [], do: run, else: add_chunk(run, head, current)
    %{run | chunks: Enum.reverse(run.chunks)}
  end

  defp add_chunk(run, head, reversed_members) do
    members = Enum.reverse(reversed_members)
    body = IO.iodata_to_binary([head, Enum.map_join(members, ",", & &1.wire), "]}"])
    %{run | chunks: [%{body: body, indices: Enum.map(members, & &1.index)} | run.chunks]}
  end

  defp too_large do
    Error.new(
      "content_too_large",
      "This recipient's email is larger than one batch request takes, so it wasn't sent.",
      name: :validation_error,
      fix: "Send this recipient's email with PostHog.Emails.send/2.",
      field: "recipients"
    )
  end

  defp send_chunks(run, connection) do
    post = %{connection | timeout_ms: max(connection.timeout_ms, @min_timeout_ms)}
    headers = [{"content-type", "application/json"} | Emails.headers(connection)]

    run.chunks
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, run}, fn {chunk, position}, {:ok, run} ->
      with :ok <- running(run, connection, position),
           {:ok, run} <- post(run, post, headers, chunk, 0) do
        {:cont, {:ok, run}}
      else
        {:closed, run, error} ->
          {:halt, {:error, run, error}}

        {:error, run, error} ->
          {:halt, {:error, run |> stop(position, error) |> read_lost(connection), error}}
      end
    end)
  end

  defp running(run, connection, position) do
    case Emails.check_running(connection) do
      :ok -> :ok
      {:error, error} -> {:closed, skip_from(run, position, error), error}
    end
  end

  defp post(run, connection, headers, chunk, attempt) do
    reply = Emails.request(connection, :post, @batch_path, headers, chunk.body)

    with {:error, run, error} <- answer(run, chunk, reply) do
      case Emails.retry_delay_ms(error, attempt, run.max_retries || connection.max_retries) do
        nil ->
          {:error, run, error}

        delay_ms ->
          connection.sleep.(delay_ms)
          post(run, connection, headers, chunk, attempt + 1)
      end
    end
  end

  defp answer(run, chunk, {:error, %Error{code: "network_error"} = error}),
    do: {:error, lost(run, chunk), error}

  defp answer(run, _chunk, {:error, error}), do: {:error, run, error}

  defp answer(run, chunk, {:ok, status, fields, _retry_after_ms}) when status in 200..299 do
    case fields["results"] do
      slots when is_list(slots) and length(slots) == length(chunk.indices) ->
        run =
          chunk.indices
          |> Enum.zip(slots)
          |> Enum.reduce(run, fn {index, slot}, run -> settle(run, index, slot) end)

        {:ok, add_warnings(run, Emails.warnings(fields["warnings"]))}

      _slots ->
        {:error, lost(run, chunk),
         Error.new(
           "api_error",
           "PostHog answered the batch without a result for each recipient.",
           status_code: status
         )}
    end
  end

  defp answer(run, chunk, {:ok, status, fields, retry_after_ms}) do
    {:error, error} =
      Emails.reply_error({:ok, status, request_fields(fields, status, chunk), retry_after_ms})

    run = if status >= 500, do: lost(run, chunk), else: run
    {:error, run, error}
  end

  defp request_fields(fields, status, chunk) do
    fields = fields |> Map.reject(fn {_key, value} -> is_nil(value) end) |> remap_attr(chunk)

    fields =
      if status == 404,
        do:
          Map.merge(
            %{
              "code" => "not_found",
              "detail" => "PostHog found no batch send for this request, so no email was sent.",
              "why" =>
                "The template doesn't exist, or batch sends are off for this project or this PostHog version.",
              "fix" => "Check template_id, or #{@send_each}"
            },
            fields
          ),
        else: fields

    if fields["code"] == "batch_unavailable",
      do: Map.put(fields, "fix", "Until batch sends are on for the project, #{@send_each}"),
      else: fields
  end

  defp remap_attr(%{"attr" => "recipients__" <> rest} = fields, chunk) do
    {position, tail} =
      case String.split(rest, "__", parts: 2) do
        [position, tail] -> {position, "__" <> tail}
        [position] -> {position, ""}
      end

    count = length(chunk.indices)

    attr =
      cond do
        not Regex.match?(~r/\A[0-9]+\z/, position) ->
          fields["attr"]

        byte_size(position) > byte_size(Integer.to_string(count)) or
            String.to_integer(position) >= count ->
          "recipients"

        true ->
          "recipients__#{Enum.at(chunk.indices, String.to_integer(position))}#{tail}"
      end

    %{fields | "attr" => attr}
  end

  defp remap_attr(fields, _chunk), do: fields

  defp settle(run, index, slot) do
    slot = if is_map(slot), do: slot, else: %{}
    message_id = Emails.text(slot["message_id"])

    if is_nil(slot["error"]) and slot["status"] == "queued" and message_id do
      run
      |> confirm(index)
      |> set(index, "queued", message_id: message_id, replayed: slot["replayed"] == true)
    else
      answer = slot_error(slot["error"], message_id)

      cond do
        MapSet.member?(run.maybe_queued, index) ->
          earlier = run.results[index]

          set(run, index, "unconfirmed",
            message_id: message_id || earlier.message_id,
            error: earlier.error,
            later_error: answer
          )

        answer.code in @unconfirmed_codes ->
          run
          |> maybe_queued(index)
          |> set(index, "unconfirmed", message_id: message_id, error: answer)

        true ->
          set(run, index, "failed", message_id: message_id, error: answer)
      end
    end
  end

  defp slot_error(%{} = error, message_id) do
    code = Emails.text(error["code"]) || "api_error"
    status = if is_integer(error["status"]), do: error["status"]

    Error.new(code, Emails.text(error["detail"]) || "PostHog didn't queue this email: #{code}.",
      status_code: status,
      message_id: message_id
    )
  end

  defp slot_error(_error, message_id) do
    Error.new(
      "api_error",
      "PostHog answered without a readable result for this email, so it may still go out.",
      message_id: message_id
    )
  end

  defp lost(run, chunk) do
    Enum.reduce(chunk.indices, run, fn index, run ->
      message_id = run.results[index] && run.results[index].message_id

      run
      |> maybe_queued(index)
      |> set(index, "unconfirmed", message_id: message_id, error: unconfirmed(message_id))
    end)
  end

  defp unconfirmed(message_id) do
    Error.new(
      "delivery_unavailable",
      "PostHog didn't confirm this email, so it may still go out. Send it again with the same idempotency_key within 24 hours, so it goes out once.",
      name: :service_unavailable,
      message_id: message_id
    )
  end

  defp stop(run, position, error) do
    later = if is_integer(error.status_code) and error.status_code < 500, do: error

    run =
      run.chunks
      |> Enum.at(position)
      |> Map.fetch!(:indices)
      |> Enum.reduce(run, fn index, run ->
        cond do
          not MapSet.member?(run.maybe_queued, index) ->
            set(run, index, "failed", error: error)

          later ->
            earlier = run.results[index]

            set(run, index, "unconfirmed",
              message_id: earlier.message_id,
              error: earlier.error,
              later_error: later
            )

          true ->
            run
        end
      end)

    skip_from(
      run,
      position + 1,
      Error.new(
        "not_attempted",
        "An earlier request of the batch failed, so the SDK sent nothing for this recipient."
      )
    )
  end

  defp skip_from(run, position, error) do
    for chunk <- Enum.drop(run.chunks, position), index <- chunk.indices, reduce: run do
      run -> set(run, index, "not_attempted", error: error)
    end
  end

  defp read_lost(run, connection) do
    run.maybe_queued
    |> Enum.sort()
    |> Enum.filter(fn index -> is_nil(run.results[index].message_id) end)
    |> Enum.reduce_while(run, fn index, run ->
      case read_by_key(connection, run.members[index].idempotency_key) do
        {:ok, status} ->
          {:cont, run |> confirm(index) |> set(index, "queued", message_id: status.id)}

        {:error, %Error{status_code: 404}} ->
          {:cont, run}

        {:error, _error} ->
          {:halt, run}
      end
    end)
  end

  defp read_by_key(connection, key) do
    path = @status_by_key_path <> "?" <> URI.encode_query(%{"idempotency_key" => key})

    connection
    |> Emails.request(:get, path, Emails.headers(connection), nil)
    |> Emails.parse_status_reply()
  end

  defp maybe_queued(run, index), do: %{run | maybe_queued: MapSet.put(run.maybe_queued, index)}
  defp confirm(run, index), do: %{run | maybe_queued: MapSet.delete(run.maybe_queued, index)}

  defp set(run, index, status, fields) do
    member = run.members[index]

    result =
      struct!(
        BatchEmailResult,
        [index: index, to: member.to, idempotency_key: member.idempotency_key, status: status] ++
          fields
      )

    %{run | results: Map.put(run.results, index, result)}
  end

  defp add_warnings(run, warnings) do
    Enum.reduce(warnings, run, fn warning, run ->
      if warning in run.warnings, do: run, else: %{run | warnings: run.warnings ++ [warning]}
    end)
  end

  defp finish({:ok, run}) do
    result = %BatchResult{results: outcome(run), warnings: run.warnings}
    Emails.log_warnings(result)
    {:ok, result}
  end

  defp finish({:error, run, error}) do
    failure = BatchError.new(error, outcome(run), run.warnings)
    Emails.log_warnings(failure)
    {:error, failure}
  end

  defp outcome(run), do: Enum.map(0..(map_size(run.members) - 1), &run.results[&1])
end
