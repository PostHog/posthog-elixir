defmodule PostHog.API.ClientTest do
  use ExUnit.Case, async: true

  alias PostHog.API.Client

  test "client/2 sets the posthog-elixir User-Agent" do
    %Client{client: req} = Client.client("phc_test", "https://us.i.posthog.com")

    assert req.headers["user-agent"] == [Client.user_agent()]
  end

  test "request fallback retries without compression when compressed request raises" do
    req = Req.new(compress_body: true)
    {:ok, calls} = Agent.start_link(fn -> [] end)

    request_fun = fn req ->
      Agent.update(calls, &[Req.Request.fetch_option(req, :compress_body) | &1])

      case Req.Request.fetch_option(req, :compress_body) do
        {:ok, true} -> raise RuntimeError, "gzip failed"
        {:ok, false} -> {:ok, %{status: 200, body: %{}}}
      end
    end

    assert {:ok, %{status: 200}} =
             Client.request_with_compression_fallback_for_test(req, request_fun)

    assert Agent.get(calls, &Enum.reverse/1) == [{:ok, true}, {:ok, false}]
  end

  test "request fallback reraises when compression is disabled" do
    req = Req.new(compress_body: false)

    assert_raise RuntimeError, "request failed", fn ->
      Client.request_with_compression_fallback_for_test(req, fn _req ->
        raise RuntimeError, "request failed"
      end)
    end
  end
end
