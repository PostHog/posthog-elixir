defmodule PostHog.OpenTelemetry.ContextSpanProcessorTest do
  use ExUnit.Case, async: false

  require Record
  Record.defrecordp(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

  alias PostHog.Integrations.Plug, as: PostHogPlug
  alias PostHog.OpenTelemetry.ContextSpanProcessor

  defmodule CaptureProcessor do
    @behaviour :otel_span_processor
    def on_start(_context, span, _config), do: span

    def on_end(span, %{pid: pid}) do
      send(pid, {:finished_span, span})
      true
    end

    def force_flush(_config), do: :ok
  end

  setup context do
    Application.stop(:opentelemetry)
    previous = Application.get_all_env(:opentelemetry)

    Application.put_env(:opentelemetry, :processors, [
      {ContextSpanProcessor, %{supervisor_name: :span_context_test}},
      {CaptureProcessor, %{pid: self()}}
    ])

    Application.put_env(:opentelemetry, :sampler, context[:sampler] || :always_on)
    Application.put_env(:opentelemetry, :attribute_count_limit, context[:attribute_limit] || 128)
    {:ok, _} = Application.ensure_all_started(:opentelemetry)

    on_exit(fn ->
      Application.stop(:opentelemetry)

      for {key, _} <- Application.get_all_env(:opentelemetry),
          do: Application.delete_env(:opentelemetry, key)

      Application.put_all_env(opentelemetry: previous)
    end)

    %{tracer: :opentelemetry.get_tracer(context.test)}
  end

  test "snapshots process context before later changes and cleanup", %{tracer: tracer} do
    PostHog.set_context(:span_context_test, %{
      distinct_id: "person-one",
      "$session_id": "session-one"
    })

    active = :otel_tracer.start_span(tracer, "child", %{})

    PostHog.set_context(:span_context_test, %{
      distinct_id: "person-two",
      "$session_id": "session-two"
    })

    :logger.unset_process_metadata()
    :otel_span.end_span(active)
    assert attributes() == %{"sessionId" => "session-one", "posthogDistinctId" => "person-one"}
    finish_span(tracer, "outside")
    assert attributes() == %{}
  end

  for explicit <- [
        %{"sessionId" => "explicit-session"},
        %{posthogDistinctId: "explicit-person"},
        %{"sessionId" => "", posthogDistinctId: false}
      ] do
    @explicit explicit
    test "preserves explicit attributes #{inspect(explicit)}", %{tracer: tracer} do
      PostHog.set_context(:span_context_test, %{distinct_id: "person", "$session_id": "session"})
      finish_span(tracer, "explicit", %{attributes: @explicit})
      actual = attributes()
      for {key, value} <- @explicit, do: assert(actual[key] == value)
      assert map_size(actual) == 2
    end
  end

  @tag attribute_limit: 1
  test "keeps existing attributes when span is full", %{tracer: tracer} do
    PostHog.set_context(:span_context_test, %{distinct_id: "person", "$session_id": "session"})
    finish_span(tracer, "full", %{attributes: %{"application" => "keep"}})
    assert attributes() == %{"application" => "keep"}
  end

  for value <- [nil, "", 10, false] do
    @value value
    test "omits invalid and absent IDs #{inspect(value)}", %{tracer: tracer} do
      PostHog.set_context(:span_context_test, %{distinct_id: @value, "$session_id": @value})
      finish_span(tracer, "missing")
      assert attributes() == %{}
    end
  end

  for outcome <- [:success, :raise] do
    @outcome outcome
    test "Plug headers reach new request spans on #{outcome}", %{tracer: tracer} do
      conn =
        Plug.Test.conn(:get, "/")
        |> Plug.Conn.put_req_header("x-posthog-distinct-id", "header-person")
        |> Plug.Conn.put_req_header("x-posthog-session-id", "header-session")

      request = fn ->
        Plug.run(conn, [
          {PostHogPlug, []},
          fn conn ->
            :otel_tracer.with_span(tracer, "request", %{kind: :server}, fn _ ->
              finish_span(tracer, "child")
              if @outcome == :raise, do: raise("request failure")
              conn
            end)
          end
        ])
      end

      if @outcome == :raise do
        assert_raise RuntimeError, "request failure", request
      else
        assert request.() == conn
      end

      for _ <- 1..2 do
        assert attributes() == %{
                 "sessionId" => "header-session",
                 "posthogDistinctId" => "header-person"
               }
      end
    end
  end

  test "application context takes precedence over header identity", %{tracer: tracer} do
    PostHog.set_context(:span_context_test, %{distinct_id: "application-person"})

    Plug.Test.conn(:get, "/")
    |> Plug.Conn.put_req_header("x-posthog-distinct-id", "header-person")
    |> Plug.Conn.put_req_header("x-posthog-session-id", "header-session")
    |> PostHogPlug.call([])

    finish_span(tracer, "child")

    assert attributes() == %{
             "sessionId" => "header-session",
             "posthogDistinctId" => "application-person"
           }
  end

  test "keeps an earlier incoming span unchanged", %{tracer: tracer} do
    :otel_tracer.with_span(tracer, "existing-request", %{kind: :server}, fn _ ->
      Plug.Test.conn(:get, "/")
      |> Plug.Conn.put_req_header("x-posthog-session-id", "header-session")
      |> PostHogPlug.call([])

      finish_span(tracer, "child")
    end)

    assert attributes() == %{"sessionId" => "header-session"}
    assert attributes() == %{}
  end

  test "isolates concurrent request processes and their tasks", %{tracer: tracer} do
    tasks =
      for id <- ["one", "two"] do
        Task.async(fn ->
          conn = Plug.Test.conn(:get, "/") |> Plug.Conn.put_req_header("x-posthog-session-id", id)
          PostHogPlug.call(conn, [])
          finish_span(tracer, id)
          Task.async(fn -> finish_span(tracer, "detached") end) |> Task.await()
        end)
      end

    Enum.each(tasks, &Task.await/1)
    results = for _ <- 1..4, do: attributes()

    assert Enum.sort(results) ==
             Enum.sort([%{"sessionId" => "one"}, %{"sessionId" => "two"}, %{}, %{}])
  end

  @tag sampler: :always_off
  test "does not change application sampling", %{tracer: tracer} do
    PostHog.set_context(:span_context_test, %{distinct_id: "person", "$session_id": "session"})
    active = :otel_tracer.start_span(tracer, "sampled-out", %{})
    refute :otel_span.is_recording(active)
    :otel_span.end_span(active)
    refute_receive {:finished_span, _}, 0
  end

  defp finish_span(tracer, name, options \\ %{}) do
    tracer |> :otel_tracer.start_span(name, options) |> :otel_span.end_span()
  end

  defp attributes do
    assert_receive {:finished_span, finished}
    finished |> span(:attributes) |> :otel_attributes.map()
  end
end
