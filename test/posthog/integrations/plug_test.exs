defmodule PostHog.Integrations.PlugTest do
  # This unfortunately will be flaky in async mode until
  # https://github.com/erlang/otp/issues/9997 is fixed
  use PostHog.Case, async: false

  @supervisor_name __MODULE__
  @moduletag capture_log: true, config: [capture_level: :error, supervisor_name: @supervisor_name]

  setup {LoggerHandlerKit.Arrange, :ensure_per_handler_translation}
  setup :setup_supervisor
  setup :setup_logger_handler

  @tracing_header_cases [
    {"x-posthog-distinct-id", :distinct_id},
    {"x-posthog-session-id", :"$session_id"},
    {"x-posthog-window-id", :"$window_id"}
  ]

  @sanitization_cases [
    {"trims whitespace", "  value-123  ", "value-123"},
    {"removes C0 and C1 control characters", "\0  user\n-\u0085123\r\t  ", "user-123"},
    {"omits empty sanitized values", "\n\t", nil},
    {"truncates long values", String.duplicate("a", 1_001), String.duplicate("a", 1_000)}
  ]

  defmodule MyRouter do
    use Plug.Router
    require Logger

    plug(PostHog.Integrations.Plug)
    plug(:match)
    plug(:dispatch)

    forward("/", to: LoggerHandlerKit.Plug)
  end

  test "sets relevant context" do
    conn =
      :get
      |> Plug.Test.conn("https://posthog.com/foo?bar=10")
      |> Plug.Conn.put_req_header("x-posthog-distinct-id", "user-123")
      |> Plug.Conn.put_req_header("x-posthog-session-id", "session-123")
      |> Plug.Conn.put_req_header("x-posthog-window-id", "window-123")
      |> Plug.Conn.put_req_header("user-agent", "Mozilla/5.0")

    assert PostHog.Integrations.Plug.call(conn, nil)

    assert PostHog.Context.get(:all) == %{
             "$current_url": "https://posthog.com/foo?bar=10",
             "$host": "posthog.com",
             "$ip": "127.0.0.1",
             "$pathname": "/foo",
             "$request_method": "GET",
             "$user_agent": "Mozilla/5.0",
             distinct_id: "user-123",
             "$session_id": "session-123",
             "$window_id": "window-123"
           }
  end

  describe "conn_to_context/1" do
    for {header_name, context_key} <- @tracing_header_cases do
      test "extracts #{header_name} into #{inspect(context_key)}" do
        conn =
          :get
          |> Plug.Test.conn("https://posthog.com/foo")
          |> Plug.Conn.put_req_header(unquote(header_name), "value-123")

        assert PostHog.Integrations.Plug.conn_to_context(conn)[unquote(context_key)] ==
                 "value-123"
      end
    end

    test "extracts tracing headers case-insensitively and request metadata" do
      conn =
        :post
        |> Plug.Test.conn("https://posthog.com/foo?bar=10")
        |> Map.update!(:req_headers, fn headers ->
          [
            {"X-PostHog-Distinct-ID", "user-123"},
            {"X-PostHog-Session-ID", "session-123"},
            {"X-PostHog-Window-ID", "window-123"},
            {"User-Agent", "Mozilla/5.0"}
            | headers
          ]
        end)

      assert PostHog.Integrations.Plug.conn_to_context(conn) == %{
               "$current_url": "https://posthog.com/foo?bar=10",
               "$host": "posthog.com",
               "$ip": "127.0.0.1",
               "$pathname": "/foo",
               "$request_method": "POST",
               "$user_agent": "Mozilla/5.0",
               distinct_id: "user-123",
               "$session_id": "session-123",
               "$window_id": "window-123"
             }
    end

    test "omits missing tracing headers and user agent" do
      conn = Plug.Test.conn(:get, "https://posthog.com/foo")

      assert PostHog.Integrations.Plug.conn_to_context(conn) == %{
               "$current_url": "https://posthog.com/foo",
               "$host": "posthog.com",
               "$ip": "127.0.0.1",
               "$pathname": "/foo",
               "$request_method": "GET"
             }
    end

    for {label, raw_value, expected_value} <- @sanitization_cases do
      test "sanitizes tracing header values: #{label}" do
        conn =
          :get
          |> Plug.Test.conn("https://posthog.com/foo")
          |> Plug.Conn.put_req_header("x-posthog-distinct-id", unquote(raw_value))

        context = PostHog.Integrations.Plug.conn_to_context(conn)

        if is_nil(unquote(expected_value)) do
          refute Map.has_key?(context, :distinct_id)
        else
          assert context.distinct_id == unquote(expected_value)
        end
      end
    end

    test "keeps user agent value unchanged" do
      user_agent = "\0  Mozilla/5.0\n  "

      conn =
        :get
        |> Plug.Test.conn("https://posthog.com/foo")
        |> Plug.Conn.put_req_header("user-agent", user_agent)

      assert PostHog.Integrations.Plug.conn_to_context(conn)[:"$user_agent"] == user_agent
    end

    test "keeps request method unchanged" do
      conn = Plug.Test.conn("\0  weird\n  ", "https://posthog.com/foo")

      assert PostHog.Integrations.Plug.conn_to_context(conn)[:"$request_method"] == conn.method
    end

    test "uses the first header value when duplicates are present" do
      conn =
        :get
        |> Plug.Test.conn("https://posthog.com/foo")
        |> Map.put(:req_headers, [
          {"x-posthog-window-id", "window-123"},
          {"x-posthog-window-id", "ignored"}
        ])

      assert PostHog.Integrations.Plug.conn_to_context(conn)[:"$window_id"] == "window-123"
    end
  end

  test "explicit capture properties override context from headers" do
    conn =
      :post
      |> Plug.Test.conn("https://posthog.com/foo")
      |> Plug.Conn.put_req_header("x-posthog-distinct-id", "header-user")
      |> Plug.Conn.put_req_header("x-posthog-session-id", "header-session")
      |> Plug.Conn.put_req_header("x-posthog-window-id", "header-window")
      |> Plug.Conn.put_req_header("user-agent", "Header Agent")

    PostHog.Integrations.Plug.call(conn, nil)

    PostHog.capture(@supervisor_name, "case tested", %{
      distinct_id: "explicit-user",
      "$session_id": "explicit-session",
      "$window_id": "explicit-window",
      "$request_method": "EXPLICIT",
      "$user_agent": "Explicit Agent"
    })

    assert [event] = all_captured(@supervisor_name)

    assert %{
             distinct_id: "explicit-user",
             properties: %{
               "$session_id": "explicit-session",
               "$window_id": "explicit-window",
               "$request_method": "EXPLICIT",
               "$user_agent": "Explicit Agent"
             }
           } = event
  end

  setup do
    # We use this call to initialize key ownership. LoggerHandlerKit will share
    # ownership to PostHog.Ownership server, but the key has to be initialized.
    all_captured(@supervisor_name)
  end

  describe "Bandit" do
    test "tracing context is attached to exceptions", %{handler_ref: ref} do
      plug_error_with_headers(:exception, Bandit, MyRouter, [
        {"x-posthog-distinct-id", "exception-user"},
        {"x-posthog-session-id", "exception-session"},
        {"x-posthog-window-id", "exception-window"},
        {"user-agent", "Exception Agent"}
      ])

      LoggerHandlerKit.Assert.assert_logged(ref)
      LoggerHandlerKit.Assert.assert_logged(ref)

      assert [event] = all_captured(@supervisor_name)

      assert %{
               event: "$exception",
               distinct_id: "exception-user",
               properties: %{
                 distinct_id: "exception-user",
                 "$session_id": "exception-session",
                 "$window_id": "exception-window",
                 "$request_method": "GET",
                 "$user_agent": "Exception Agent"
               }
             } = event
    end

    test "context is attached to exceptions", %{handler_ref: ref} do
      LoggerHandlerKit.Act.plug_error(:exception, Bandit, MyRouter)
      LoggerHandlerKit.Assert.assert_logged(ref)
      LoggerHandlerKit.Assert.assert_logged(ref)

      assert [event] = all_captured(@supervisor_name)

      assert %{
               event: "$exception",
               uuid: _,
               properties: properties
             } = event

      if pre_19?() do
        assert %{
                 "$current_url": "http://localhost/exception",
                 "$host": "localhost",
                 "$ip": "127.0.0.1",
                 "$pathname": "/exception",
                 "$lib": "posthog-elixir",
                 "$lib_version": _,
                 "$exception_list": [
                   %{
                     type: "RuntimeError",
                     value: "oops",
                     mechanism: %{handled: false, type: "generic"},
                     stacktrace: %{type: "raw", frames: _frames}
                   }
                 ]
               } = properties
      else
        assert %{
                 "$current_url": "http://localhost/exception",
                 "$host": "localhost",
                 "$ip": "127.0.0.1",
                 "$pathname": "/exception",
                 "$lib": "posthog-elixir",
                 "$lib_version": _,
                 "$exception_list": [
                   %{
                     mechanism: %{handled: true, type: "generic"},
                     type: "** (RuntimeError) oops",
                     value: "** (RuntimeError) oops\n" <> _
                   },
                   %{
                     type: "RuntimeError",
                     value: "oops",
                     mechanism: %{handled: false, type: "generic"},
                     stacktrace: %{type: "raw", frames: _frames}
                   }
                 ]
               } = properties
      end
    end

    test "context is attached to throws", %{handler_ref: ref} do
      LoggerHandlerKit.Act.plug_error(:throw, Bandit, MyRouter)
      LoggerHandlerKit.Assert.assert_logged(ref)
      LoggerHandlerKit.Assert.assert_logged(ref)

      assert [event] = all_captured(@supervisor_name)

      assert %{
               event: "$exception",
               uuid: _,
               properties: properties
             } = event

      if pre_19?() do
        assert %{
                 "$current_url": "http://localhost/throw",
                 "$host": "localhost",
                 "$ip": "127.0.0.1",
                 "$pathname": "/throw",
                 "$lib": "posthog-elixir",
                 "$lib_version": _,
                 "$exception_list": [
                   %{
                     type: "** (throw) \"catch!\"",
                     value: "\"catch!\"",
                     mechanism: %{handled: false, type: "generic"},
                     stacktrace: %{type: "raw", frames: _frames}
                   }
                 ]
               } = properties
      else
        assert %{
                 "$current_url": "http://localhost/throw",
                 "$host": "localhost",
                 "$ip": "127.0.0.1",
                 "$pathname": "/throw",
                 "$lib": "posthog-elixir",
                 "$lib_version": _,
                 "$exception_list": [
                   %{
                     mechanism: %{handled: true, type: "generic"},
                     type: "** (throw) \"catch!\"",
                     value: "** (throw) \"catch!\"\n" <> _
                   },
                   %{
                     type: "** (throw) \"catch!\"",
                     value: "\"catch!\"",
                     mechanism: %{handled: false, type: "generic"},
                     stacktrace: %{type: "raw", frames: _frames}
                   }
                 ]
               } = properties
      end
    end

    test "context is attached to exit", %{handler_ref: ref} do
      LoggerHandlerKit.Act.plug_error(:exit, Bandit, MyRouter)
      LoggerHandlerKit.Assert.assert_logged(ref)
      LoggerHandlerKit.Assert.assert_logged(ref)

      assert [event] = all_captured(@supervisor_name)

      assert %{
               event: "$exception",
               uuid: _,
               properties: properties
             } = event

      if pre_19?() do
        assert %{
                 "$current_url": "http://localhost/exit",
                 "$host": "localhost",
                 "$ip": "127.0.0.1",
                 "$pathname": "/exit",
                 "$lib": "posthog-elixir",
                 "$lib_version": _,
                 "$exception_list": [
                   %{
                     type: "** (exit) \"i quit\"",
                     value: "\"i quit\"",
                     mechanism: %{handled: false, type: "generic"}
                   }
                 ]
               } = properties
      else
        assert %{
                 "$current_url": "http://localhost/exit",
                 "$host": "localhost",
                 "$ip": "127.0.0.1",
                 "$pathname": "/exit",
                 "$lib": "posthog-elixir",
                 "$lib_version": _,
                 "$exception_list": [
                   %{
                     mechanism: %{handled: true, type: "generic"},
                     type: "** (exit) \"i quit\"",
                     value: "** (exit) \"i quit\"\n" <> _
                   },
                   %{
                     type: "** (exit) \"i quit\"",
                     value: "\"i quit\"",
                     mechanism: %{handled: false, type: "generic"}
                   }
                 ]
               } = properties
      end
    end
  end

  describe "Cowboy" do
    test "context is attached to exceptions", %{handler_ref: ref} do
      LoggerHandlerKit.Act.plug_error(:exception, Plug.Cowboy, MyRouter)
      LoggerHandlerKit.Assert.assert_logged(ref)

      assert [event] = all_captured(@supervisor_name)

      assert %{
               event: "$exception",
               uuid: _,
               properties: properties
             } = event

      if pre_19?() do
        assert %{
                 "$current_url": "http://localhost/exception",
                 "$host": "localhost",
                 "$ip": "127.0.0.1",
                 "$pathname": "/exception",
                 "$lib": "posthog-elixir",
                 "$lib_version": _,
                 "$exception_list": [
                   %{
                     type: "RuntimeError",
                     value: "oops",
                     mechanism: %{handled: false, type: "generic"},
                     stacktrace: %{type: "raw", frames: _frames}
                   }
                 ]
               } = properties
      else
        assert %{
                 "$current_url": "http://localhost/exception",
                 "$host": "localhost",
                 "$ip": "127.0.0.1",
                 "$pathname": "/exception",
                 "$lib": "posthog-elixir",
                 "$lib_version": _,
                 "$exception_list": [
                   %{
                     type: "RuntimeError",
                     value: "oops",
                     mechanism: %{handled: false, type: "generic"},
                     stacktrace: %{type: "raw", frames: _frames}
                   },
                   %{
                     type: "#PID<" <> _,
                     value: "#PID<" <> _,
                     mechanism: %{handled: true, type: "generic"}
                   }
                 ]
               } = properties
      end
    end

    test "context is attached to throws", %{handler_ref: ref} do
      LoggerHandlerKit.Act.plug_error(:throw, Plug.Cowboy, MyRouter)
      LoggerHandlerKit.Assert.assert_logged(ref)

      assert [event] = all_captured(@supervisor_name)

      assert %{
               event: "$exception",
               uuid: _,
               properties: properties
             } = event

      if pre_19?() do
        assert %{
                 "$current_url": "http://localhost/throw",
                 "$host": "localhost",
                 "$ip": "127.0.0.1",
                 "$pathname": "/throw",
                 "$lib": "posthog-elixir",
                 "$lib_version": _,
                 "$exception_list": [
                   %{
                     type: "** (throw) \"catch!\"",
                     value: "\"catch!\"",
                     mechanism: %{handled: false, type: "generic"},
                     stacktrace: %{type: "raw", frames: _frames}
                   }
                 ]
               } = properties
      else
        assert %{
                 "$current_url": "http://localhost/throw",
                 "$host": "localhost",
                 "$ip": "127.0.0.1",
                 "$pathname": "/throw",
                 "$lib": "posthog-elixir",
                 "$lib_version": _,
                 "$exception_list": [
                   %{
                     type: "** (throw) \"catch!\"",
                     value: "\"catch!\"",
                     mechanism: %{handled: false, type: "generic"},
                     stacktrace: %{type: "raw", frames: _frames}
                   },
                   %{
                     type: "#PID<" <> _,
                     value: "#PID<" <> _,
                     mechanism: %{handled: true, type: "generic"}
                   }
                 ]
               } = properties
      end
    end

    test "context is attached to exit", %{handler_ref: ref} do
      LoggerHandlerKit.Act.plug_error(:exit, Plug.Cowboy, MyRouter)
      LoggerHandlerKit.Assert.assert_logged(ref)

      assert [event] = all_captured(@supervisor_name)

      assert %{
               event: "$exception",
               uuid: _,
               properties: properties
             } = event

      if pre_19?() do
        assert %{
                 "$current_url": "http://localhost/exit",
                 "$host": "localhost",
                 "$ip": "127.0.0.1",
                 "$pathname": "/exit",
                 "$lib": "posthog-elixir",
                 "$lib_version": _,
                 "$exception_list": [
                   %{
                     type: "** (exit) \"i quit\"",
                     value: "\"i quit\"",
                     mechanism: %{handled: false, type: "generic"}
                   }
                 ]
               } = properties
      else
        assert %{
                 "$current_url": "http://localhost/exit",
                 "$host": "localhost",
                 "$ip": "127.0.0.1",
                 "$pathname": "/exit",
                 "$lib": "posthog-elixir",
                 "$lib_version": _,
                 "$exception_list": [
                   %{
                     type: "** (exit) \"i quit\"",
                     value: "\"i quit\"",
                     mechanism: %{handled: false, type: "generic"}
                   },
                   %{
                     type: "#PID<" <> _,
                     value: "#PID<" <> _,
                     mechanism: %{handled: true, type: "generic"}
                   }
                 ]
               } = properties
      end
    end
  end

  defp plug_error_with_headers(flavour, web_server, router_plug, headers) do
    ExUnit.Callbacks.start_supervised!(
      {web_server, [plug: {router_plug, %{test_pid: self()}}, scheme: :http, port: 8001]}
    )

    {:ok, conn} = Mint.HTTP.connect(:http, "localhost", 8001)
    {:ok, _conn, _request_ref} = Mint.HTTP.request(conn, "GET", "/#{flavour}", headers, nil)

    :ok
  end
end
