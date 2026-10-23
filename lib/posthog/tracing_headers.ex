defmodule PostHog.TracingHeaders do
  @moduledoc false

  @max_header_value_length 1000
  @control_chars_regex ~r/[\x{00}-\x{1F}\x{7F}-\x{9F}]/u

  def sanitize_value(value) when is_binary(value) do
    value =
      value
      |> String.replace(@control_chars_regex, "")
      |> String.trim()
      |> String.slice(0, @max_header_value_length)

    if value == "", do: nil, else: value
  end
end
