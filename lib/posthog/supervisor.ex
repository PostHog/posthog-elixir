defmodule PostHog.Supervisor do
  @moduledoc """
  Supervisor that manages the processes required for PostHog event capture.

  By default, `PostHog` starts this supervisor automatically from the `:posthog`
  application configuration. Start it yourself when you need a custom supervision
  tree or multiple PostHog instances.
  """
  use Supervisor

  @doc """
  Returns a child specification for a PostHog supervision tree.

  ## Parameters

  - `config` - validated `t:PostHog.Config.config/0` for the instance.

  ## Returns

  A `t:Supervisor.child_spec/0` that can be included in your application's
  children list.
  """
  @spec child_spec(PostHog.Config.config()) :: Supervisor.child_spec()
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

  @doc """
  Starts a PostHog supervision tree from a validated config.

  ## Parameters

  - `config` - validated `t:PostHog.Config.config/0`. Use
    `PostHog.Config.validate!/1` before calling this function with raw options.

  ## Returns

  Returns the standard `t:Supervisor.on_start/0` tuple.
  """
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
         meta: [config: config]}
      ] ++ senders(config) ++ sources(config)

    Process.put(:"$callers", callers)

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp sources(%{enabled: false}), do: []

  defp sources(config) do
    if config.enable_source_code_context do
      opts = [
        supervisor_name: config.supervisor_name,
        root_source_code_paths: config.root_source_code_paths,
        source_code_path_pattern: config.source_code_path_pattern,
        source_code_exclude_patterns: config.source_code_exclude_patterns,
        source_code_map_path: Map.get(config, :source_code_map_path)
      ]

      [{PostHog.ErrorTracking.Sources, opts}]
    else
      []
    end
  end

  defp senders(%{enabled: false}), do: []

  defp senders(config) do
    pool_size = Map.get(config, :sender_pool_size, max(System.schedulers_online(), 2))

    for index <- 1..pool_size do
      Supervisor.child_spec(
        {PostHog.Sender,
         [
           api_client: config.api_client,
           supervisor_name: config.supervisor_name,
           max_batch_time_ms: Map.get(config, :max_batch_time_ms, :timer.seconds(10)),
           max_batch_events: Map.get(config, :max_batch_events, 100),
           test_mode: config.test_mode,
           index: index
         ]},
        id: {PostHog.Sender, index}
      )
    end
  end
end
