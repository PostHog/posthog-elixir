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
  @per_recipient_fields [:to, :distinct_id, :idempotency_key]
  @excluded_fields [:scheduled_at, :cc, :bcc, :attachments]
  @send_each "send each email the batch didn't queue with PostHog.Emails.send/2 and its recipient's idempotency_key."

  @spec batch(PostHog.supervisor_name(), [Emails.batch_option()] | map()) ::
          {:ok, BatchResult.t()} | {:error, BatchError.t() | Error.t()}
  def batch(name, options) do
    case start(name, options) do
      {:ok, run, connection} -> run |> send_chunks(connection) |> read_ids(connection) |> finish()
      {:error, error} -> {:error, error}
    end
  end

  defp start(name, options) do
    with {:ok, run} <- prepare(options),
         {:ok, connection} <- Emails.connect(name, :send) do
      {:ok, run, %{connection | nothing_done: "the rest of the batch wasn't sent"}}
    end
  rescue
    exception -> {:error, Emails.unexpected(exception, "Sending the batch failed unexpectedly.")}
  end

  defp prepare(options) do
    with {:ok, options} <- options(options),
         :ok <- refuse_fields(options),
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

  defp refuse_fields(options) do
    case Enum.find(@per_recipient_fields ++ @excluded_fields, &Map.has_key?(options, &1)) do
      nil ->
        :ok

      field when field in @per_recipient_fields ->
        refuse_field(
          field,
          "Each recipient's to, distinct_id and idempotency_key go in recipients.",
          "Move #{field} into each recipient in recipients."
        )

      field ->
        refuse_field(
          field,
          "A batch takes no scheduled_at, cc, bcc or attachments.",
          "Remove #{field}, or send each email with PostHog.Emails.send/2."
        )
    end
  end

  defp refuse_field(field, why, fix) do
    {:error,
     Error.new("invalid_form", "A batch doesn't take #{field}, so no email was sent.",
       field: to_string(field),
       why: why,
       fix: fix
     )}
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
      head: head,
      chunks: [],
      results: %{},
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
            {run, [member.index], empty + wire_size}

          length(current) == @max_recipients or size + 1 + wire_size > @max_body_bytes ->
            {add_chunk(run, current), [member.index], empty + wire_size}

          true ->
            {run, [member.index | current], size + 1 + wire_size}
        end
      end)

    run = if current == [], do: run, else: add_chunk(run, current)
    %{run | chunks: Enum.reverse(run.chunks)}
  end

  defp add_chunk(run, reversed_chunk),
    do: %{run | chunks: [Enum.reverse(reversed_chunk) | run.chunks]}

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
    max_retries = run.max_retries || connection.max_retries

    run.chunks
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, run}, fn {chunk, position}, {:ok, run} ->
      body =
        IO.iodata_to_binary([run.head, Enum.map_join(chunk, ",", &run.members[&1].wire), "]}"])

      attempt_once = &attempt(&1, &2, post, headers, chunk, body)

      case Emails.with_retries(post, max_retries, run, attempt_once) do
        {:ok, run} ->
          {:cont, {:ok, run}}

        {:error, error, run} ->
          {:halt, {:error, stop(run, position, error), error}}
      end
    end)
  end

  defp attempt(run, attempt, connection, headers, chunk, body) do
    reply = Emails.request(connection, :post, @batch_path, headers, body)
    answer(run, chunk, attempt, reply)
  rescue
    exception ->
      {:error, Emails.unexpected(exception, "Sending the batch failed unexpectedly."),
       lost(run, chunk)}
  end

  defp answer(run, chunk, 0, {:error, %Error{code: "client_closed"} = error}),
    do: {:error, error, skip(run, chunk, error)}

  defp answer(run, chunk, _attempt, {:error, %Error{code: "network_error"} = error}),
    do: {:error, error, lost(run, chunk)}

  defp answer(run, _chunk, _attempt, {:error, error}), do: {:error, error, run}

  defp answer(run, chunk, _attempt, {:ok, status, fields, _retry_after_ms})
       when status in 200..299 do
    case fields["results"] do
      slots when is_list(slots) and length(slots) == length(chunk) ->
        run =
          chunk
          |> Enum.zip(slots)
          |> Enum.reduce(run, fn {index, slot}, run -> settle(run, index, slot) end)

        {:ok, add_warnings(run, Emails.warnings(fields["warnings"]))}

      _slots ->
        {:error,
         Error.new(
           "api_error",
           "PostHog answered the batch without a result for each recipient.",
           status_code: status
         ), lost(run, chunk)}
    end
  end

  defp answer(run, chunk, _attempt, {:ok, status, fields, retry_after_ms}) do
    {:error, error} =
      Emails.reply_error({:ok, status, request_fields(fields, status, chunk), retry_after_ms})

    cond do
      Emails.text(fields["code"]) in @unconfirmed_codes ->
        {:error, error, lost(run, chunk, error)}

      status >= 500 ->
        {:error, error, lost(run, chunk)}

      true ->
        {:error, error, refused(run, chunk, error)}
    end
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

    count = length(chunk)

    attr =
      cond do
        not Regex.match?(~r/\A[0-9]+\z/, position) ->
          fields["attr"]

        byte_size(position) > byte_size(Integer.to_string(count)) or
            String.to_integer(position) >= count ->
          "recipients"

        true ->
          "recipients__#{Enum.at(chunk, String.to_integer(position))}#{tail}"
      end

    %{fields | "attr" => attr}
  end

  defp remap_attr(fields, _chunk), do: fields

  defp settle(run, index, slot) do
    slot = if is_map(slot), do: slot, else: %{}
    message_id = Emails.text(slot["message_id"])

    if is_nil(slot["error"]) and slot["status"] == "queued" and message_id do
      set(run, index, "queued", message_id: message_id, replayed: slot["replayed"] == true)
    else
      answer = slot_error(slot["error"], message_id)

      cond do
        unconfirmed?(run, index) ->
          update(run, index, message_id: message_id, later_error: answer)

        answer.code in @unconfirmed_codes ->
          set(run, index, "unconfirmed", message_id: message_id, error: answer)

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

  defp lost(run, chunk, error \\ unconfirmed()) do
    Enum.reduce(chunk, run, fn index, run ->
      if unconfirmed?(run, index),
        do: update(run, index, later_error: error),
        else: set(run, index, "unconfirmed", error: error)
    end)
  end

  defp refused(run, chunk, error) do
    chunk
    |> Enum.filter(&unconfirmed?(run, &1))
    |> Enum.reduce(run, &update(&2, &1, later_error: error))
  end

  defp unconfirmed do
    Error.new(
      "delivery_unavailable",
      "PostHog didn't confirm this email, so it may still go out. Send it again with the same idempotency_key within 24 hours, so it goes out once.",
      name: :service_unavailable
    )
  end

  defp stop(run, position, error) do
    run =
      run.chunks
      |> Enum.at(position)
      |> Enum.reject(&Map.has_key?(run.results, &1))
      |> Enum.reduce(run, &set(&2, &1, "failed", error: error))

    skipped =
      if error.code == "client_closed",
        do: error,
        else:
          Error.new(
            "not_attempted",
            "An earlier request of the batch failed, so the SDK sent nothing for this recipient."
          )

    skip(run, run.chunks |> Enum.drop(position + 1) |> Enum.concat(), skipped)
  end

  defp skip(run, indices, error),
    do: Enum.reduce(indices, run, &set(&2, &1, "not_attempted", error: error))

  defp read_ids({:ok, run}, connection) do
    case read_ids(run, connection, nil) do
      {run, nil} -> {:ok, run}
      {run, closed} -> {:error, run, closed}
    end
  end

  defp read_ids({:error, run, error}, connection) do
    {run, error} = read_ids(run, connection, error)
    {:error, run, error}
  end

  defp read_ids(run, connection, error) do
    0..(map_size(run.members) - 1)
    |> Enum.filter(&match?(%{status: "unconfirmed", message_id: nil}, run.results[&1]))
    |> Enum.reduce_while({run, error}, fn index, {run, error} ->
      case read_by_key(connection, run.members[index].idempotency_key) do
        {:ok, status} ->
          {:cont, {update(run, index, message_id: status.id), error}}

        {:error, %Error{status_code: 404}} ->
          {:cont, {run, error}}

        {:error, %Error{code: "client_closed"} = closed} ->
          {:halt, {run, closed}}

        {:error, _error} ->
          {:halt, {run, error}}
      end
    end)
  end

  defp read_by_key(connection, key) do
    path = @status_by_key_path <> "?" <> URI.encode_query(%{"idempotency_key" => key})

    connection
    |> Emails.request(:get, path, Emails.headers(connection), nil)
    |> Emails.parse_status_reply()
  rescue
    exception ->
      {:error,
       Emails.unexpected(exception, "Reading a batch email by its key failed unexpectedly.")}
  end

  defp unconfirmed?(run, index), do: match?(%{status: "unconfirmed"}, run.results[index])

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

  defp update(run, index, fields),
    do: %{run | results: Map.update!(run.results, index, &struct!(&1, fields))}

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
