defmodule PostHog.Test.LocalEvaluatorStructs.DerivedObject do
  @moduledoc false
  @derive Jason.Encoder
  defstruct [:payload]
end

defmodule PostHog.Test.LocalEvaluatorStructs.CustomValue do
  @moduledoc false
  defstruct [:payload]

  defimpl Jason.Encoder do
    def encode(value, opts), do: Jason.Encode.value(value.payload, opts)
  end

  defimpl String.Chars do
    def to_string(value), do: Kernel.to_string(value.payload)
  end
end
