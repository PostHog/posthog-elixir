if Code.ensure_loaded?(:otel_span_processor) do
  defmodule PostHog.OpenTelemetry.ContextSpanProcessor do
    @moduledoc """
    Adds PostHog IDs to application spans when they start.

    Requires the optional `{:opentelemetry, "~> 1.7"}` dependency. Add
    `{PostHog.OpenTelemetry.ContextSpanProcessor, %{supervisor_name: PostHog}}`
    before the existing export processors in your OpenTelemetry `:processors`
    configuration. Keep the application's provider, exporter, and sampler.

    The processor reads the current process's PostHog context. `:supervisor_name`
    selects a named PostHog instance and defaults to `PostHog`. Spans stay
    unchanged when that instance is disabled or not started. It adds the
    `sessionId` and `posthogDistinctId` attributes when their values are present.
    Existing attributes with these names take precedence, with atom or string
    keys. Empty and non-string IDs are omitted.

    Initial span attributes named `http.request.header.x-posthog-session-id`
    and `http.request.header.x-posthog-distinct-id` provide fallback IDs when
    process context has none. The processor sanitizes those values with the
    same rules as the PostHog plug. Existing canonical attributes take precedence,
    followed by process context, then captured header attributes.

    With Cowboy, explicitly allow only `x-posthog-session-id` and
    `x-posthog-distinct-id` in the application's OpenTelemetry `request_headers`
    option to cover its early request span. This processor does not enable
    header capture. Keep `PostHog.Integrations.Plug` before the router for child
    spans. A span that starts without context or captured headers remains
    unchanged, even if PostHog extracts headers later.

    Context has the same lifetime as existing PostHog process metadata. A
    standard request process loses its context when it exits. Reusing a process
    for unrelated work requires explicit context cleanup. Tasks and spawned
    processes do not automatically inherit PostHog context. Set context in the
    destination process when that propagation is required.
    """

    @behaviour :otel_span_processor

    alias PostHog.TracingHeaders

    require Record

    Record.defrecordp(
      :span,
      Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
    )

    @context_attributes [
      {:sessionId, :"$session_id", :"http.request.header.x-posthog-session-id"},
      {:posthogDistinctId, :distinct_id, :"http.request.header.x-posthog-distinct-id"}
    ]

    @impl true
    @doc false
    def on_start(_parent_context, current_span, config) do
      name = Map.get(config, :supervisor_name, PostHog)

      case PostHog.config(name) do
        %{enabled: true} -> add_context(current_span, PostHog.Context.get(name))
        _ -> current_span
      end
    rescue
      _ -> current_span
    catch
      _, _ -> current_span
    end

    defp add_context(current_span, context) do
      attributes = span(current_span, :attributes)
      existing = :otel_attributes.map(attributes)

      attributes =
        Enum.reduce(@context_attributes, attributes, fn {key, context_key, header_key},
                                                        attributes ->
          name = Atom.to_string(key)
          value = context_id(context, context_key, existing, header_key)

          if is_binary(value) and value != "" and
               not (Map.has_key?(existing, name) or Map.has_key?(existing, key)) do
            :otel_attributes.set(name, value, attributes)
          else
            attributes
          end
        end)

      span(current_span, attributes: attributes)
    end

    defp context_id(context, context_key, attributes, header_key) do
      case Map.get(context, context_key) do
        value when is_binary(value) and value != "" -> value
        _ -> header_id(attributes, header_key)
      end
    end

    defp header_id(attributes, key) do
      case Map.get(attributes, Atom.to_string(key), Map.get(attributes, key)) do
        [value | _] when is_binary(value) -> TracingHeaders.sanitize_value(value)
        value when is_binary(value) -> TracingHeaders.sanitize_value(value)
        _ -> nil
      end
    end

    @impl true
    @doc false
    def on_end(_span, _config), do: true

    @impl true
    @doc false
    def force_flush(_config), do: :ok
  end
end
