defmodule PostHog.FeatureFlags.CalledCache do
  @moduledoc false

  use GenServer

  @max_size 50_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    supervisor_name = Keyword.fetch!(opts, :supervisor_name)

    GenServer.start_link(__MODULE__, supervisor_name,
      name: PostHog.Registry.via(supervisor_name, __MODULE__)
    )
  end

  @impl GenServer
  def init(supervisor_name) do
    table =
      supervisor_name
      |> table_name()
      |> :ets.new([
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])

    {:ok, %{table: table}}
  end

  @spec first_seen?(PostHog.supervisor_name(), PostHog.distinct_id(), String.t(), any()) ::
          boolean()
  def first_seen?(supervisor_name, distinct_id, flag_key, value) do
    key = {to_string(distinct_id), flag_key, value}
    table = table_name(supervisor_name)

    case :ets.insert_new(table, {key}) do
      true ->
        rollover_if_full(supervisor_name, table, key)
        true

      false ->
        false
    end
  rescue
    ArgumentError -> true
  catch
    :exit, _ -> true
  end

  @impl GenServer
  def handle_call({:rollover, key}, _from, %{table: table} = state) do
    if over_max_size?(table) do
      # Intentionally flush instead of evicting individual entries to keep
      # the hot path simple. Previously seen values may emit again after
      # the cache rolls over.
      :ets.delete_all_objects(table)
      :ets.insert(table, {key})
    end

    {:reply, :ok, state}
  end

  defp rollover_if_full(supervisor_name, table, key) do
    if over_max_size?(table) do
      GenServer.call(PostHog.Registry.via(supervisor_name, __MODULE__), {:rollover, key})
    end
  end

  defp over_max_size?(table) do
    case :ets.info(table, :size) do
      size when is_integer(size) -> size > @max_size
      _ -> false
    end
  end

  defp table_name(supervisor_name), do: Module.concat(supervisor_name, CalledCacheTable)
end
