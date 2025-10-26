defmodule PostHog.LLMAnalytics do
  @root_span_key :__llm_analytics_root_span_id
  @span_backlog_key :__llm_analytics_spans
  @llm_events ["$ai_generation", "$ai_trace", "$ai_span", "$ai_embedding"]

  def set_trace(trace_id) when not is_atom(trace_id) do
    set_trace(PostHog, trace_id)
  end

  def set_trace(name \\ PostHog, trace_id \\ nil) do
    trace_id = trace_id || UUIDv7.generate()
    properties = %{"$ai_trace_id": trace_id}

    for event <- ["$exception" | @llm_events] do
      PostHog.Context.set(name, event, properties)
    end

    trace_id
  end

  def set_root_span(name \\ PostHog, span_id) do
    Process.put({name, @root_span_key}, span_id)
  end

  def start_span(properties) when not is_atom(properties) do
    start_span(PostHog, properties)
  end

  def start_span(name \\ PostHog, properties \\ %{}) do
    properties = Map.put_new_lazy(properties, :"$ai_span_id", fn -> UUIDv7.generate() end)
    span = push_span(name, properties)
    span."$ai_span_id"
  end

  def capture_current_span(type, properties) when not is_atom(type) do
    capture_current_span(PostHog, type, properties)
  end

  def capture_current_span(name \\ PostHog, type, properties \\ %{}) when type in @llm_events do
    current_span_properties = name |> pop_span() |> Map.merge(properties)
    PostHog.capture(name, type, current_span_properties)
  end

  def capture_span(type, properties) when not is_atom(type) do
    capture_span(PostHog, type, properties)
  end

  def capture_span(name \\ PostHog, type, properties \\ %{}) when type in @llm_events do
    start_span(name, properties)
    capture_current_span(name, type, properties)
  end

  defp pop_span(name) do
    case Process.get({name, @span_backlog_key}) do
      [span | rest] ->
        Process.put({name, @span_backlog_key}, rest)
        span

      _ ->
        root_span = Process.get({name, @root_span_key})

        if root_span, do: %{"$ai_parent_id": root_span}, else: %{}
    end
  end

  defp push_span(name, span) do
    case Process.get({name, @span_backlog_key}) do
      [%{"$ai_span_id": parent_span_id} | _] = backlog ->
        span = Map.put_new(span, :"$ai_parent_id", parent_span_id)
        Process.put({name, @span_backlog_key}, [span | backlog])
        span

      _ ->
        span =
          if root_span = Process.get({name, @root_span_key}) do
            Map.put_new(span, :"$ai_parent_id", root_span)
          else
            span
          end

        Process.put({name, @span_backlog_key}, [span])
        span
    end
  end
end
