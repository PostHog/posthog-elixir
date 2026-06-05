defmodule PostHog.Error do
  @moduledoc """
  Generic PostHog SDK error.

  ## Fields

  - `:message` - human-readable error message.
  """

  @typedoc "Exception raised for SDK errors that are not tied to an HTTP response."
  @type t() :: %__MODULE__{message: String.t()}

  defexception [:message]
end

defmodule PostHog.UnexpectedResponseError do
  @moduledoc """
  PostHog error that includes a response from the API, either full or partial.

  ## Fields

  - `:message` - human-readable error message.
  - `:response` - API response data that caused the error.
  """

  @typedoc "Exception raised when PostHog returns a response the SDK cannot handle."
  @type t() :: %__MODULE__{response: any(), message: String.t()}

  defexception [:response, :message]

  @impl Exception
  def message(%__MODULE__{response: response, message: message}) do
    "#{message}\n\n#{inspect(response, pretty: true)}"
  end
end
