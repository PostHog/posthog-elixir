defmodule PostHog.Context do
  @moduledoc false

  @logger_metadata_key :__posthog__

  def set(name_scope, event_scope \\ :all, context) do
    metadata =
      with :undefined <- :logger.get_process_metadata(), do: %{}

    current_context = Map.get(metadata, @logger_metadata_key, %{})

    new_value =
      case get_in(current_context, [name_scope, event_scope]) do
        %{} = existing -> Map.merge(existing, context)
        nil -> context
      end

    updated_context =
      put_in(
        current_context,
        [Access.key(name_scope, %{}), Access.key(event_scope, %{})],
        new_value
      )

    :logger.update_process_metadata(%{@logger_metadata_key => updated_context})
  end

  def get(name_scope, event_scope \\ :all) do
    case :logger.get_process_metadata() do
      %{@logger_metadata_key => context} ->
        get_in(context, [key_and_all(name_scope), key_and_all(event_scope)]) |> Map.new()

      _ ->
        %{}
    end
  end

  defp key_and_all(key) do
    fn :get, data, next ->
      scoped = Map.get(data, key, %{})
      all = Map.get(data, :all, %{})
      Enum.flat_map([all, scoped], next)
    end
  end
end
