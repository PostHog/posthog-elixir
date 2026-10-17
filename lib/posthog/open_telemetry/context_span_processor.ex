if Code.ensure_loaded?(:otel_span_processor) do
  defmodule PostHog.OpenTelemetry.ContextSpanProcessor do
    @moduledoc """
    Adds PostHog IDs to application spans when they start.

    Requires the optional `{:opentelemetry, "~> 1.7"}` dependency. Add
    `{PostHog.OpenTelemetry.ContextSpanProcessor, %{supervisor_name: PostHog}}`
    before the existing export processors in your OpenTelemetry `:processors`
    configuration. Keep the application's provider, exporter, and sampler.

    The processor reads the current process's PostHog context. `:supervisor_name`
    selects a named PostHog instance and defaults to `PostHog`. It adds the
    `sessionId` and `posthogDistinctId` attributes when their values are present.
    Existing attributes with these names take precedence, with atom or string
    keys. Empty and non-string IDs are omitted.

    Place `PostHog.Integrations.Plug` before an application tracing plug if that
    tracing plug starts the request span. This processor cannot update a span
    that started before PostHog extracted the headers. This includes request
    spans that Phoenix instrumentation starts before the endpoint's plugs.

    Context has the same lifetime as existing PostHog process metadata. A
    standard request process loses its context when it exits. Reusing a process
    for unrelated work requires explicit context cleanup. Tasks and spawned
    processes do not automatically inherit PostHog context. Set context in the
    destination process when that propagation is required.
    """

    @behaviour :otel_span_processor

    require Record

    Record.defrecordp(
      :span,
      Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
    )

    @context_attributes [
      {"sessionId", :sessionId, :"$session_id"},
      {"posthogDistinctId", :posthogDistinctId, :distinct_id}
    ]

    @impl true
    @doc false
    def on_start(_parent_context, current_span, config) do
      context = PostHog.Context.get(Map.get(config, :supervisor_name, PostHog))
      attributes = span(current_span, :attributes)
      existing = :otel_attributes.map(attributes)

      attributes =
        Enum.reduce(@context_attributes, attributes, fn {key, atom_key, context_key},
                                                        attributes ->
          value = Map.get(context, context_key)

          if is_binary(value) and value != "" and
               not (Map.has_key?(existing, key) or Map.has_key?(existing, atom_key)) do
            :otel_attributes.set(key, value, attributes)
          else
            attributes
          end
        end)

      span(current_span, attributes: attributes)
    rescue
      _ -> current_span
    catch
      _, _ -> current_span
    end

    @impl true
    @doc false
    def on_end(_span, _config), do: true

    @impl true
    @doc false
    def force_flush(_config), do: :ok
  end
end
