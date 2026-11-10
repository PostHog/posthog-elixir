defmodule PostHog.Emails.Error do
  @moduledoc """
  PostHog did not queue the email or return its status, or the SDK could not tell whether it did.

  Branch on `:code`, PostHog's stable error code, or on `:name`, a coarse category of the
  failure. The message never contains the secret key or the request body.

  ## Fields

  - `:name` - the category, one of `t:name/0`.
  - `:code` - PostHog's error code, such as `"quota_limited"`, `"recipient_suppressed"` or
    `"category_mismatch"`, or an SDK code: `"missing_secret_key"`, `"missing_app_host"`,
    `"client_disabled"`, `"client_closed"`, `"network_error"`, `"api_error"` (an answer without
    a code), `"unexpected_error"`, or an `"invalid_*"` code for an option the SDK refused before
    any request.
  - `:message` - human-readable message.
  - `:status_code` - the HTTP status, when PostHog answered.
  - `:why` and `:fix` - why PostHog refused the email and how to fix it, when it said.
  - `:docs_url` - a link to the docs for the error, when PostHog sent one.
  - `:field` - the option the error is about, such as `"to"`.
  - `:retry_after_ms` - how long PostHog asked the client to wait before it sends again.
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
          retry_after_ms: non_neg_integer() | nil
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
    :retry_after_ms
  ]

  @doc false
  @spec new(String.t(), String.t(), keyword()) :: t()
  def new(code, message, fields \\ []) do
    status_code = fields[:status_code]
    struct!(%__MODULE__{name: name(status_code, code), code: code, message: message}, fields)
  end

  defp name(_status, "missing_secret_key"), do: :missing_api_key
  defp name(401, _code), do: :missing_api_key
  defp name(nil, "network_error"), do: :service_unavailable
  defp name(nil, "invalid_" <> _), do: :validation_error
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
