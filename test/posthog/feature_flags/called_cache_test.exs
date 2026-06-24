defmodule PostHog.FeatureFlags.CalledCacheTest do
  use PostHog.Case, async: true

  alias PostHog.FeatureFlags.CalledCache

  @max_size 50_000

  setup :setup_supervisor

  test "returns true when the supervisor registry is not running" do
    supervisor_name = __MODULE__.MissingSupervisor

    refute Process.whereis(PostHog.Registry.registry_name(supervisor_name))

    assert CalledCache.first_seen?(supervisor_name, "user", "flag", true)
  end

  test "flushes the cache when it reaches the maximum size", %{config: config} do
    supervisor_name = config.supervisor_name
    seed_key = {"seed-user", "flag", true}

    full_cache =
      1..(@max_size - 1)
      |> Enum.map(&{"user-#{&1}", "flag", true})
      |> MapSet.new()
      |> MapSet.put(seed_key)

    Agent.update(PostHog.Registry.via(supervisor_name, CalledCache), fn _seen -> full_cache end)

    refute CalledCache.first_seen?(supervisor_name, "seed-user", "flag", true)

    assert CalledCache.first_seen?(supervisor_name, "overflow-user", "flag", true)
    assert CalledCache.first_seen?(supervisor_name, "seed-user", "flag", true)
    refute CalledCache.first_seen?(supervisor_name, "overflow-user", "flag", true)
  end
end
