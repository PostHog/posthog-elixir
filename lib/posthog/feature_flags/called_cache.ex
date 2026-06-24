defmodule PostHog.FeatureFlags.CalledCache do
  @moduledoc false

  use Agent

  @max_size 50_000

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts) do
    supervisor_name = Keyword.fetch!(opts, :supervisor_name)

    Agent.start_link(fn -> MapSet.new() end,
      name: PostHog.Registry.via(supervisor_name, __MODULE__)
    )
  end

  @spec first_seen?(PostHog.supervisor_name(), PostHog.distinct_id(), String.t(), any()) ::
          boolean()
  def first_seen?(supervisor_name, distinct_id, flag_key, value) do
    key = {to_string(distinct_id), flag_key, value}

    case cache_pid(supervisor_name) do
      nil ->
        true

      pid ->
        Agent.get_and_update(pid, &mark_seen(&1, key))
    end
  catch
    :exit, _ -> true
  end

  defp mark_seen(seen, key) do
    cond do
      MapSet.member?(seen, key) ->
        {false, seen}

      MapSet.size(seen) >= @max_size ->
        # Intentionally flush instead of evicting individual entries to keep
        # the hot path simple. Previously seen values may emit again after
        # the cache rolls over.
        {true, MapSet.new([key])}

      true ->
        {true, MapSet.put(seen, key)}
    end
  end

  defp cache_pid(supervisor_name) do
    registry_name = PostHog.Registry.registry_name(supervisor_name)

    with registry_pid when is_pid(registry_pid) <- Process.whereis(registry_name),
         [{pid, _value}] <- Registry.lookup(registry_name, __MODULE__) do
      pid
    else
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end
end
