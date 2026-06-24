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
    table = table(supervisor_name)

    full_cache =
      1..(@max_size - 1)
      |> Enum.map(&{{"user-#{&1}", "flag", true}})
      |> then(&[{seed_key} | &1])

    :ets.insert(table, full_cache)

    refute CalledCache.first_seen?(supervisor_name, "seed-user", "flag", true)

    assert CalledCache.first_seen?(supervisor_name, "overflow-user", "flag", true)
    assert CalledCache.first_seen?(supervisor_name, "seed-user", "flag", true)
    refute CalledCache.first_seen?(supervisor_name, "overflow-user", "flag", true)
  end

  defp table(supervisor_name) do
    [{pid, _value}] =
      Registry.lookup(PostHog.Registry.registry_name(supervisor_name), CalledCache)

    pid
    |> :sys.get_state()
    |> Map.fetch!(:table)
  end
end
