defmodule PostHog.API.ClientTest do
  use ExUnit.Case, async: true

  alias PostHog.API.Client

  test "client/2 sets the posthog-elixir User-Agent" do
    %Client{client: req} = Client.client("phc_test", "https://us.i.posthog.com")

    assert req.headers["user-agent"] == [Client.user_agent()]
  end

  for {case_name, response_or_exception, expected} <- [
        {"transport timeout", %Req.TransportError{reason: :timeout}, true},
        {"transport closed", %Req.TransportError{reason: :closed}, true},
        {"http error", %Req.HTTPError{reason: :closed}, false},
        {"http status response", %Req.Response{status: 503}, false}
      ] do
    test "flags retry policy handles #{case_name}" do
      assert Client.retry_flags_request?(
               %Req.Request{},
               unquote(Macro.escape(response_or_exception))
             ) == unquote(expected)
    end
  end

  for {retry_count, expected_delay} <- [{0, 300}, {1, 600}, {2, 1200}] do
    test "flags retry delay for retry count #{retry_count}" do
      assert Client.flags_retry_delay(unquote(retry_count)) == unquote(expected_delay)
    end
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

    assert {:ok, %{status: 200}} = Client.request(req, :post, "/", [])
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
      Client.request(req, :post, "/", [])
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

    assert {:ok, %{status: 200}} = Client.request(req, :post, "/", [])
    assert_received {:request, ["gzip"], gzipped_body}
    assert :zlib.gunzip(gzipped_body) == "hello"
  end
end
