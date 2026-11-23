defmodule PostHog.Emails.Warning do
  @moduledoc """
  A warning PostHog returned with a queued email. `PostHog.Emails.send/2` also logs it.
  """

  @typedoc "A warning about a queued email."
  @type t() :: %__MODULE__{code: String.t(), message: String.t(), fix: String.t() | nil}

  @enforce_keys [:code, :message]
  defstruct [:code, :message, :fix]
end

defmodule PostHog.Emails.SendResult do
  @moduledoc """
  The accepted email. A result means PostHog queued or scheduled the email, not that it was
  delivered.

  ## Fields

  - `:id` - the accepted email's message ID. Read its status with `PostHog.Emails.get/2`.
  - `:replayed` - `true` when PostHog had already accepted this idempotency key and returned the
    first send's result.
  - `:warnings` - the warnings PostHog returned with the email.
  - `:status` - `"scheduled"` when the email waits for its `:scheduled_at`, `"queued"` when it
    goes out now.
  - `:scheduled_at` - when a scheduled email goes out, in UTC, to the millisecond. `nil` for an
    email that goes out now, also when the `:scheduled_at` of the send had already passed when
    PostHog accepted it.
  """

  @typedoc "An accepted email."
  @type t() :: %__MODULE__{
          id: String.t(),
          replayed: boolean(),
          warnings: [PostHog.Emails.Warning.t()],
          status: String.t(),
          scheduled_at: DateTime.t() | nil
        }

  @enforce_keys [:id]
  defstruct [:id, replayed: false, warnings: [], status: "queued", scheduled_at: nil]
end

defmodule PostHog.Emails.Status do
  @moduledoc """
  What happened to an email that `PostHog.Emails.send/2` queued.

  ## Fields

  - `:id` - the message ID that `send/2` returned.
  - `:status` - one of `"scheduled"`, `"queued"`, `"sent"`, `"failed"`, `"delivered"`,
    `"bounced"` or `"complained"`. Later versions of PostHog can return values this list does not
    have yet.
    - `"scheduled"`: the email waits for the `:scheduled_at` of its send.
    - `"queued"`: the email waits to go out.
    - `"sent"`: PostHog handed the email to the email provider.
    - `"failed"`: the email was not sent, and `:reason` says why.
    - `"delivered"`: the recipient's mail server accepted the email.
    - `"bounced"` and `"complained"`: the recipient's mail provider reported them after delivery.
  - `:created_at` - when PostHog queued the email.
  - `:status_at` - when the email reached its current status.
  - `:reason` - why a failed email was not sent, such as `"provider_error"` or
    `"recipient_suppressed"`, or the bounce type of a bounced email: `"hard"`, `"soft"` or
    `"unknown"`. `nil` otherwise.
  """

  @typedoc "The status of a queued email."
  @type t() :: %__MODULE__{
          id: String.t(),
          status: String.t(),
          created_at: DateTime.t(),
          status_at: DateTime.t(),
          reason: String.t() | nil
        }

  @enforce_keys [:id, :status, :created_at, :status_at]
  defstruct [:id, :status, :created_at, :status_at, :reason]
end
