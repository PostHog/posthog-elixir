defmodule SdkComplianceAdapter.State do
  @moduledoc """
  Tracks SDK state for test assertions.
  """
  use Agent

  defstruct [
    :config,
    total_events_captured: 0,
    total_events_sent: 0,
    total_retries: 0,
    pending_events: 0,
    last_error: nil,
    requests_made: []
  ]

  def start_link(_opts) do
    Agent.start_link(fn -> %__MODULE__{} end, name: __MODULE__)
  end

  def get do
    Agent.get(__MODULE__, & &1)
  end

  def reset do
    Agent.update(__MODULE__, fn _ -> %__MODULE__{} end)
  end

  def set_config(config) do
    Agent.update(__MODULE__, fn state -> %{state | config: config} end)
  end

  def get_config do
    Agent.get(__MODULE__, & &1.config)
  end

  def increment_events_captured do
    Agent.update(__MODULE__, fn state ->
      %{state | total_events_captured: state.total_events_captured + 1, pending_events: state.pending_events + 1}
    end)
  end

  def record_request(status_code, event_count, uuid_list) do
    Agent.update(__MODULE__, fn state ->
      retry_attempt =
        state.requests_made
        |> Enum.count(fn req -> req.uuid_list != [] and req.uuid_list == uuid_list end)

      is_retry = retry_attempt > 0

      request_info = %{
        timestamp_ms: System.system_time(:millisecond),
        status_code: status_code,
        retry_attempt: retry_attempt,
        event_count: event_count,
        uuid_list: uuid_list
      }

      new_state = %{
        state
        | requests_made: state.requests_made ++ [request_info],
          total_retries: if(is_retry, do: state.total_retries + 1, else: state.total_retries)
      }

      if status_code in 200..299 do
        %{
          new_state
          | total_events_sent: state.total_events_sent + event_count,
            pending_events: max(0, state.pending_events - event_count)
        }
      else
        new_state
      end
    end)
  end

  def set_last_error(error) do
    Agent.update(__MODULE__, fn state -> %{state | last_error: error} end)
  end
end
