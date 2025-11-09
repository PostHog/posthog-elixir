defmodule PostHog.LLMAnalytics do
  @moduledoc since: "2.1.0"
  @moduledoc """
  [LLM Analytics](https://posthog.com/docs/llm-analytics) is an observability
  product for LLM-powered applications.

  LLM Analytics works by capturing special types of events: traces (`$ai_trace`)
  and spans (`$ai_generation`, `$ai_span`, and `$ai_embedding`). They organize
  into a tree structure.

  ```mermaid
  flowchart TD
  
      A[<strong>$ai_trace</strong>]
              
      B[<strong>$ai_generation</strong>]
        
      C@{ shape: processes, label: "<strong>$ai_spans</strong>" }
  
      D[<strong>$ai_generation</strong>]
  
      E@{ shape: processes, label: "<strong>$ai_spans</strong>" }
  
      F[<strong>$ai_generation</strong>]
  
      A --> B
      A --> C
      C --> D
      C --> E
      E --> F
  ```

  This module provides an interface for instrumenting your application with traces
  and spans.

  ## Traces

  [Traces](https://posthog.com/docs/llm-analytics/manual-capture?tab=Trace)
  define how spans are grouped together. You can capture them explicitly with
  `$ai_trace` event if you want, but it's not required. As long as all your
  spans include `$ai_trace_id` property, PostHog will group them automatically.
  `set_trace/2` function will generate a random UUIDv7 trace id and
  set it in the context for relevant events automatically:

      iex> PostHog.LLMAnalytics.set_trace()
      "019a69ad-a9e9-7a20-9540-40101e01a364"
      iex> PostHog.get_event_context("$ai_span")
      %{"$ai_trace_id": "019a69ad-a9e9-7a20-9540-40101e01a364"}
      
  ## Spans

  [`$ai_generation`](https://posthog.com/docs/llm-analytics/manual-capture?tab=Generation),
  [`$ai_span`](https://posthog.com/docs/llm-analytics/manual-capture?tab=Span)
  and
  [`$ai_embedding`](https://posthog.com/docs/llm-analytics/manual-capture?tab=Embedding)
  are all span events. To capture them, use the `capture_span/2` function:

      iex> PostHog.LLMAnalytics.capture_span("$ai_generation", %{"$ai_span_name": "user message"})
      {:ok, "019a69b8-c465-7981-99cc-5578ae10f55b"}
      
  It automatically generates and returns a span id, which can be used as a parent
  span id later:

      iex> PostHog.LLMAnalytics.capture_span("$ai_span", %{"$ai_span_name": "tool call", "$ai_parent_id": "019a69b8-c465-7981-99cc-5578ae10f55b"})
      {:ok, "019a69bb-4ba1-7cdc-8287-3425e4e7033f"}
      
      
  ## Nested Spans

  Very often, it's not practical to carry all span properties to the place that
  actually captures the event. In this case, use `start_span/2` to
  start a span and `capture_current_span/3` to capture it:

  ```
  def generate_response(user_message) do
    LLMAnalytics.start_span(%{"$ai_span_name": "LLM call", "$ai_input_state": user_message})
    
    Req.post!("https://api.openai.com/v1/responses, json: %{input: user_message})
    |> handle_response()
  end

  defp handle_response(%{status: 200, body: %{"output" => output}}) do
    LLMAnalytics.capture_current_span("$ai_generation", %{"$ai_output_choices": output})
    ...
  end
  ```

  You can also start nested spans and SDK will automatically take care
  of setting parent span IDs:

      iex> PostHog.LLMAnalytics.start_span(%{"$ai_span_name": "parent"})
      "019a69de-0d29-7160-bea2-c93124109de6"
      iex> PostHog.LLMAnalytics.capture_span("$ai_span", %{"$ai_span_name": "child"})
      {:ok, "019a69de-38a9-7975-ac51-97e056cee6bf"}
      iex> PostHog.LLMAnalytics.capture_current_span("$ai_span")
      {:ok, "019a69de-0d29-7160-bea2-c93124109de6"}
      
  Think of `capture_span` as a way to capture "leaf" nodes of the tree.
      
  ## Asynchronous Environment

  Just as with Context, LLMAnalytics tracks the current trace and span in the
  process dictionary. Any time you spawn a new process, you'll need to propagate
  this information. Use `set_trace/2` and `set_root_span/2`:

  ```
  def generate_response(user_message) do
    trace_id = LLMAnalytics.set_trace()
    {:ok, span_id} = LLMAnalytics.capture_span("$ai_span", %{"$ai_span_name": "top level", "$ai_input_state": user_message})
    
    Task.async(fn -> 
      LLMAnalytics.set_trace(trace_id)
      LLMAnalytics.set_root_span(span_id)
      
      resp = Req.post!("https://api.openai.com/v1/responses", json: %{input: "Check if this message violates our policies: " <> user_message})
      LLMAnalytics.capture_span("$ai_generation", %{"$ai_span_name": "railguard check", ...})
      ...
    end)
    
    Req.post!("https://api.openai.com/v1/responses, json: %{input: user_message})
    ...
  end
  ```
  """
  @root_span_key :__llm_analytics_root_span_id
  @span_backlog_key :__llm_analytics_spans
  @llm_events ["$ai_generation", "$ai_trace", "$ai_span", "$ai_embedding"]

  @typedoc "You can pass any string as span_id. By default, PostHog will generate a random UUIDv7."
  @type span_id() :: String.t()

  @typedoc "You can pass any string as trace_id. By default, PostHog will generate a random UUIDv7."
  @type trace_id() :: String.t()

  @typedoc "One of LLM Analytics events: `$ai_generation`, `$ai_trace`, `$ai_span`, `$ai_embedding`"
  @type llm_event() :: PostHog.event()

  @doc false
  def set_trace(trace_id) when not is_atom(trace_id) do
    set_trace(PostHog, trace_id)
  end

  @spec set_trace(PostHog.supervisor_name(), trace_id()) :: trace_id()
  def set_trace(name \\ PostHog, trace_id \\ UUIDv7.generate()) do
    properties = %{"$ai_trace_id": trace_id}

    for event <- ["$exception" | @llm_events] do
      PostHog.Context.set(name, event, properties)
    end

    trace_id
  end

  @spec get_trace(PostHog.supervisor_name()) :: trace_id() | nil
  def get_trace(name \\ PostHog) do
    PostHog.Context.get(name, "$ai_generation")[:"$ai_trace_id"]
  end

  @spec set_root_span(PostHog.supervisor_name(), span_id()) :: :ok
  def set_root_span(name \\ PostHog, span_id) do
    Process.put({name, @root_span_key}, span_id)
    :ok
  end

  @spec get_root_span(PostHog.supervisor_name()) :: span_id()
  def get_root_span(name \\ PostHog) do
    Process.get({name, @root_span_key})
  end

  @doc false
  def start_span(properties) when not is_atom(properties) do
    start_span(PostHog, properties)
  end

  @spec start_span(PostHog.supervisor_name(), PostHog.properties()) :: span_id()
  def start_span(name \\ PostHog, properties \\ %{}) do
    properties = Map.put_new_lazy(properties, :"$ai_span_id", fn -> UUIDv7.generate() end)
    span = push_span(name, properties)
    span."$ai_span_id"
  end

  @doc false
  def capture_current_span(type, properties) when not is_atom(type) do
    capture_current_span(PostHog, type, properties)
  end

  @spec capture_current_span(PostHog.supervisor_name(), llm_event(), PostHog.properties()) ::
          :ok | {:error, :missing_distinct_id}
  def capture_current_span(name \\ PostHog, type, properties \\ %{}) when type in @llm_events do
    current_span_properties = name |> pop_span() |> Map.merge(properties)

    with :ok <- PostHog.capture(name, type, current_span_properties) do
      {:ok, current_span_properties."$ai_span_id"}
    end
  end

  @doc false
  def capture_span(type, properties) when not is_atom(type) do
    capture_span(PostHog, type, properties)
  end

  @spec capture_span(PostHog.supervisor_name(), llm_event(), PostHog.properties()) ::
          {:ok, span_id()} | {:error, :missing_distinct_id}
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
        span_id = UUIDv7.generate()

        if root_span do
          %{"$ai_parent_id": root_span, "$ai_span_id": span_id}
        else
          %{"$ai_span_id": span_id}
        end
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
