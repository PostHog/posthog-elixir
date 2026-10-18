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

    Mox.stub_with(PostHog.API.Mock, PostHog.API.Stub)
    start_posthog(:span_context_test, "my_api_key")
    instances = context[:processor_instances] || [:span_context_test]
    if :span_context_disabled in instances, do: start_posthog(:span_context_disabled, "")
    processors = for name <- instances, do: {ContextSpanProcessor, %{supervisor_name: name}}

    Application.put_env(
      :opentelemetry,
      :processors,
      processors ++ [{CaptureProcessor, %{pid: self()}}]
    )

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

  for {label, raw, expected} <- [
        {"trim and controls", [" \0session\n-\u0085123\r\t "], "session-123"},
        {"first value", ["first", "second"], "first"},
        {"single string", "single", "single"},
        {"empty", [" \n\t "], nil},
        {"empty array", [], nil},
        {"wrong type", true, nil},
        {"length limit", [String.duplicate("a", 1001)], String.duplicate("a", 1000)}
      ],
      key_type <- [:atom, :string] do
    @raw raw
    @expected expected
    @key_type key_type
    test "uses initial #{key_type} header attributes: #{label}", %{tracer: tracer} do
      header = :"http.request.header.x-posthog-session-id"
      key = if @key_type == :string, do: Atom.to_string(header), else: header
      finish_span(tracer, "request", %{attributes: %{key => @raw}})
      assert attributes()["sessionId"] == @expected
    end
  end

  for {label, context, explicit, expected} <- [
        {"header fallback", %{}, %{},
         %{"sessionId" => "header-session", "posthogDistinctId" => "header-person"}},
        {"application context",
         %{distinct_id: "application-person", "$session_id": "application-session"}, %{},
         %{"sessionId" => "application-session", "posthogDistinctId" => "application-person"}},
        {"explicit canonical attributes", %{distinct_id: "application-person"},
         %{"sessionId" => "explicit-session", "posthogDistinctId" => "explicit-person"},
         %{"sessionId" => "explicit-session", "posthogDistinctId" => "explicit-person"}}
      ] do
    @context context
    @explicit explicit
    @expected expected
    test "initial header fallback respects #{label}", %{tracer: tracer} do
      PostHog.set_context(:span_context_test, @context)

      initial =
        Map.merge(
          %{
            :"http.request.header.x-posthog-session-id" => ["header-session"],
            :"http.request.header.x-posthog-distinct-id" => ["header-person"]
          },
          @explicit
        )

      finish_span(tracer, "request", %{attributes: initial})
      actual = attributes()
      assert Map.take(actual, ["sessionId", "posthogDistinctId"]) == @expected
      for {key, value} <- initial, do: assert(actual[key] == value)
    end
  end

  @tag attribute_limit: 1
  test "header fallback does not evict captured header attributes", %{tracer: tracer} do
    initial = %{:"http.request.header.x-posthog-session-id" => ["header-session"]}
    finish_span(tracer, "request", %{attributes: initial})
    assert attributes() == initial
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

  @headers %{
    :"http.request.header.x-posthog-session-id" => ["header-session"],
    :"http.request.header.x-posthog-distinct-id" => ["header-person"]
  }

  for {label, instances, context_instances, initial, expected} <- [
        {"missing instance", [:span_context_missing], [:span_context_missing], %{}, %{}},
        {"disabled instance with process context", [:span_context_disabled],
         [:span_context_disabled], %{}, %{}},
        {"disabled instance with header fallback", [:span_context_disabled], [], @headers,
         @headers},
        {"enabled test-mode instance", [:span_context_test], [:span_context_test], %{},
         %{
           "sessionId" => "span_context_test-session",
           "posthogDistinctId" => "span_context_test-person"
         }},
        {"enabled instance beside a disabled one", [:span_context_disabled, :span_context_test],
         [:span_context_disabled, :span_context_test], %{},
         %{
           "sessionId" => "span_context_test-session",
           "posthogDistinctId" => "span_context_test-person"
         }}
      ] do
    @context_instances context_instances
    @initial initial
    @expected expected
    @tag processor_instances: instances
    test "selected instance state controls enrichment: #{label}", %{tracer: tracer} do
      for name <- @context_instances do
        PostHog.set_context(name, %{
          distinct_id: "#{name}-person",
          "$session_id": "#{name}-session"
        })
      end

      finish_span(tracer, "request", %{attributes: @initial})
      assert attributes() == @expected
    end
  end

  defp start_posthog(name, api_key) do
    config =
      PostHog.Config.validate!(
        api_key: api_key,
        api_client_module: PostHog.API.Mock,
        supervisor_name: name,
        test_mode: true
      )

    start_supervised!({PostHog.Supervisor, config}, id: name)
  end

  defp finish_span(tracer, name, options \\ %{}) do
    tracer |> :otel_tracer.start_span(name, options) |> :otel_span.end_span()
  end

  defp attributes do
    assert_receive {:finished_span, finished}
    finished |> span(:attributes) |> :otel_attributes.map()
  end
end
