defmodule PostHog.API.FunAdapter do
  @moduledoc false

  # Req deprecated function adapters, so tests pass their function through this module adapter.
  def put(request, fun) when is_function(fun, 1) do
    request
    |> Req.merge(adapter: __MODULE__)
    |> Req.Request.put_private(__MODULE__, fun)
  end

  def run(request), do: Req.Request.get_private(request, __MODULE__).(request)
end
