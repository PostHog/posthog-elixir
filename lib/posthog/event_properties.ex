defmodule PostHog.EventProperties do
  @moduledoc false

  def normalize(%{properties: properties} = event) do
    %{event | properties: normalize_properties(properties, event[:event])}
  end

  def normalize(%{"properties" => properties} = event) do
    %{event | "properties" => normalize_properties(properties, event["event"])}
  end

  def normalize(event), do: event

  defp normalize_properties(properties, event)
       when is_map(properties) and not is_struct(properties) do
    properties |> clean_pairs(event, &clean/1) |> Map.new()
  end

  defp normalize_properties(properties, event) when is_struct(properties) do
    case decode_encoded(properties) do
      %Jason.OrderedObject{values: pairs} ->
        pairs |> clean_pairs(event, &clean_encoded/1) |> Jason.OrderedObject.new()

      value ->
        clean_encoded(value)
    end
  end

  defp normalize_properties(properties, _event), do: clean(properties)

  defp clean_pairs(pairs, event, clean) do
    flag =
      Enum.find_value(pairs, fn {key, value} ->
        if key in [:"$feature_flag", "$feature_flag"], do: value
      end)

    Enum.flat_map(pairs, fn {key, value} ->
      preserve = preserve?(key, event, flag)
      value = if preserve, do: value, else: clean.(value)
      if preserve or value != nil, do: [{key, value}], else: []
    end)
  end

  # Preserve only producer-backed metadata, and never recreate privacy-filtered fields.
  defp preserve?(key, event, flag) when is_atom(key),
    do: preserve?(Atom.to_string(key), event, flag)

  defp preserve?("$exception_list", "$exception", _flag), do: true
  defp preserve?("$feature_flag_response", "$feature_flag_called", _flag), do: true

  defp preserve?(key, "$feature_flag_called", flag) when is_binary(flag),
    do: key == "$feature/" <> flag

  defp preserve?(_key, _event, _flag), do: false

  # A struct's JSON shape comes from its encoder, not its implementation fields.
  defp clean(value) when is_struct(value), do: value |> decode_encoded() |> clean_encoded()
  defp clean(value) when is_map(value), do: value |> clean_pairs(nil, &clean/1) |> Map.new()
  defp clean(value) when is_list(value), do: Enum.map(value, &clean/1)
  defp clean(value), do: value

  # Only decoded encoder output enters this traversal. Numeric fragments are already validated.
  defp clean_encoded(%Jason.OrderedObject{values: pairs}) do
    pairs |> clean_pairs(nil, &clean_encoded/1) |> Jason.OrderedObject.new()
  end

  defp clean_encoded(value) when is_list(value), do: Enum.map(value, &clean_encoded/1)
  defp clean_encoded(value), do: value

  # Shield scalar tokens from float conversion, not JSON structure. Complete strings match
  # first; every string gets a tag so caller strings cannot collide with numeric tokens.
  # Number boundaries forbid partial matches in 01, 1e+, etc. Jason still validates structure,
  # string escapes and adjacency; numeric object keys must not become accepted string keys.
  @scalar ~r/"(?:[^"\\]++|\\.)*+"|(?<![^\x20\t\r\n\[,:]) -?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)? (?=$|[\x20\t\r\n,\]}])/sx
  defp decode_encoded(value) do
    json = Jason.encode!(value)

    tagged =
      Regex.replace(@scalar, json, fn
        <<"\"", rest::binary>> -> "\"s" <> rest
        number -> "\"n" <> number <> "\""
      end)

    tagged
    |> Jason.decode!(
      objects: :ordered_objects,
      keys: fn
        <<"s", key::binary>> -> key
        _ -> raise Jason.DecodeError, data: json, position: 0
      end
    )
    |> restore_scalars()
  end

  defp restore_scalars(%Jason.OrderedObject{values: pairs}) do
    Jason.OrderedObject.new(Enum.map(pairs, fn {key, value} -> {key, restore_scalars(value)} end))
  end

  defp restore_scalars(value) when is_list(value), do: Enum.map(value, &restore_scalars/1)
  defp restore_scalars(<<"s", string::binary>>), do: string
  defp restore_scalars(<<"n", number::binary>>), do: Jason.Fragment.new(number)
  defp restore_scalars(value), do: value
end
