defmodule PostHog.Test.NullableJSONValue do
  @moduledoc false
  defstruct [:value, :private]
end

defimpl Jason.Encoder, for: PostHog.Test.NullableJSONValue do
  def encode(value, opts), do: Jason.Encode.value(value.value, opts)
end
