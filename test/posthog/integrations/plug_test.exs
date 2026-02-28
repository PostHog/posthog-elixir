defmodule PostHog.Integrations.PlugTest do
  # This unfortunately will be flaky in async mode until
  # https://github.com/erlang/otp/issues/9997 is fixed
  use PostHog.Case, async: false

  @supervisor_name __MODULE__
  @moduletag capture_log: true, config: [capture_level: :error, supervisor_name: @supervisor_name]

  setup {LoggerHandlerKit.Arrange, :ensure_per_handler_translation}
  setup :setup_supervisor
  setup :setup_logger_handler

  defmodule MyRouter do
    use Plug.Router
    require Logger

    plug(PostHog.Integrations.Plug)
    plug(:match)
    plug(:dispatch)

    forward("/", to: LoggerHandlerKit.Plug)
  end

  test "sets relevant context" do
    conn = Plug.Test.conn(:get, "https://posthog.com/foo?bar=10")
    assert PostHog.Integrations.Plug.call(conn, nil)

    assert PostHog.Context.get(:all) == %{
             "$current_url": "https://posthog.com/foo?bar=10",
             "$host": "posthog.com",
             "$ip": "127.0.0.1",
             "$pathname": "/foo"
           }
  end

  setup do
    # We use this call to initialize key ownership. LoggerHandlerKit will share
    # ownership to PostHog.Ownership server, but the key has to be initialized.
    all_captured(@supervisor_name)
  end

  describe "Bandit" do
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
                     value: "** (RuntimeError) oops",
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
                     value: "** (RuntimeError) oops",
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
                     value: "** (throw) \"catch!\"",
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
                     value: "** (throw) \"catch!\"",
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
                     value: "** (exit) \"i quit\"",
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
                     value: "** (exit) \"i quit\"",
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
                     value: "** (RuntimeError) oops",
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
                     value: "** (RuntimeError) oops",
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
                     value: "** (throw) \"catch!\"",
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
                     value: "** (throw) \"catch!\"",
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
                     value: "** (exit) \"i quit\"",
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
                     value: "** (exit) \"i quit\"",
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
end
