defmodule PostHog.Emails.Error do
  @moduledoc """
  PostHog did not queue the email or return its status, or the SDK could not tell whether it did.

  Branch on `:code`, PostHog's stable error code, or on `:name`, a coarse category of the
  failure. The message never contains the secret key or the request body.

  ## Fields

  - `:name` - the category, one of `t:name/0`.
  - `:code` - PostHog's error code, such as `"quota_limited"` or `"recipient_suppressed"`, or an
    SDK code: `"missing_secret_key"`, `"missing_app_host"`, `"client_disabled"`,
    `"client_closed"`, `"network_error"`, `"api_error"` (an answer without a code),
    `"unexpected_error"`, `"too_many_attachments"` or `"message_too_large"` for files that
    make the email too large, which the SDK checks before any request and PostHog checks again,
    `"attachment_upload_failed"` when the storage refused an upload, `"scheduling_requires_cloud"`
    for a send with `:scheduled_at` to a host that is not PostHog Cloud, `"schedule_not_confirmed"`
    when PostHog accepted a send with `:scheduled_at` without confirming its time,
    `"content_too_large"` for a batch recipient whose email is larger than one batch request
    takes, `"delivery_unavailable"` for a batch recipient PostHog didn't confirm, which may still
    go out, `"not_attempted"` for a batch recipient the SDK didn't send because an earlier request
    of the batch failed, or an `"invalid_*"` code for an option the SDK refused before any
    request.
  - `:message` - human-readable message.
  - `:status_code` - the HTTP status, when PostHog answered, or the storage's for
    `"attachment_upload_failed"`.
  - `:why` and `:fix` - why PostHog refused the email and how to fix it, when it said.
  - `:docs_url` - a link to the docs for the error, when PostHog sent one.
  - `:field` - the option the error is about, such as `"to"`.
  - `:retry_after_ms` - how long PostHog, or the storage, asked the client to wait before it
    sends again.
  - `:message_id` - the message ID of an email PostHog accepted, when the error is about that
    email, as for `"schedule_not_confirmed"`.
  """

  @typedoc "A coarse category of the failure."
  @type name() ::
          :validation_error
          | :missing_api_key
          | :invalid_permission
          | :not_found
          | :concurrent_idempotent_requests
          | :invalid_idempotent_request
          | :rate_limit_exceeded
          | :monthly_quota_exceeded
          | :service_unavailable
          | :application_error

  @typedoc "An email request that failed."
  @type t() :: %__MODULE__{
          name: name(),
          code: String.t(),
          message: String.t(),
          status_code: pos_integer() | nil,
          why: String.t() | nil,
          fix: String.t() | nil,
          docs_url: String.t() | nil,
          field: String.t() | nil,
          retry_after_ms: non_neg_integer() | nil,
          message_id: String.t() | nil
        }

  defexception [
    :name,
    :code,
    :message,
    :status_code,
    :why,
    :fix,
    :docs_url,
    :field,
    :retry_after_ms,
    :message_id
  ]

  @doc false
  @spec new(String.t(), String.t(), keyword()) :: t()
  def new(code, message, fields \\ []) do
    status_code = fields[:status_code]
    struct!(%__MODULE__{name: name(status_code, code), code: code, message: message}, fields)
  end

  defp name(_status, "missing_secret_key"), do: :missing_api_key
  # The storage answered, so its status says nothing about PostHog's key or scope.
  defp name(_status, "attachment_upload_failed"), do: :application_error
  defp name(401, _code), do: :missing_api_key
  defp name(nil, "network_error"), do: :service_unavailable
  defp name(nil, "invalid_" <> _), do: :validation_error

  defp name(nil, code)
       when code in ["too_many_attachments", "message_too_large", "scheduling_requires_cloud"],
       do: :validation_error

  defp name(nil, _code), do: :application_error
  defp name(400, _code), do: :validation_error
  defp name(403, _code), do: :invalid_permission
  defp name(404, _code), do: :not_found
  defp name(409, "template_outdated"), do: :validation_error
  defp name(409, _code), do: :concurrent_idempotent_requests
  # The template send route also answers 422 for send checks such as recipient_suppressed.
  defp name(422, "idempotency_key_reused"), do: :invalid_idempotent_request
  defp name(422, _code), do: :validation_error
  defp name(429, "quota_limited"), do: :monthly_quota_exceeded
  defp name(429, _code), do: :rate_limit_exceeded
  defp name(503, _code), do: :service_unavailable
  defp name(_status, _code), do: :application_error
end

defmodule PostHog.Emails.BatchError do
  @moduledoc """
  A request of `PostHog.Emails.batch/2` failed as a whole, so the batch stopped.

  The fields of `PostHog.Emails.Error` describe that request's error. `:results` holds every
  recipient: those of earlier requests as PostHog answered them, those of the failed request as
  `"failed"`, or `"unconfirmed"` where an earlier attempt may have queued them, and the rest as
  `"not_attempted"`.

  ## Fields

  - `:name`, `:code`, `:message`, `:status_code`, `:why`, `:fix`, `:docs_url`, `:field`,
    `:retry_after_ms` and `:message_id` - as on `PostHog.Emails.Error`.
  - `:results` - one `PostHog.Emails.BatchEmailResult` per recipient, in the order of
    `:recipients`.
  - `:warnings` - the warnings PostHog returned about the requests that went out, each once.
  """

  alias PostHog.Emails.Error

  @typedoc "A batch that stopped at a request that failed as a whole."
  @type t() :: %__MODULE__{
          name: Error.name(),
          code: String.t(),
          message: String.t(),
          status_code: pos_integer() | nil,
          why: String.t() | nil,
          fix: String.t() | nil,
          docs_url: String.t() | nil,
          field: String.t() | nil,
          retry_after_ms: non_neg_integer() | nil,
          message_id: String.t() | nil,
          results: [PostHog.Emails.BatchEmailResult.t()],
          warnings: [PostHog.Emails.Warning.t()]
        }

  defexception [
    :name,
    :code,
    :message,
    :status_code,
    :why,
    :fix,
    :docs_url,
    :field,
    :retry_after_ms,
    :message_id,
    results: [],
    warnings: []
  ]

  @doc false
  @spec new(Error.t(), [PostHog.Emails.BatchEmailResult.t()], [PostHog.Emails.Warning.t()]) ::
          t()
  def new(%Error{} = error, results, warnings) do
    fields = error |> Map.from_struct() |> Map.delete(:__exception__)
    struct!(__MODULE__, Map.merge(fields, %{results: results, warnings: warnings}))
  end
end
