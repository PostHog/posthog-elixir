defmodule PostHog.Emails.Batch do
  @moduledoc false

  alias PostHog.Emails
  alias PostHog.Emails.BatchEmailResult
  alias PostHog.Emails.BatchError
  alias PostHog.Emails.BatchResult
  alias PostHog.Emails.Error

  @batch_path "/api/messaging/send/email_batch/"
  @max_recipients 100
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
      {:ok, run, connection} -> run |> send_batch(connection) |> finish()
      {:error, error} -> {:error, error}
    end
  end

  defp start(name, options) do
    with {:ok, run} <- prepare(options),
         {:ok, connection} <- Emails.connect(name, :send) do
      {:ok, run, %{connection | nothing_done: "the batch wasn't sent"}}
    end
  rescue
    exception -> {:error, Emails.unexpected(exception, "Sending the batch failed unexpectedly.")}
  end

  defp prepare(options) do
    with {:ok, options} <- options(options),
         :ok <- refuse_fields(options),
         {:ok, recipients} <- fetch_recipients(options),
         :ok <- within_limit(recipients),
         {:ok, max_retries} <- Emails.max_retries(options),
         {:ok, shared} <- Emails.content(Map.drop(options, [:recipients, :max_retries])),
         {:ok, shared} <- Emails.encode(shared, options),
         {:ok, members} <- members(recipients, options) do
      {:ok, run(members, shared, max_retries)}
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

  defp within_limit(recipients) when length(recipients) <= @max_recipients, do: :ok

  defp within_limit(_recipients) do
    {:error,
     Error.new(
       "invalid_recipients",
       "A batch takes at most #{@max_recipients} recipients, so no email was sent.",
       field: "recipients",
       fix: "Split the recipients into batches of #{@max_recipients} or fewer."
     )}
  end

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

  defp run(members, shared, max_retries) do
    head = binary_part(shared, 0, byte_size(shared) - 1) <> ~s(,"recipients":[)

    %{
      members: Map.new(members, &{&1.index, &1}),
      body: IO.iodata_to_binary([head, Enum.map_join(members, ",", & &1.wire), "]}"]),
      results: %{},
      warnings: [],
      max_retries: max_retries,
      lost?: false
    }
  end

  defp send_batch(run, connection) do
    post = %{connection | timeout_ms: max(connection.timeout_ms, @min_timeout_ms)}
    headers = [{"content-type", "application/json"} | Emails.headers(connection)]
    max_retries = run.max_retries || connection.max_retries
    attempt_once = &attempt(&1, &2, post, headers)

    case Emails.with_retries(post, max_retries, run, attempt_once) do
      {:ok, run} -> {:ok, run}
      {:error, error, run} -> {:error, run, closed_after_send(error, run, connection)}
    end
  end

  defp closed_after_send(%Error{code: "client_closed"} = error, run, connection) do
    if Enum.any?(Map.values(run.results), &(&1.status == "unconfirmed")) do
      %{
        error
        | message:
            "The PostHog instance #{inspect(connection.name)} stopped during the call, so the SDK sent no retry. PostHog may have queued some of the emails, and each result says which."
      }
    else
      error
    end
  end

  defp closed_after_send(error, _run, _connection), do: error

  defp attempt(run, attempt, connection, headers) do
    run = %{
      run
      | lost?: run.lost? or Enum.any?(Map.values(run.results), &(&1.status == "unconfirmed"))
    }

    reply = Emails.request(connection, :post, @batch_path, headers, run.body)
    answer(run, attempt, reply)
  rescue
    exception ->
      {:error, Emails.unexpected(exception, "Sending the batch failed unexpectedly."),
       all(run, "unconfirmed", unconfirmed())}
  end

  defp answer(run, 0, {:error, %Error{code: "client_closed"} = error}),
    do: {:error, error, all(run, "failed", error)}

  defp answer(run, _attempt, {:error, %Error{code: "network_error"} = error}),
    do: {:error, error, all(run, "unconfirmed", unconfirmed())}

  defp answer(run, _attempt, {:error, error}) when map_size(run.results) > 0,
    do: {:error, error, run}

  defp answer(run, _attempt, {:error, error}),
    do: {:error, error, all(run, "unconfirmed", error)}

  defp answer(run, _attempt, {:ok, status, fields, _retry_after_ms})
       when status in 200..299 do
    case fields["results"] do
      slots when is_list(slots) and length(slots) == map_size(run.members) ->
        run =
          slots
          |> Enum.with_index()
          |> Enum.reduce(run, fn {slot, index}, run -> settle(run, index, slot) end)

        {:ok, add_warnings(run, Emails.warnings(fields["warnings"]))}

      _slots ->
        error =
          Error.new(
            "api_error",
            "PostHog answered the batch without a result for each recipient.",
            status_code: status
          )

        {:error, error, all(run, "unconfirmed", error)}
    end
  end

  defp answer(run, _attempt, {:ok, status, fields, retry_after_ms}) do
    {:error, error} =
      Emails.reply_error({:ok, status, request_fields(fields, status), retry_after_ms})

    uncertain? =
      status >= 500 or
        (status != 429 and Emails.text(fields["code"]) in @unconfirmed_codes)

    cond do
      uncertain? ->
        {:error, error, all(run, "unconfirmed", error)}

      run.lost? ->
        {:error, refused_after_loss(error), all(run, "unconfirmed", refused_after_loss(error))}

      true ->
        {:error, error, all(run, "failed", error)}
    end
  end

  defp request_fields(fields, status) do
    fields = Map.reject(fields, fn {_key, value} -> is_nil(value) end)

    fields = Map.merge(defaults(status), fields)

    if fields["code"] == "batch_unavailable",
      do: Map.put(fields, "fix", "Until batch sends are on for the project, #{@send_each}"),
      else: fields
  end

  defp defaults(404) do
    %{
      "code" => "not_found",
      "detail" => "PostHog found no batch send for this request, so no email was sent.",
      "why" =>
        "The template doesn't exist, or batch sends are off for this project or this PostHog version.",
      "fix" => "Check template_id, or #{@send_each}"
    }
  end

  defp defaults(413) do
    %{
      "code" => "content_too_large",
      "detail" => "The batch is larger than PostHog takes in one request, so no email was sent.",
      "fix" => "Split the recipients into smaller batches, or make each email's content smaller."
    }
  end

  defp defaults(_status), do: %{}

  defp settle(run, index, slot) do
    slot = if is_map(slot), do: slot, else: %{}
    message_id = Emails.text(slot["message_id"])

    if is_nil(slot["error"]) and slot["status"] == "queued" and message_id do
      set(run, index, "queued", message_id: message_id, replayed: slot["replayed"] == true)
    else
      answer = slot_error(slot["error"], message_id)

      cond do
        answer.code in @unconfirmed_codes ->
          set(run, index, "unconfirmed", message_id: message_id, error: answer)

        run.lost? ->
          set(run, index, "unconfirmed",
            message_id: message_id,
            error: refused_after_loss(answer)
          )

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

  defp refused_after_loss(error) do
    %{
      error
      | message:
          "PostHog refused a retry with #{error.code}, but its answer to an earlier try was lost, so the email may still go out."
    }
  end

  defp unconfirmed do
    Error.new(
      "delivery_unavailable",
      "PostHog didn't confirm this email, so it may still go out.",
      name: :service_unavailable
    )
  end

  defp all(run, status, error),
    do: Enum.reduce(Map.keys(run.members), run, &set(&2, &1, status, error: error))

  defp set(run, index, "unconfirmed", fields),
    do: put_result(run, index, "unconfirmed", Keyword.update!(fields, :error, &resend_same_key/1))

  defp set(run, index, status, fields), do: put_result(run, index, status, fields)

  defp resend_same_key(error),
    do: %{
      error
      | fix:
          "Send this email again, unchanged, with the same idempotency_key within 24 hours of the key's first use, so it goes out once."
    }

  defp put_result(run, index, status, fields) do
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
