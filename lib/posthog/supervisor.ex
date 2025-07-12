defmodule PostHog.Supervisor do
  @moduledoc """
  Supervisor that manages all processes required for logging. By default,
  `PostHog` starts it automatically.
  """
  use Supervisor

  def child_spec(config) do
    Supervisor.child_spec(
      %{
        id: config.supervisor_name,
        start: {__MODULE__, :start_link, [config]},
        type: :supervisor
      },
      []
    )
  end

  @spec start_link(PostHog.Config.config()) :: Supervisor.on_start()
  def start_link(config) do
    callers = Process.get(:"$callers", [])
    Supervisor.start_link(__MODULE__, {config, callers}, name: config.supervisor_name)
  end

  @impl Supervisor
  def init({config, callers}) do
    children =
      [
        {Registry,
         keys: :unique,
         name: PostHog.Registry.registry_name(config.supervisor_name),
         meta: [config: config]},
        {PostHog.Sender,
         [
           api_client: config.api_client,
           supervisor_name: config.supervisor_name,
           max_batch_time_ms: Map.get(config, :max_batch_time_ms, to_timeout(second: 10)),
           max_batch_events: Map.get(config, :max_batch_events, 100)
         ]}
      ]

    Process.put(:"$callers", callers)

    Supervisor.init(children, strategy: :one_for_one)
  end
end
