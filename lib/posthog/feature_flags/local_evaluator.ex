# The evaluator mirrors a recursive, tri-state rules language. Keeping each rules
# branch explicit is safer and more discoverable than hiding it behind dynamic dispatch.
# credo:disable-for-this-file Credo.Check.Readability.WithSingleClause
# credo:disable-for-this-file Credo.Check.Refactor.CyclomaticComplexity
# credo:disable-for-this-file Credo.Check.Refactor.FunctionArity
# credo:disable-for-this-file Credo.Check.Refactor.Nesting
defmodule PostHog.FeatureFlags.LocalEvaluator do
  @moduledoc false

  alias PostHog.FeatureFlags.Result

  @long_scale 0xFFFFFFFFFFFFFFF
  @semver_operators ~w(semver_eq semver_neq semver_gt semver_gte semver_lt semver_lte semver_tilde semver_caret semver_wildcard)

  @type outcome :: {:ok, boolean() | String.t()} | :inconclusive | :requires_server

  @spec evaluate(map(), map(), [String.t()] | nil) :: %{
          results: %{String.t() => Result.t()},
          unresolved: MapSet.t(String.t())
        }
  def evaluate(definitions, context, keys \\ nil) do
    keys = keys || Map.keys(definitions.flags_by_key)
    context = normalize_context(context)

    {results, unresolved, _cache} =
      Enum.reduce(keys, {%{}, MapSet.new(), %{}}, fn key, {results, unresolved, cache} ->
        case Map.fetch(definitions.flags_by_key, key) do
          {:ok, flag} ->
            {outcome, cache} = evaluate_key(key, flag, definitions, context, cache)

            case outcome do
              {:ok, value} ->
                {Map.put(results, key, build_result(key, flag, value, definitions)), unresolved,
                 cache}

              status when status in [:inconclusive, :requires_server] ->
                {results, MapSet.put(unresolved, key), cache}
            end

          :error ->
            {results, MapSet.put(unresolved, key), cache}
        end
      end)

    %{results: results, unresolved: unresolved}
  end

  @doc false
  @spec hash(String.t(), String.t(), String.t()) :: float()
  def hash(key, bucketing_value, salt \\ "") do
    <<prefix::binary-size(15), _::binary>> =
      :crypto.hash(:sha, "#{key}.#{bucketing_value}#{salt}") |> Base.encode16(case: :lower)

    {integer, ""} = Integer.parse(prefix, 16)
    integer / @long_scale
  end

  defp normalize_context(context) do
    distinct_id = context_value(context, :distinct_id)
    groups = context_value(context, :groups) || %{}

    person_properties =
      context
      |> context_value(:person_properties)
      |> Kernel.||(%{})
      |> put_default_property("distinct_id", distinct_id)

    group_properties =
      Enum.reduce(groups, context_value(context, :group_properties) || %{}, fn
        {group_type, group_key}, properties when is_map(properties) ->
          group_type = to_string(group_type)
          focused = map_value(properties, group_type) || %{}
          Map.put(properties, group_type, put_default_property(focused, "$group_key", group_key))

        _group, properties ->
          properties
      end)

    %{
      distinct_id: distinct_id,
      groups: groups,
      person_properties: person_properties,
      group_properties: group_properties,
      device_id: context_value(context, :device_id),
      now: context_value(context, :now) || DateTime.utc_now()
    }
  end

  defp put_default_property(properties, key, value) when is_map(properties) do
    case map_fetch(properties, key) do
      :error -> Map.put(properties, key, value)
      {:ok, _existing} -> properties
    end
  end

  defp put_default_property(_properties, key, value), do: %{key => value}

  defp context_value(context, key),
    do: Map.get(context, key, Map.get(context, Atom.to_string(key)))

  defp evaluate_key(key, flag, definitions, context, cache) do
    case Map.get(cache, key) do
      :resolving ->
        {:inconclusive, cache}

      {:done, outcome} ->
        {outcome, cache}

      nil ->
        cache = Map.put(cache, key, :resolving)
        {outcome, cache} = evaluate_flag(flag, definitions, context, cache)
        {outcome, Map.put(cache, key, {:done, outcome})}
    end
  rescue
    _exception -> {:inconclusive, Map.put(cache, key, {:done, :inconclusive})}
  catch
    _kind, _reason -> {:inconclusive, Map.put(cache, key, {:done, :inconclusive})}
  end

  defp evaluate_flag(flag, definitions, context, cache) when is_map(flag) do
    cond do
      value(flag, "active") == false ->
        {{:ok, false}, cache}

      value(flag, "active") != true ->
        {:inconclusive, cache}

      value(flag, "ensure_experience_continuity") == true ->
        {:requires_server, cache}

      not is_binary(value(flag, "key")) or not is_map(value(flag, "filters")) ->
        {:inconclusive, cache}

      true ->
        evaluate_active_flag(flag, definitions, context, cache)
    end
  end

  defp evaluate_flag(_flag, _definitions, _context, cache), do: {:inconclusive, cache}

  defp evaluate_active_flag(flag, definitions, context, cache) do
    filters = value(flag, "filters")
    aggregation = value(filters, "aggregation_group_type_index")

    with {:ok, properties, bucketing} <-
           evaluation_target(aggregation, flag, definitions, context) do
      conditions = value(filters, "groups") || []

      if is_list(conditions) do
        evaluate_conditions(
          conditions,
          flag,
          aggregation,
          properties,
          bucketing,
          definitions,
          context,
          cache,
          false
        )
      else
        {:inconclusive, cache}
      end
    else
      status when status in [:inconclusive, :requires_server] -> {status, cache}
    end
  end

  defp evaluation_target(nil, flag, _definitions, context) do
    case bucketing_value(flag, context) do
      {:ok, bucketing} -> {:ok, context.person_properties, bucketing}
      status -> status
    end
  end

  defp evaluation_target(index, _flag, definitions, context) do
    group_name = map_value(definitions.group_type_mapping, to_string(index))
    group_key = if is_binary(group_name), do: map_value(context.groups, group_name)
    properties = if is_binary(group_name), do: map_value(context.group_properties, group_name)

    cond do
      not is_binary(group_name) or is_nil(group_key) -> :inconclusive
      not is_map(properties) -> :inconclusive
      true -> {:ok, properties, to_string(group_key)}
    end
  end

  defp bucketing_value(flag, context) do
    filters = value(flag, "filters") || %{}
    identifier = value(flag, "bucketing_identifier") || value(filters, "bucketing_identifier")

    case identifier do
      "device_id" when is_binary(context.device_id) and context.device_id != "" ->
        {:ok, context.device_id}

      "device_id" ->
        :inconclusive

      _ when is_binary(context.distinct_id) ->
        {:ok, context.distinct_id}

      _ ->
        :inconclusive
    end
  end

  defp evaluate_conditions(
         [],
         _flag,
         _aggregation,
         _properties,
         _bucketing,
         _definitions,
         _context,
         cache,
         inconclusive?
       ) do
    {if(inconclusive?, do: :inconclusive, else: {:ok, false}), cache}
  end

  defp evaluate_conditions(
         [condition | rest],
         flag,
         aggregation,
         properties,
         bucketing,
         definitions,
         context,
         cache,
         inconclusive?
       ) do
    case condition_target(
           condition,
           aggregation,
           properties,
           bucketing,
           flag,
           definitions,
           context
         ) do
      {:ok, effective_properties, effective_bucketing} ->
        {match, cache} =
          condition_match(
            condition,
            flag,
            effective_properties,
            effective_bucketing,
            definitions,
            context,
            cache
          )

        case match do
          :match ->
            value = matching_value(flag, condition, effective_bucketing)
            {{:ok, value}, cache}

          :out_of_rollout ->
            if value(value(flag, "filters"), "early_exit") == true and not inconclusive? do
              {{:ok, false}, cache}
            else
              evaluate_conditions(
                rest,
                flag,
                aggregation,
                properties,
                bucketing,
                definitions,
                context,
                cache,
                inconclusive?
              )
            end

          :no_match ->
            evaluate_conditions(
              rest,
              flag,
              aggregation,
              properties,
              bucketing,
              definitions,
              context,
              cache,
              inconclusive?
            )

          :inconclusive ->
            evaluate_conditions(
              rest,
              flag,
              aggregation,
              properties,
              bucketing,
              definitions,
              context,
              cache,
              true
            )

          :requires_server ->
            {:requires_server, cache}
        end

      :skip ->
        evaluate_conditions(
          rest,
          flag,
          aggregation,
          properties,
          bucketing,
          definitions,
          context,
          cache,
          inconclusive?
        )

      :inconclusive ->
        evaluate_conditions(
          rest,
          flag,
          aggregation,
          properties,
          bucketing,
          definitions,
          context,
          cache,
          true
        )
    end
  end

  defp condition_target(condition, aggregation, properties, bucketing, flag, definitions, context)
       when is_map(condition) do
    condition_aggregation =
      if has_key?(condition, "aggregation_group_type_index") do
        value(condition, "aggregation_group_type_index")
      else
        aggregation
      end

    if condition_aggregation == aggregation do
      {:ok, properties, bucketing}
    else
      case condition_aggregation do
        nil ->
          case bucketing_value(flag, context) do
            {:ok, person_bucketing} -> {:ok, context.person_properties, person_bucketing}
            _ -> :inconclusive
          end

        index ->
          group_name = map_value(definitions.group_type_mapping, to_string(index))
          group_key = if is_binary(group_name), do: map_value(context.groups, group_name)

          group_props =
            if is_binary(group_name), do: map_value(context.group_properties, group_name)

          cond do
            is_nil(group_key) -> :skip
            not is_map(group_props) -> :inconclusive
            true -> {:ok, group_props, to_string(group_key)}
          end
      end
    end
  end

  defp condition_target(
         _condition,
         _aggregation,
         _properties,
         _bucketing,
         _flag,
         _definitions,
         _context
       ),
       do: :inconclusive

  defp condition_match(condition, flag, properties, bucketing, definitions, context, cache) do
    property_filters = value(condition, "properties") || []

    if is_list(property_filters) do
      {property_result, cache} =
        match_all_properties(property_filters, properties, definitions, context, cache)

      case property_result do
        :match -> rollout_match(condition, flag, bucketing, cache)
        other -> {other, cache}
      end
    else
      {:inconclusive, cache}
    end
  end

  defp rollout_match(condition, flag, bucketing, cache) do
    case value(condition, "rollout_percentage") do
      nil ->
        {:match, cache}

      percentage when is_number(percentage) and percentage >= 100 ->
        {:match, cache}

      percentage when is_number(percentage) and percentage <= 0 ->
        {:out_of_rollout, cache}

      percentage when is_number(percentage) ->
        result =
          if hash(value(flag, "key"), bucketing) < percentage / 100,
            do: :match,
            else: :out_of_rollout

        {result, cache}

      _ ->
        {:inconclusive, cache}
    end
  end

  defp match_all_properties(properties, property_values, definitions, context, cache) do
    Enum.reduce_while(properties, {:match, cache}, fn property, {aggregate, cache} ->
      {result, cache} =
        match_typed_property(property, property_values, definitions, context, cache)

      case result do
        :no_match -> {:halt, {:no_match, cache}}
        :requires_server -> {:halt, {:requires_server, cache}}
        :inconclusive -> {:cont, {:inconclusive, cache}}
        :match -> {:cont, {aggregate, cache}}
      end
    end)
  end

  defp match_typed_property(property, property_values, definitions, context, cache)
       when is_map(property) do
    {result, cache} =
      case value(property, "type") do
        "cohort" -> {match_cohort(property, property_values, definitions, context, cache), cache}
        "flag" -> match_dependency(property, definitions, context, cache)
        _ -> {match_property(property, property_values, context.now), cache}
      end

    {apply_negation(result, value(property, "negation") == true), cache}
  end

  defp match_typed_property(_property, _values, _definitions, _context, cache),
    do: {:inconclusive, cache}

  defp apply_negation(:match, true), do: :no_match
  defp apply_negation(:no_match, true), do: :match
  defp apply_negation(result, _negation), do: result

  defp match_dependency(property, definitions, context, cache) do
    key = value(property, "key")
    expected = value(property, "value")

    cond do
      value(property, "operator") != "flag_evaluates_to" ->
        {:no_match, cache}

      not is_binary(key) or is_nil(expected) ->
        {:no_match, cache}

      not has_key?(property, "dependency_chain") or value(property, "dependency_chain") == [] ->
        {:inconclusive, cache}

      not is_list(value(property, "dependency_chain")) or
          not Enum.all?(value(property, "dependency_chain"), &is_binary/1) ->
        {:inconclusive, cache}

      true ->
        case evaluate_dependency_chain(
               value(property, "dependency_chain"),
               definitions,
               context,
               cache
             ) do
          {:ok, cache} -> dependency_result(key, expected, cache)
          {:error, cache} -> {:inconclusive, cache}
        end
    end
  end

  defp evaluate_dependency_chain([], _definitions, _context, cache), do: {:ok, cache}

  defp evaluate_dependency_chain([key | rest], definitions, context, cache) do
    case Map.get(cache, key) do
      {:done, {:ok, _value}} ->
        evaluate_dependency_chain(rest, definitions, context, cache)

      {:done, _outcome} ->
        {:error, cache}

      :resolving ->
        {:error, cache}

      nil ->
        case Map.fetch(definitions.flags_by_key, key) do
          :error ->
            {:error, Map.put(cache, key, {:done, :inconclusive})}

          {:ok, dependency} ->
            {outcome, cache} = evaluate_key(key, dependency, definitions, context, cache)

            case outcome do
              {:ok, _value} -> evaluate_dependency_chain(rest, definitions, context, cache)
              _other -> {:error, cache}
            end
        end
    end
  end

  defp dependency_result(key, expected, cache) do
    case Map.get(cache, key) do
      {:done, {:ok, actual}} ->
        {if(dependency_matches?(expected, actual), do: :match, else: :no_match), cache}

      _other ->
        {:inconclusive, cache}
    end
  end

  defp dependency_matches?(expected, actual) when is_binary(actual) and actual != "" do
    (is_boolean(expected) and expected) or (is_binary(expected) and expected == actual)
  end

  defp dependency_matches?(expected, actual) when is_boolean(expected) and is_boolean(actual),
    do: expected == actual

  defp dependency_matches?(_expected, _actual), do: false

  defp match_cohort(property, property_values, definitions, context, cache) do
    cohort_id = to_string(value(property, "value"))

    case map_fetch(definitions.cohorts, cohort_id) do
      :error ->
        :requires_server

      {:ok, group} ->
        result = match_property_group(group, property_values, definitions, context, cache)

        case value(property, "operator") || "exact" do
          operator when operator in ["exact", "in"] -> result
          "not_in" -> apply_negation(result, true)
          _ -> :inconclusive
        end
    end
  end

  defp match_property_group(group, _property_values, _definitions, _context, _cache)
       when group == %{},
       do: :match

  defp match_property_group(group, property_values, definitions, context, cache)
       when is_map(group) do
    type = value(group, "type")
    values = value(group, "values")

    if type in ["AND", "OR"] and is_list(values) do
      match_group_values(type, values, property_values, definitions, context, cache)
    else
      :requires_server
    end
  end

  defp match_property_group(_group, _property_values, _definitions, _context, _cache),
    do: :requires_server

  defp match_group_values(_type, [], _properties, _definitions, _context, _cache), do: :match

  defp match_group_values(type, values, properties, definitions, context, cache) do
    results =
      Enum.map(values, fn entry ->
        if is_map(entry) and (entry == %{} or has_key?(entry, "values")) do
          entry
          |> match_property_group(properties, definitions, context, cache)
          |> apply_negation(value(entry, "negation") == true)
        else
          {result, _cache} = match_typed_property(entry, properties, definitions, context, cache)
          result
        end
      end)

    combine_group_results(type, results)
  end

  defp combine_group_results("AND", results) do
    cond do
      :requires_server in results -> :requires_server
      :no_match in results -> :no_match
      :inconclusive in results -> :inconclusive
      true -> :match
    end
  end

  defp combine_group_results("OR", results) do
    cond do
      :requires_server in results -> :requires_server
      :match in results -> :match
      :inconclusive in results -> :inconclusive
      true -> :no_match
    end
  end

  defp match_property(property, property_values, now) do
    key = value(property, "key")
    operator = value(property, "operator") || "exact"
    filter_value = value(property, "value")

    case map_fetch(property_values, key) do
      :error ->
        :inconclusive

      {:ok, property_value} ->
        apply_operator(operator, property_value, filter_value, now)
    end
  end

  defp apply_operator("is_set", nil, _filter, _now), do: :no_match
  defp apply_operator("is_set", _property, _filter, _now), do: :match
  defp apply_operator("is_not_set", _property, _filter, _now), do: :no_match

  defp apply_operator("is_not", nil, filter, _now) do
    match = if is_list(filter), do: nil in filter, else: is_nil(filter)
    boolean_result(not match)
  end

  defp apply_operator(_operator, nil, _filter, _now), do: :no_match

  defp apply_operator(operator, property, filter, _now) when operator in ["exact", "is_not"] do
    match =
      if is_list(filter) do
        Enum.any?(filter, &case_insensitive_equal?(property, &1))
      else
        case_insensitive_equal?(property, filter)
      end

    boolean_result(if(operator == "exact", do: match, else: not match))
  end

  defp apply_operator(operator, property, filter, _now)
       when operator in [
              "icontains",
              "not_icontains",
              "starts_with",
              "not_starts_with",
              "ends_with",
              "not_ends_with"
            ] do
    property = ascii_downcase(to_string(property))
    filter = ascii_downcase(to_string(filter))

    positive =
      case operator do
        op when op in ["icontains", "not_icontains"] -> String.contains?(property, filter)
        op when op in ["starts_with", "not_starts_with"] -> String.starts_with?(property, filter)
        _ -> String.ends_with?(property, filter)
      end

    negative? = operator in ["not_icontains", "not_starts_with", "not_ends_with"]
    boolean_result(if(negative?, do: not positive, else: positive))
  end

  defp apply_operator(operator, property, filter, _now) when operator in ["regex", "not_regex"] do
    case Regex.compile(to_string(filter)) do
      {:ok, regex} ->
        matched = Regex.match?(regex, to_string(property))
        boolean_result(if(operator == "regex", do: matched, else: not matched))

      {:error, _reason} ->
        :inconclusive
    end
  end

  defp apply_operator(operator, property, filter, _now)
       when operator in ["gt", "gte", "lt", "lte"] do
    with {:ok, left} <- number(property), {:ok, right} <- number(filter) do
      compare(operator, left, right)
    else
      _ -> :inconclusive
    end
  end

  defp apply_operator(operator, property, filter, now)
       when operator in ["is_date_before", "is_date_after"] do
    with {:ok, left} <- parse_datetime(property, now),
         {:ok, right} <- parse_datetime(filter, now) do
      comparison = DateTime.compare(left, right)

      boolean_result(
        if(operator == "is_date_before", do: comparison == :lt, else: comparison == :gt)
      )
    else
      _ -> :inconclusive
    end
  end

  defp apply_operator(operator, property, filter, _now) when operator in @semver_operators do
    semver_match(operator, property, filter)
  end

  defp apply_operator(_operator, _property, _filter, _now), do: :inconclusive

  defp matching_value(flag, condition, bucketing) do
    variants = variants(flag)
    override = value(condition, "variant")

    cond do
      is_binary(override) and Enum.any?(variants, &(value(&1, "key") == override)) -> override
      variants == [] -> true
      true -> matching_variant(flag, variants, bucketing) || true
    end
  end

  defp matching_variant(flag, variants, bucketing) do
    target = hash(value(flag, "key"), bucketing, "variant")

    Enum.reduce_while(variants, 0.0, fn variant, lower ->
      percentage = value(variant, "rollout_percentage")

      if is_number(percentage) do
        upper = lower + percentage / 100

        if target >= lower and target < upper,
          do: {:halt, value(variant, "key")},
          else: {:cont, upper}
      else
        {:halt, nil}
      end
    end)
  end

  defp variants(flag) do
    with filters when is_map(filters) <- value(flag, "filters"),
         multivariate when is_map(multivariate) <- value(filters, "multivariate"),
         variants when is_list(variants) <- value(multivariate, "variants") do
      variants
    else
      _ -> []
    end
  end

  defp build_result(key, flag, value, definitions) do
    enabled = value != false
    variant = if is_binary(value), do: value
    payload_key = if is_binary(value), do: value, else: to_string(value)
    payloads = value(value(flag, "filters") || %{}, "payloads") || %{}
    payload = payloads |> map_value(payload_key) |> decode_payload()

    %Result{
      key: key,
      enabled: enabled,
      variant: variant,
      payload: payload,
      id: value(flag, "id"),
      version: value(flag, "version"),
      has_experiment: boolean_or_nil(value(flag, "has_experiment")),
      minimal_flag_called_events: definitions.minimal_flag_called_events
    }
  end

  defp decode_payload(nil), do: nil

  defp decode_payload(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> payload
    end
  end

  defp decode_payload(payload), do: payload

  defp boolean_or_nil(value) when is_boolean(value), do: value
  defp boolean_or_nil(_value), do: nil
  defp boolean_result(true), do: :match
  defp boolean_result(false), do: :no_match

  defp case_insensitive_equal?(left, right),
    do: ascii_downcase(to_string(left)) == ascii_downcase(to_string(right))

  defp ascii_downcase(value) do
    for <<character <- value>>, into: "" do
      if character in ?A..?Z, do: <<character + 32>>, else: <<character>>
    end
  end

  defp number(value) when is_number(value), do: {:ok, value}

  defp number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> {:ok, number}
      _ -> :error
    end
  end

  defp number(_value), do: :error

  defp compare("gt", left, right), do: boolean_result(left > right)
  defp compare("gte", left, right), do: boolean_result(left >= right)
  defp compare("lt", left, right), do: boolean_result(left < right)
  defp compare("lte", left, right), do: boolean_result(left <= right)

  defp parse_datetime(%DateTime{} = datetime, _now), do: {:ok, datetime}

  defp parse_datetime(%NaiveDateTime{} = datetime, _now),
    do: DateTime.from_naive(datetime, "Etc/UTC")

  defp parse_datetime(%Date{} = date, _now) do
    date |> NaiveDateTime.new!(~T[00:00:00]) |> DateTime.from_naive("Etc/UTC")
  end

  defp parse_datetime(value, now) when is_binary(value) do
    case Regex.run(~r/^-?(\d+)([hdwmy])$/, value) do
      [_, amount, unit] ->
        shift_relative_datetime(now, String.to_integer(amount), unit)

      nil ->
        parse_iso_datetime(value)
    end
  end

  defp parse_datetime(_value, _now), do: :error

  defp shift_relative_datetime(_now, amount, _unit) when amount >= 10_000, do: :error

  defp shift_relative_datetime(now, amount, unit) when unit in ["h", "d", "w"] do
    seconds = amount * Map.fetch!(%{"h" => 3_600, "d" => 86_400, "w" => 604_800}, unit)
    {:ok, DateTime.add(now, -seconds, :second)}
  end

  defp shift_relative_datetime(now, amount, "m"),
    do: {:ok, DateTime.shift(now, month: -amount)}

  defp shift_relative_datetime(now, amount, "y"),
    do: {:ok, DateTime.shift(now, year: -amount)}

  defp parse_iso_datetime(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        {:ok, datetime}

      {:error, _reason} ->
        parse_timezone_less_datetime(value)
    end
  end

  defp parse_timezone_less_datetime(value) do
    normalized = String.replace(value, " ", "T", global: false)

    case NaiveDateTime.from_iso8601(normalized) do
      {:ok, datetime} ->
        DateTime.from_naive(datetime, "Etc/UTC")

      {:error, _reason} ->
        case Date.from_iso8601(value) do
          {:ok, date} -> parse_datetime(date, nil)
          {:error, _reason} -> :error
        end
    end
  end

  defp semver_match(operator, property, filter) do
    with {:ok, actual} <- parse_semver(property) do
      case operator do
        "semver_wildcard" ->
          semver_range(actual, wildcard_bounds(filter))

        "semver_tilde" ->
          semver_range(actual, tilde_bounds(filter))

        "semver_caret" ->
          semver_range(actual, caret_bounds(filter))

        _ ->
          with {:ok, expected} <- parse_semver(filter) do
            ordering = compare_semver(actual, expected)

            boolean_result(
              case operator do
                "semver_eq" -> ordering == :eq
                "semver_neq" -> ordering != :eq
                "semver_gt" -> ordering == :gt
                "semver_gte" -> ordering in [:gt, :eq]
                "semver_lt" -> ordering == :lt
                "semver_lte" -> ordering in [:lt, :eq]
              end
            )
          else
            _ -> :inconclusive
          end
      end
    else
      _ -> :inconclusive
    end
  end

  defp semver_range(_actual, :error), do: :inconclusive

  defp semver_range(actual, {:ok, lower, upper}) do
    boolean_result(
      compare_semver(actual, lower) in [:eq, :gt] and compare_semver(actual, upper) == :lt
    )
  end

  defp parse_semver(value) when is_binary(value) do
    parts =
      value
      |> normalize_semver_text()
      |> String.split(".")

    if parts == [] do
      :error
    else
      with {:ok, numbers} <- parts |> Enum.take(3) |> parse_semver_numbers() do
        {:ok, numbers |> Kernel.++([0, 0]) |> Enum.take(3) |> List.to_tuple()}
      end
    end
  end

  defp parse_semver(_value), do: :error

  defp normalize_semver_text(value) do
    value
    |> String.trim()
    |> String.replace_prefix("v", "")
    |> String.replace_prefix("V", "")
    |> String.split(~r/[-+]/, parts: 2)
    |> hd()
  end

  defp parse_semver_numbers(parts) do
    Enum.reduce_while(parts, {:ok, []}, fn part, {:ok, numbers} ->
      case parse_semver_number(part) do
        {:ok, number} -> {:cont, {:ok, numbers ++ [number]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp compare_semver(left, right), do: compare_tuple(left, right)
  defp compare_tuple(left, right) when left < right, do: :lt
  defp compare_tuple(left, right) when left > right, do: :gt
  defp compare_tuple(_left, _right), do: :eq

  defp tilde_bounds(value) do
    with {:ok, {major, minor, patch}} <- parse_semver(value) do
      {:ok, {major, minor, patch}, {major, minor + 1, 0}}
    end
  end

  defp caret_bounds(value) do
    with {:ok, {major, minor, patch}} <- parse_semver(value) do
      upper =
        cond do
          major > 0 -> {major + 1, 0, 0}
          minor > 0 -> {0, minor + 1, 0}
          true -> {0, 0, patch + 1}
        end

      {:ok, {major, minor, patch}, upper}
    end
  end

  defp wildcard_bounds(value) when is_binary(value) do
    normalized =
      value
      |> String.trim()
      |> String.replace_prefix("v", "")
      |> String.replace_prefix("V", "")

    case String.split(normalized, ".") do
      parts when length(parts) in 2..4 ->
        {numbers, [wildcard]} = Enum.split(parts, -1)

        with true <- wildcard in ["*", "x", "X"],
             {:ok, parsed} <- parse_semver_numbers(numbers) do
          wildcard_range(parsed)
        else
          _ -> :error
        end

      _parts ->
        :error
    end
  end

  defp wildcard_bounds(_value), do: :error

  defp wildcard_range([major]), do: {:ok, {major, 0, 0}, {major + 1, 0, 0}}

  defp wildcard_range([major, minor]),
    do: {:ok, {major, minor, 0}, {major, minor + 1, 0}}

  defp wildcard_range([major, minor, patch]),
    do: {:ok, {major, minor, patch}, {major, minor, patch + 1}}

  defp parse_semver_number(value) do
    if Regex.match?(~r/^(0|[1-9]\d*)$/, value),
      do: {:ok, String.to_integer(value)},
      else: :error
  end

  defp has_key?(map, key), do: Map.has_key?(map, key) or Map.has_key?(map, known_atom(key))

  defp value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, known_atom(key)))
  defp value(_map, _key), do: nil

  defp known_atom("active"), do: :active
  defp known_atom("aggregation_group_type_index"), do: :aggregation_group_type_index
  defp known_atom("bucketing_identifier"), do: :bucketing_identifier
  defp known_atom("dependency_chain"), do: :dependency_chain
  defp known_atom("ensure_experience_continuity"), do: :ensure_experience_continuity
  defp known_atom("early_exit"), do: :early_exit
  defp known_atom("filters"), do: :filters
  defp known_atom("groups"), do: :groups
  defp known_atom("has_experiment"), do: :has_experiment
  defp known_atom("id"), do: :id
  defp known_atom("key"), do: :key
  defp known_atom("multivariate"), do: :multivariate
  defp known_atom("negation"), do: :negation
  defp known_atom("operator"), do: :operator
  defp known_atom("payloads"), do: :payloads
  defp known_atom("properties"), do: :properties
  defp known_atom("rollout_percentage"), do: :rollout_percentage
  defp known_atom("type"), do: :type
  defp known_atom("value"), do: :value
  defp known_atom("values"), do: :values
  defp known_atom("variant"), do: :variant
  defp known_atom("variants"), do: :variants
  defp known_atom("version"), do: :version

  defp map_value(map, key) when is_map(map) do
    case map_fetch(map, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp map_value(_map, _key), do: nil

  defp map_fetch(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        {:ok, value}

      :error when is_binary(key) ->
        Enum.find_value(map, :error, fn {candidate, value} ->
          if (is_atom(candidate) or is_integer(candidate)) and to_string(candidate) == key,
            do: {:ok, value}
        end)

      :error ->
        :error
    end
  end

  defp map_fetch(_map, _key), do: :error
end
