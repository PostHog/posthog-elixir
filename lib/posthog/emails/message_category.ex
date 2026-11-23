defmodule PostHog.Emails.MessageCategory do
  @moduledoc """
  A message category that a send with `:template_key` defines in code.

  When code-send categories are enabled for the project and `:template_key` does not match an
  existing saved template, PostHog finds the category by `:key` and creates it when the project
  has none with that key, or restores a deleted one, so no category has to exist in PostHog
  first. `:name` and `:description` apply only when the send creates the category: a send never
  renames a category or changes its description, so change them later in PostHog. A category
  whose key exists must keep its `:type`, or PostHog refuses the send with `category_mismatch`.

  A matching saved template keeps its own category, including when it has none: passing a
  `MessageCategory` for a `:template_key` that matches an uncategorized saved template returns
  `category_mismatch` (for marketing emails, use a different `:template_key`; omit `:category` or
  pass `PostHog.Emails.transactional_category/0` only for transactional emails). When code-send
  categories aren't enabled for the project yet, passing a `MessageCategory` returns HTTP 400
  `categories_not_enabled`, and an older PostHog server rejects `:category` with HTTP 400.

  ## Fields

  - `:key` - identifies the category in the project, such as `"newsletter"`. Required. The
    opt-out and preferences APIs take the same key.
  - `:type` - `:marketing` or `:transactional`. Required. A marketing email honors the
    recipient's opt-outs; a transactional one skips them.
  - `:name` - the name recipients see on their preferences page, such as `"Newsletter"`.
    Required.
  - `:description` - what the category sends, such as `"Monthly product news"`. Optional. It
    applies only when the send creates the category.

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
