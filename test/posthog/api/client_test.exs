defmodule PostHog.API.ClientTest do
  use ExUnit.Case, async: true

  alias PostHog.API.Client

  test "client/2 sets the posthog-elixir User-Agent" do
    %Client{client: req} = Client.client("phc_test", "https://us.i.posthog.com")

    assert req.headers["user-agent"] == [Client.user_agent()]
  end

  test "request fallback continues uncompressed when compression step raises" do
    parent = self()

    req =
      Req.new(
        body: [123_456],
        compress_body: true,
        adapter: fn req ->
          send(
            parent,
            {:request, Req.Request.fetch_option(req, :compress_body),
             Req.Request.get_header(req, "content-encoding")}
          )

          {req, Req.Response.new(status: 200, body: %{})}
        end
      )

    assert {:ok, %{status: 200}} = Client.request_with_compression_fallback_for_test(req)
    assert_received {:request, {:ok, false}, []}
  end

  test "request fallback does not catch adapter exceptions" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    req =
      Req.new(
        body: "ok",
        compress_body: true,
        adapter: fn _req ->
          Agent.update(calls, &(&1 + 1))
          raise RuntimeError, "request failed"
        end
      )

    assert_raise RuntimeError, "request failed", fn ->
      Client.request_with_compression_fallback_for_test(req)
    end

    assert Agent.get(calls, & &1) == 1
  end

  test "request fallback preserves normal compression" do
    parent = self()

    req =
      Req.new(
        body: "hello",
        compress_body: true,
        adapter: fn req ->
          send(parent, {:request, Req.Request.get_header(req, "content-encoding"), req.body})
          {req, Req.Response.new(status: 200, body: %{})}
        end
      )

    assert {:ok, %{status: 200}} = Client.request_with_compression_fallback_for_test(req)
    assert_received {:request, ["gzip"], gzipped_body}
    assert :zlib.gunzip(gzipped_body) == "hello"
  end
end
