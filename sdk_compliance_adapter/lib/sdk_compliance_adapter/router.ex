defmodule SdkComplianceAdapter.Router do
  @moduledoc """
  HTTP router for the SDK compliance adapter.

  Implements the standard adapter interface defined by the PostHog SDK Test Harness.
  """
  use Plug.Router
  use Plug.ErrorHandler

  require Logger

  # Capture SDK version at compile time since Mix isn't available at runtime
  @sdk_version Application.spec(:posthog, :vsn) |> to_string()

  plug(Plug.Logger)
  plug(:match)
  plug(Plug.Parsers,
    parsers: [:json],
    json_decoder: Jason,
    pass: ["*/*"]
  )
  plug(:dispatch)

  @impl Plug.ErrorHandler
  def handle_errors(conn, %{kind: _kind, reason: reason, stack: stack}) do
    Logger.error("Error in #{conn.method} #{conn.request_path}: #{inspect(reason)}\n#{Exception.format_stacktrace(stack)}")

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(500, Jason.encode!(%{success: false, error: inspect(reason)}))
  end

  # GET /health - Health check endpoint
  get "/health" do
    response = %{
      sdk_name: "posthog-elixir",
      sdk_version: @sdk_version,
      adapter_version: SdkComplianceAdapter.version()
    }

    json_response(conn, 200, response)
  end

  # POST /init - Initialize SDK with configuration
  post "/init" do
    params = conn.body_params

    # Stop existing PostHog supervisor if running
    stop_posthog()

    # Reset state
    SdkComplianceAdapter.State.reset()

    # Build configuration
    config = build_config(params)
    SdkComplianceAdapter.State.set_config(config)

    # Start PostHog with the new configuration
    case start_posthog(config) do
      {:ok, _pid} ->
        json_response(conn, 200, %{success: true})

      {:error, reason} ->
        json_response(conn, 500, %{success: false, error: inspect(reason)})
    end
  end

  # POST /capture - Capture a single event
  post "/capture" do
    params = conn.body_params

    distinct_id = params["distinct_id"]
    event = params["event"]
    properties = params["properties"] || %{}

    if is_nil(distinct_id) or is_nil(event) do
      json_response(conn, 400, %{success: false, error: "Missing distinct_id or event"})
    else
      # Use the SDK's public API as-is
      PostHog.bare_capture(SdkComplianceAdapter.PostHog, event, distinct_id, properties)

      # Track captured event
      SdkComplianceAdapter.State.increment_events_captured()

      # The SDK doesn't return UUID, so we return a placeholder
      # The test harness will check the actual UUID in the batch request
      json_response(conn, 200, %{success: true})
    end
  end

  # POST /flush - Flush pending events
  post "/flush" do
    # Get the configured interval
    config = SdkComplianceAdapter.State.get_config()
    interval_ms = config[:max_batch_time_ms] || 100

    # Wait for events to be sent (interval + buffer)
    wait_time = interval_ms + 500
    Process.sleep(wait_time)

    state = SdkComplianceAdapter.State.get()

    json_response(conn, 200, %{
      success: true,
      events_flushed: state.total_events_sent
    })
  end

  # GET /state - Get internal SDK state
  get "/state" do
    state = SdkComplianceAdapter.State.get()

    response = %{
      pending_events: state.pending_events,
      total_events_captured: state.total_events_captured,
      total_events_sent: state.total_events_sent,
      total_retries: state.total_retries,
      last_error: state.last_error,
      requests_made: state.requests_made
    }

    json_response(conn, 200, response)
  end

  # POST /reset - Reset SDK state
  post "/reset" do
    try do
      stop_posthog()
      SdkComplianceAdapter.State.reset()
      json_response(conn, 200, %{success: true})
    rescue
      e ->
        json_response(conn, 500, %{success: false, error: Exception.message(e)})
    end
  end

  match _ do
    json_response(conn, 404, %{error: "Not found"})
  end

  # Helper functions

  defp json_response(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end

  defp build_config(params) do
    api_key = params["api_key"]
    host = params["host"]

    # Default values optimized for testing
    flush_at = params["flush_at"] || 1
    flush_interval_ms = params["flush_interval_ms"] || 100

    %{
      api_key: api_key,
      api_host: host,
      api_client_module: SdkComplianceAdapter.TrackedClient,
      supervisor_name: SdkComplianceAdapter.PostHog,
      max_batch_events: flush_at,
      max_batch_time_ms: flush_interval_ms,
      # Use a single sender for predictable testing
      sender_pool_size: 1
    }
  end

  defp start_posthog(config) do
    # Extract extra config that's not part of the validation schema
    extra_config = Map.take(config, [:max_batch_events, :max_batch_time_ms, :sender_pool_size])

    # Build the base config for validation
    base_config = [
      api_key: config.api_key,
      api_host: config.api_host,
      api_client_module: config.api_client_module,
      supervisor_name: config.supervisor_name
    ]

    # Validate and start PostHog supervisor
    case PostHog.Config.validate(base_config) do
      {:ok, validated_config} ->
        # Merge extra config after validation
        final_config = Map.merge(validated_config, extra_config)
        child_spec = {PostHog.Supervisor, final_config}
        DynamicSupervisor.start_child(SdkComplianceAdapter.DynamicSupervisor, child_spec)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stop_posthog do
    case Process.whereis(SdkComplianceAdapter.PostHog) do
      nil ->
        :ok

      pid ->
        # terminate_child can return :ok or {:error, :not_found}
        # We don't care about the result - just try to stop it
        _ = DynamicSupervisor.terminate_child(SdkComplianceAdapter.DynamicSupervisor, pid)
        :ok
    end
  rescue
    # Catch any errors during termination
    _ -> :ok
  end
end
