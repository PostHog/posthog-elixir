defmodule PostHog.Emails.MessageCategory do
  @moduledoc """
  A message category that a send with `:template_key` defines in code.

  PostHog finds the category by `:key` and creates it when the project has none with that key,
  so no category has to exist in PostHog first. A send that changes `:name` or `:description`
  updates the category. A category whose key exists must keep its `:type`, or PostHog refuses
  the send with `category_mismatch`.

  ## Fields

  - `:key` - identifies the category in the project, such as `"newsletter"`. Required. The
    opt-out and preferences APIs take the same key.
  - `:type` - `:marketing` or `:transactional`. Required. A marketing email honors the
    recipient's opt-outs; a transactional one skips them.
  - `:name` - the name recipients see on their preferences page, such as `"Newsletter"`.
    Required.
  - `:description` - what the category sends, such as `"Monthly product news"`. Optional.
    Left `nil`, the send keeps the category's current description; `""` clears it.

  ## Examples

      %PostHog.Emails.MessageCategory{
        key: "newsletter",
        type: :marketing,
        name: "Newsletter",
        description: "Monthly product news"
      }
  """

  @typedoc "Whether a category's emails are marketing or transactional."
  @type type() :: :marketing | :transactional

  @typedoc "A message category defined in code."
  @type t() :: %__MODULE__{
          key: String.t(),
          type: type(),
          name: String.t(),
          description: String.t() | nil
        }

  @enforce_keys [:key, :type, :name]
  defstruct [:key, :type, :name, :description]
end
