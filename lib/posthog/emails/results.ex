defmodule PostHog.Emails.Warning do
  @moduledoc """
  A warning PostHog returned with a queued email or batch. `PostHog.Emails.send/2` and
  `PostHog.Emails.batch/2` also log it.
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

defmodule PostHog.Emails.BatchEmailResult do
  @moduledoc """
  What happened to one recipient of `PostHog.Emails.batch/2`.

  ## Fields

  - `:index` - the recipient's position in `:recipients`, from 0.
  - `:to` - the recipient's email address.
  - `:idempotency_key` - the recipient's key, given or made by the SDK.
  - `:status` - one of:
    - `"queued"`: PostHog accepted the email. Read its status with `PostHog.Emails.get/2` to see
      whether it went out.
    - `"failed"`: PostHog didn't queue the email, and `:error` says why.
    - `"unconfirmed"`: the SDK can't tell whether PostHog queued the email, such as after a lost
      answer. It may still go out. Send it again, unchanged, with the same `:idempotency_key`
      within 24 hours of the key's first use, so it goes out once; its error's `:fix` says the
      same.
    - `"not_attempted"`: an earlier request of the batch failed, or the PostHog instance
      stopped, so the SDK sent nothing for this recipient.
  - `:message_id` - the email's message ID, when PostHog named it in its answer.
  - `:replayed` - `true` when an earlier send with the same key had already queued the email, so
    no new email was sent.
  - `:error` - a `PostHog.Emails.Error` that says why the email is not `"queued"`. For an
    `"unconfirmed"` email, its `:code` is `"delivery_unavailable"`, `"idempotency_key_in_flight"`
    or `"api_error"`.
  - `:later_error` - for an `"unconfirmed"` email, what a retry in the same call answered, which
    describes only that retry.
  """

  @typedoc "What happened to one recipient of a batch."
  @type t() :: %__MODULE__{
          index: non_neg_integer(),
          to: String.t(),
          idempotency_key: String.t(),
          status: String.t(),
          message_id: String.t() | nil,
          replayed: boolean(),
          error: PostHog.Emails.Error.t() | nil,
          later_error: PostHog.Emails.Error.t() | nil
        }

  @enforce_keys [:index, :to, :idempotency_key, :status]
  defstruct [
    :index,
    :to,
    :idempotency_key,
    :status,
    message_id: nil,
    replayed: false,
    error: nil,
    later_error: nil
  ]
end

defmodule PostHog.Emails.BatchResult do
  @moduledoc """
  The answer to `PostHog.Emails.batch/2`.

  ## Fields

  - `:results` - one `PostHog.Emails.BatchEmailResult` per recipient, in the order of
    `:recipients`.
  - `:warnings` - the warnings PostHog returned about the batch, each once. `batch/2` also logs
    them.
  """

  @typedoc "The answer to a batch."
  @type t() :: %__MODULE__{
          results: [PostHog.Emails.BatchEmailResult.t()],
          warnings: [PostHog.Emails.Warning.t()]
        }

  @enforce_keys [:results]
  defstruct [:results, warnings: []]
end
