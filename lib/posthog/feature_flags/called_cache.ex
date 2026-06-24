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

    Agent.get_and_update(PostHog.Registry.via(supervisor_name, __MODULE__), fn seen ->
      cond do
        MapSet.member?(seen, key) ->
          {false, seen}

        MapSet.size(seen) >= @max_size ->
          {true, MapSet.new([key])}

        true ->
          {true, MapSet.put(seen, key)}
      end
    end)
  rescue
    error in ArgumentError ->
      if String.starts_with?(Exception.message(error), "unknown registry: ") do
        true
      else
        reraise(error, __STACKTRACE__)
      end
  catch
    :exit, _ -> true
  end
end
