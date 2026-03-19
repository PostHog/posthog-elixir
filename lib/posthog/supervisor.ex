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
         meta: [config: config]}
      ] ++ senders(config) ++ sources(config)

    Process.put(:"$callers", callers)

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp sources(config) do
    if config.enable_source_code_context do
      opts =
        [
          root_source_code_paths: config.root_source_code_paths,
          source_code_path_pattern: config.source_code_path_pattern,
          source_code_exclude_patterns: config.source_code_exclude_patterns,
          context_lines: config.context_lines
        ]

      opts =
        case Map.get(config, :source_code_map_path) do
          nil -> opts
          path -> Keyword.put(opts, :source_code_map_path, path)
        end

      [{PostHog.ErrorTracking.Sources, opts}]
    else
      []
    end
  end

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
