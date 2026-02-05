defmodule PostHog.UUID do
  @moduledoc false

  import Bitwise

  # Minimal UUID v4 generator without external deps.
  def uuid4() do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    # set version to 4 (0100)
    c = (c &&& 0x0FFF) ||| 0x4000

    # set variant to 10xx
    d = (d &&& 0x3FFF) ||| 0x8000

    encode(a, b, c, d, e)
  end

  defp encode(a, b, c, d, e) do
    [a, b, c, d, e]
    |> Enum.map(&Integer.to_string(&1, 16))
    |> then(fn [a_s, b_s, c_s, d_s, e_s] ->
      # pad segments to proper lengths
      a_p = String.pad_leading(a_s, 8, "0")
      b_p = String.pad_leading(b_s, 4, "0")
      c_p = String.pad_leading(c_s, 4, "0")
      d_p = String.pad_leading(d_s, 4, "0")
      e_p = String.pad_leading(e_s, 12, "0")

      Enum.join([a_p, b_p, c_p, d_p, e_p], "-")
    end)
  end
end
