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
  @text_operators ~w(exact is_not is_set is_not_set icontains not_icontains starts_with not_starts_with ends_with not_ends_with)

  @type reason :: PostHog.FeatureFlags.Evaluations.unresolved_reason()

  # :inconclusive lets later conditions resolve the flag. :requires_server stops evaluation,
  # because only the server knows whether this condition matches.
  @type outcome ::
          {:ok, boolean() | String.t()} | {:inconclusive, reason()} | {:requires_server, reason()}

  @spec evaluate(map(), map(), [String.t()] | nil) :: %{
          results: %{String.t() => Result.t()},
          unresolved: MapSet.t(String.t()),
          reasons: %{String.t() => reason()}
        }
  def evaluate(definitions, context, keys \\ nil) do
    keys = keys || Map.keys(definitions.flags_by_key)
    context = normalize_context(context)

    {results, unresolved, reasons, _cache} =
      Enum.reduce(keys, {%{}, MapSet.new(), %{}, %{}}, fn key,
                                                          {results, unresolved, reasons, cache} ->
        case Map.fetch(definitions.flags_by_key, key) do
          {:ok, flag} ->
            {outcome, cache} = evaluate_key(key, flag, definitions, context, cache)

            case outcome do
              {:ok, value} ->
                {Map.put(results, key, build_result(key, flag, value, definitions)), unresolved,
                 reasons, cache}

              # An unexpected error has no reason, but the flag still falls back.
              {_status, nil} ->
                {results, MapSet.put(unresolved, key), reasons, cache}

              {status, reason} when status in [:inconclusive, :requires_server] ->
                {results, MapSet.put(unresolved, key), Map.put(reasons, key, reason), cache}
            end

          :error ->
            {results, MapSet.put(unresolved, key), reasons, cache}
        end
      end)

    %{results: results, unresolved: unresolved, reasons: reasons}
  end

  @doc false
  # The reason that comes from the flag's definition alone, so it is known when definitions
  # load. It is the reason evaluation reports for the same cause.
  @spec definition_unresolved_reason(map(), map()) :: reason() | nil
  def definition_unresolved_reason(flag, definitions) do
    cond do
      not is_map(flag) ->
        :unsupported_definition

      value(flag, "active") == false ->
        nil

      value(flag, "active") != true ->
        :unsupported_definition

      value(flag, "ensure_experience_continuity") == true ->
        :experience_continuity

      not is_binary(value(flag, "key")) ->
        :unsupported_definition

      not is_map(value(flag, "filters")) ->
        :unsupported_definition

      true ->
        filters_definition_reason(value(flag, "filters"), definitions)
    end
  end

  defp filters_definition_reason(filters, definitions) do
    aggregation = value(filters, "aggregation_group_type_index")
    conditions = value(filters, "groups") || []

    cond do
      not is_nil(aggregation) and
          not is_binary(map_value(definitions.group_type_mapping, to_string(aggregation))) ->
        :unsupported_definition

      not is_list(conditions) ->
        :unsupported_definition

      Enum.any?(conditions, &unsupported_condition?(&1, definitions)) ->
        :unsupported_definition

      true ->
        nil
    end
  end

  defp unsupported_condition?(condition, definitions) when is_map(condition) do
    properties = value(condition, "properties") || []
    rollout = value(condition, "rollout_percentage")

    not is_list(properties) or not (is_nil(rollout) or is_number(rollout)) or
      Enum.any?(properties, &unsupported_property?(&1, definitions, false, MapSet.new()))
  end

  defp unsupported_condition?(_condition, _definitions), do: true

  defp unsupported_property?(property, definitions, cohort?, visited) when is_map(property) do
    case value(property, "type") do
      "flag" -> dependency_filter(property, definitions) == :unsupported
      "cohort" -> unsupported_cohort?(property, definitions, visited)
      _ -> not filter_supported?(property, DateTime.utc_now(), cohort?)
    end
  end

  defp unsupported_property?(_property, _definitions, _cohort?, _visited), do: true

  defp unsupported_cohort?(property, definitions, visited) do
    cohort_id = to_string(value(property, "value"))

    cond do
      (value(property, "operator") || "exact") not in ["exact", "in", "not_in"] ->
        true

      MapSet.member?(visited, cohort_id) ->
        false

      true ->
        case map_fetch(definitions.cohorts, cohort_id) do
          :error -> true
          {:ok, group} -> unsupported_group?(group, definitions, MapSet.put(visited, cohort_id))
        end
    end
  end

  defp unsupported_group?(group, _definitions, _visited) when group == %{}, do: false

  defp unsupported_group?(group, definitions, visited) when is_map(group) do
    values = value(group, "values")

    if value(group, "type") in ["AND", "OR"] and is_list(values) do
      Enum.any?(values, fn entry ->
        if is_map(entry) and (entry == %{} or has_key?(entry, "values")),
          do: unsupported_group?(entry, definitions, visited),
          else: unsupported_property?(entry, definitions, true, visited)
      end)
    else
      true
    end
  end

  defp unsupported_group?(_group, _definitions, _visited), do: true

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
        {{:inconclusive, :unsupported_definition}, cache}

      {:done, outcome} ->
        {outcome, cache}

      nil ->
        cache = Map.put(cache, key, :resolving)
        {outcome, cache} = evaluate_flag(flag, definitions, context, cache)
        {outcome, Map.put(cache, key, {:done, outcome})}
    end
  rescue
    _exception -> unexpected_error(key, cache)
  catch
    _kind, _reason -> unexpected_error(key, cache)
  end

  # Like the other SDKs, an unexpected error reports no reason.
  defp unexpected_error(key, cache) do
    outcome = {:inconclusive, nil}
    {outcome, Map.put(cache, key, {:done, outcome})}
  end

  defp evaluate_flag(flag, definitions, context, cache) when is_map(flag) do
    cond do
      value(flag, "active") == false ->
        {{:ok, false}, cache}

      value(flag, "active") != true ->
        {{:inconclusive, :unsupported_definition}, cache}

      # Inconclusive rather than server-required, so a flag that depends on this one can
      # still resolve from a later condition.
      value(flag, "ensure_experience_continuity") == true ->
        {{:inconclusive, :experience_continuity}, cache}

      not is_binary(value(flag, "key")) or not is_map(value(flag, "filters")) ->
        {{:inconclusive, :unsupported_definition}, cache}

      true ->
        evaluate_active_flag(flag, definitions, context, cache)
    end
  end

  defp evaluate_flag(_flag, _definitions, _context, cache),
    do: {{:inconclusive, :unsupported_definition}, cache}

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
          nil
        )
      else
        {{:inconclusive, :unsupported_definition}, cache}
      end
    else
      # No condition can be checked, so a cause in the definition outranks the missing context.
      :missing_context ->
        {{:inconclusive, with_definition_reason(:missing_context, flag, definitions)}, cache}

      {:inconclusive, _reason} = outcome ->
        {outcome, cache}
    end
  end

  defp evaluation_target(nil, flag, _definitions, context) do
    case bucketing_value(flag, context) do
      {:ok, bucketing} -> {:ok, context.person_properties, bucketing}
      :error -> :missing_context
    end
  end

  defp evaluation_target(index, _flag, definitions, context) do
    group_name = map_value(definitions.group_type_mapping, to_string(index))
    group_key = if is_binary(group_name), do: map_value(context.groups, group_name)
    properties = if is_binary(group_name), do: map_value(context.group_properties, group_name)

    cond do
      not is_binary(group_name) -> {:inconclusive, :unsupported_definition}
      is_nil(group_key) or not is_map(properties) -> :missing_context
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
        :error

      _ when is_binary(context.distinct_id) ->
        {:ok, context.distinct_id}

      _ ->
        :error
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
         reason
       ) do
    # reason doubles as the inconclusive marker. It is never nil for an inconclusive condition,
    # because only a whole-flag error has no reason, and that never reaches the condition loop.
    {if(reason, do: {:inconclusive, reason}, else: {:ok, false}), cache}
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
         reason
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
            if value(value(flag, "filters"), "early_exit") == true and is_nil(reason) do
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
                reason
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
              reason
            )

          {:inconclusive, condition_reason} ->
            evaluate_conditions(
              rest,
              flag,
              aggregation,
              properties,
              bucketing,
              definitions,
              context,
              cache,
              pick_reason(reason, condition_reason)
            )

          # Evaluation stops here and skips the conditions it did not reach, so the flag's
          # definition still counts toward the reason.
          {:requires_server, server_reason} ->
            server_reason =
              reason |> pick_reason(server_reason) |> with_definition_reason(flag, definitions)

            {{:requires_server, server_reason}, cache}
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
          reason
        )

      {:inconclusive, target_reason} ->
        evaluate_conditions(
          rest,
          flag,
          aggregation,
          properties,
          bucketing,
          definitions,
          context,
          cache,
          pick_reason(reason, target_reason)
        )
    end
  end

  defp with_definition_reason(reason, flag, definitions) do
    pick_reason(reason, definition_unresolved_reason(flag, definitions))
  rescue
    # A definition this lookup cannot read must not change how the flag falls back.
    _exception -> reason
  end

  defp pick_reason(nil, reason), do: reason
  defp pick_reason(reason, nil), do: reason

  defp pick_reason(current, reason),
    do: if(reason_rank(reason) < reason_rank(current), do: reason, else: current)

  # When several causes apply to one flag, every SDK reports the first reason in this order,
  # whatever order it inspects the filters in.
  defp reason_rank(:experience_continuity), do: 0
  defp reason_rank(:unsupported_definition), do: 1
  defp reason_rank(:unresolved_dependency), do: 2
  defp reason_rank(:missing_context), do: 3

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
            :error -> {:inconclusive, :missing_context}
          end

        index ->
          group_name = map_value(definitions.group_type_mapping, to_string(index))
          group_key = if is_binary(group_name), do: map_value(context.groups, group_name)

          group_props =
            if is_binary(group_name), do: map_value(context.group_properties, group_name)

          cond do
            is_nil(group_key) -> :skip
            not is_map(group_props) -> {:inconclusive, :missing_context}
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
       do: {:inconclusive, :unsupported_definition}

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
      {{:inconclusive, :unsupported_definition}, cache}
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
        {{:inconclusive, :unsupported_definition}, cache}
    end
  end

  # Filters in a condition have no defined order, so a filter that can't be checked does not
  # stop the loop: a later filter can still rule the condition out or carry a higher reason.
  defp match_all_properties(properties, property_values, definitions, context, cache) do
    Enum.reduce_while(properties, {:match, cache}, fn property, {aggregate, cache} ->
      case match_condition_property(property, property_values, definitions, context, cache) do
        {:no_match, cache} ->
          {:halt, {:no_match, cache}}

        {:match, cache} ->
          {:cont, {aggregate, cache}}

        {{_status, _reason} = uncertain, cache} ->
          {:cont, {merge_uncertain(aggregate, uncertain), cache}}

        {:error, kind, reason, stacktrace} ->
          # The condition is already inconclusive, so an unexpected error in a later filter
          # stops only this condition. Later conditions can still resolve the flag.
          if aggregate == :match,
            do: :erlang.raise(kind, reason, stacktrace),
            else: {:halt, {aggregate, cache}}
      end
    end)
  end

  defp match_condition_property(property, property_values, definitions, context, cache) do
    match_typed_property(property, property_values, definitions, context, cache)
  catch
    kind, reason -> {:error, kind, reason, __STACKTRACE__}
  end

  defp merge_uncertain(:match, uncertain), do: uncertain

  defp merge_uncertain({left_status, left_reason}, {right_status, right_reason}) do
    status =
      if :requires_server in [left_status, right_status],
        do: :requires_server,
        else: :inconclusive

    {status, pick_reason(left_reason, right_reason)}
  end

  defp match_typed_property(
         property,
         property_values,
         definitions,
         context,
         cache,
         cohort? \\ false
       )

  defp match_typed_property(property, property_values, definitions, context, cache, cohort?)
       when is_map(property) do
    {result, cache} =
      case value(property, "type") do
        "cohort" ->
          {match_cohort(property, property_values, definitions, context, cache), cache}

        "flag" ->
          match_dependency(property, definitions, context, cache)

        _ ->
          {match_property(
             property,
             property_values,
             context.now,
             Map.get(definitions, :property_matching_version, 1),
             cohort?
           ), cache}
      end

    if result == :invalid_regex do
      # A cohort may be negated again at any outer group/reference. Keep malformed leaves
      # inconclusive there so an invalid search can never become a successful comparison.
      {if(cohort?, do: {:inconclusive, :unsupported_definition}, else: :no_match), cache}
    else
      {apply_negation(result, value(property, "negation") == true), cache}
    end
  end

  defp match_typed_property(_property, _values, _definitions, _context, cache, _cohort?),
    do: {{:inconclusive, :unsupported_definition}, cache}

  defp apply_negation(:match, true), do: :no_match
  defp apply_negation(:no_match, true), do: :match
  defp apply_negation(result, _negation), do: result

  defp match_dependency(property, definitions, context, cache) do
    case dependency_filter(property, definitions) do
      {:ok, key, expected, chain} ->
        case evaluate_dependency_chain(chain, definitions, context, cache) do
          {:ok, cache} -> dependency_result(key, expected, cache)
          {uncertain, cache} -> {uncertain, cache}
        end

      :unsupported ->
        {{:inconclusive, :unsupported_definition}, cache}

      :no_match ->
        {:no_match, cache}
    end
  end

  # Evaluation and the load-time warning share this check, so both report the same reason.
  defp dependency_filter(property, definitions) do
    key = value(property, "key")
    expected = value(property, "value")
    chain = value(property, "dependency_chain")

    cond do
      value(property, "operator") != "flag_evaluates_to" -> :no_match
      not is_binary(key) or is_nil(expected) -> :no_match
      not is_list(chain) or chain == [] or not Enum.all?(chain, &is_binary/1) -> :unsupported
      # A dependency with no definition outranks one that is only unresolved.
      not Enum.all?(chain, &Map.has_key?(definitions.flags_by_key, &1)) -> :unsupported
      true -> {:ok, key, expected, chain}
    end
  end

  defp evaluate_dependency_chain([], _definitions, _context, cache), do: {:ok, cache}

  defp evaluate_dependency_chain([key | rest], definitions, context, cache) do
    case Map.get(cache, key) do
      {:done, {:ok, _value}} ->
        evaluate_dependency_chain(rest, definitions, context, cache)

      {:done, outcome} ->
        {unresolved_dependency(outcome), cache}

      :resolving ->
        {{:inconclusive, :unsupported_definition}, cache}

      nil ->
        dependency = Map.fetch!(definitions.flags_by_key, key)
        {outcome, cache} = evaluate_key(key, dependency, definitions, context, cache)

        case outcome do
          {:ok, _value} -> evaluate_dependency_chain(rest, definitions, context, cache)
          outcome -> {unresolved_dependency(outcome), cache}
        end
    end
  end

  # Only the server knows the value of a dependency that requires it, and that value can
  # decide which condition matches. So the dependent flag requires the server too, and a
  # later condition must not choose a different value locally.
  defp unresolved_dependency({status, _reason}), do: {status, :unresolved_dependency}

  defp dependency_result(key, expected, cache) do
    case Map.get(cache, key) do
      {:done, {:ok, actual}} ->
        {if(dependency_matches?(expected, actual), do: :match, else: :no_match), cache}

      _other ->
        {{:inconclusive, :unresolved_dependency}, cache}
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
      # Likely a static cohort, whose members only the server knows.
      :error ->
        {:requires_server, :unsupported_definition}

      {:ok, group} ->
        result = match_property_group(group, property_values, definitions, context, cache)

        case value(property, "operator") || "exact" do
          operator when operator in ["exact", "in"] -> result
          "not_in" -> apply_negation(result, true)
          _ -> {:inconclusive, :unsupported_definition}
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
      {:requires_server, :unsupported_definition}
    end
  end

  defp match_property_group(_group, _property_values, _definitions, _context, _cache),
    do: {:requires_server, :unsupported_definition}

  defp match_group_values(_type, [], _properties, _definitions, _context, _cache), do: :match

  defp match_group_values(type, values, properties, definitions, context, cache) do
    results =
      Enum.map(values, fn entry ->
        if is_map(entry) and (entry == %{} or has_key?(entry, "values")) do
          entry
          |> match_property_group(properties, definitions, context, cache)
          |> apply_negation(value(entry, "negation") == true)
        else
          {result, _cache} =
            match_typed_property(entry, properties, definitions, context, cache, true)

          result
        end
      end)

    combine_group_results(type, results)
  end

  defp combine_group_results(type, results) do
    uncertain = Enum.filter(results, &match?({_status, _reason}, &1))
    reason = uncertain |> Enum.map(&elem(&1, 1)) |> Enum.reduce(nil, &pick_reason(&2, &1))

    cond do
      Enum.any?(uncertain, &match?({:requires_server, _reason}, &1)) -> {:requires_server, reason}
      type == "AND" and :no_match in results -> :no_match
      type == "OR" and :match in results -> :match
      uncertain != [] -> {:inconclusive, reason}
      type == "AND" -> :match
      true -> :no_match
    end
  end

  defp match_property(property, property_values, now, property_matching_version, cohort?) do
    key = value(property, "key")
    operator = value(property, "operator") || "exact"
    filter_value = value(property, "value")

    case map_fetch(property_values, key) do
      :error ->
        {:inconclusive, property_reason(property, now, cohort?)}

      {:ok, property_value} when operator in ["exact", "is_not"] ->
        match = exact_match?(property_value, filter_value, property_matching_version)
        boolean_result(if(operator == "exact", do: match, else: not match))

      {:ok, property_value} ->
        case apply_operator(operator, property_value, filter_value, now) do
          # Only the server can run this pattern on this value.
          :inconclusive when operator in ["regex", "not_regex"] ->
            {:inconclusive, :unsupported_definition}

          :inconclusive ->
            {:inconclusive, property_reason(property, now, cohort?)}

          result ->
            result
        end
    end
  rescue
    # Unsupported comparisons must not prevent later conditions from matching.
    _exception -> {:inconclusive, property_reason(property, now, cohort?)}
  end

  # A filter that local evaluation can't use outranks missing or unusable context, so the
  # filter is checked before the context is blamed.
  defp property_reason(property, now, cohort?) do
    if filter_supported?(property, now, cohort?),
      do: :missing_context,
      else: :unsupported_definition
  end

  defp filter_supported?(property, now, cohort?) do
    filter = value(property, "value")

    case value(property, "operator") || "exact" do
      operator when operator in @text_operators ->
        true

      operator when operator in ["regex", "not_regex"] ->
        case compile_regex(to_string(filter)) do
          {:ok, _regex} -> true
          :invalid_regex -> not cohort?
          :inconclusive -> false
        end

      operator when operator in ["gt", "gte", "lt", "lte"] ->
        match?({:ok, _number}, number(filter))

      operator when operator in ["is_date_before", "is_date_after"] ->
        match?({:ok, _datetime}, parse_datetime(filter, now))

      "semver_tilde" ->
        match?({:ok, _lower, _upper}, tilde_bounds(filter))

      "semver_caret" ->
        match?({:ok, _lower, _upper}, caret_bounds(filter))

      "semver_wildcard" ->
        match?({:ok, _lower, _upper}, wildcard_bounds(filter))

      operator when operator in @semver_operators ->
        match?({:ok, _version}, parse_semver(filter))

      _unknown ->
        false
    end
  rescue
    _exception -> false
  end

  defp apply_operator("is_set", _property, _filter, _now), do: :match
  defp apply_operator("is_not_set", _property, _filter, _now), do: :no_match

  defp apply_operator(_operator, nil, _filter, _now), do: :no_match

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
    pattern = to_string(filter)
    input = to_string(property)

    case regex_match(pattern, input) do
      matched when is_boolean(matched) ->
        boolean_result(if(operator == "regex", do: matched, else: not matched))

      result ->
        result
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

  defp regex_match("", _input), do: true

  defp regex_match(pattern, input) do
    case compile_regex(pattern) do
      {:ok, regex} ->
        # Make $ strict at the end of the input, rather than before a final LF.
        if ascii_regex_input?(input) do
          # Regex.match? hides match-limit errors as misses.
          case :re.run(input, Regex.re_pattern(regex), [:report_errors, {:capture, :none}]) do
            :match -> true
            :nomatch -> false
            {:error, _reason} -> :inconclusive
          end
        else
          :inconclusive
        end

      result ->
        result
    end
  end

  defp compile_regex(pattern) do
    # PCRE's Unicode tables and set syntax differ from the service. Keep the shared ASCII
    # subset local, without changing POSIX classes by blindly enabling Unicode mode.
    if portable_regex?(pattern, :outside, :start) do
      case Regex.compile(pattern, [:dollar_endonly]) do
        {:ok, regex} -> {:ok, regex}
        {:error, {reason, _offset}} -> invalid_regex_result(reason)
        _ -> :inconclusive
      end
    else
      :inconclusive
    end
  end

  # Only proven shared syntax errors are definitive. Other compiler failures, including
  # engine limits, remain inconclusive. PCRE1 and PCRE2 spell some syntax errors differently.
  defp invalid_regex_result(reason) do
    if to_string(reason) in [
         "missing terminating ] for character class",
         "missing closing parenthesis",
         "missing )",
         "unmatched closing parenthesis",
         "unmatched parentheses",
         "quantifier does not follow a repeatable item",
         "nothing to repeat",
         "range out of order in character class",
         "numbers out of order in {} quantifier"
       ],
       do: :invalid_regex,
       else: :inconclusive
  end

  defp ascii_regex_input?(""), do: true

  defp ascii_regex_input?(<<byte, rest::binary>>) when byte < 128,
    do: ascii_regex_input?(rest)

  defp ascii_regex_input?(<<_byte, _rest::binary>>), do: false

  defp portable_regex?("", _class, _previous), do: true

  defp portable_regex?(<<character, _rest::binary>>, _class, _previous)
       when character > 127,
       do: false

  defp portable_regex?(<<"\\x", a, b, rest::binary>>, class, _previous)
       when a in ?0..?9 or a in ?a..?f or a in ?A..?F do
    if b in ?0..?9 or b in ?a..?f or b in ?A..?F,
      do: portable_regex?(rest, class_content(class), :literal),
      else: false
  end

  defp portable_regex?(<<"\\", escaped, rest::binary>>, class, _previous) do
    cond do
      # Even short ASCII word-boundary searches can exceed the service backtracking budget.
      class == :outside and escaped in ~c"bB" ->
        false

      escaped in ~c"dDsSwW" ->
        portable_regex?(rest, class_content(class), :shorthand)

      # PCRE's \v includes LF/CR/FF, whereas the service matches only vertical tab.
      escaped in ~c"fnrt" or (class != :outside and escaped == ?b) ->
        portable_regex?(rest, class_content(class), :literal)

      class != :outside and escaped in ~c"\\.^$|?*+()[]{}-" ->
        portable_regex?(rest, :inside, :literal)

      class == :outside and
          (escaped in 32..47 or escaped in ~c":;=?@" or escaped in 91..96 or
             escaped in 123..126) ->
        portable_regex?(rest, class, :literal)

      true ->
        false
    end
  end

  defp portable_regex?(<<"[", rest::binary>>, :outside, _previous),
    do: portable_regex?(rest, :class_start, :start)

  defp portable_regex?(<<"^", rest::binary>>, :class_start, _previous),
    do: portable_regex?(rest, :negated_start, :start)

  defp portable_regex?(<<"]", _rest::binary>>, class, _previous)
       when class in [:class_start, :negated_start],
       do: false

  defp portable_regex?(<<"]", rest::binary>>, :inside, _previous),
    do: portable_regex?(rest, :outside, :literal)

  defp portable_regex?(<<character, rest::binary>>, class, previous) when class != :outside do
    cond do
      character == ?[ -> false
      character in ~c"&-~" and String.starts_with?(rest, <<character>>) -> false
      character == ?- and previous == :shorthand and not String.starts_with?(rest, "]") -> false
      character == ?- and shorthand_start?(rest) -> false
      true -> portable_regex?(rest, :inside, :literal)
    end
  end

  defp portable_regex?(<<"(?:", rest::binary>>, :outside, _previous),
    do: portable_regex?(rest, :outside, :open)

  defp portable_regex?(<<"(?", _rest::binary>>, :outside, _previous), do: false

  defp portable_regex?(<<"{", _rest::binary>> = pattern, :outside, previous) do
    case Regex.run(~r/^\{([0-9]+)(?:,([0-9]*))?\}/, pattern) do
      [repetition | counts]
      when previous not in [:start, :open, :alternation, :assertion, :empty, :repeat] ->
        if Enum.all?(counts, &(&1 == "" or String.to_integer(&1) <= 65_535)) do
          rest =
            binary_part(
              pattern,
              byte_size(repetition),
              byte_size(pattern) - byte_size(repetition)
            )

          not String.starts_with?(rest, "+") and portable_regex?(rest, :outside, :repeat)
        else
          false
        end

      _ ->
        false
    end
  end

  defp portable_regex?(<<character, rest::binary>>, :outside, previous) do
    cond do
      character in ~c"*+?" and previous in [:start, :open, :alternation, :assertion, :empty] ->
        false

      character in ~c"*+?" and String.starts_with?(rest, ["+", "{"]) ->
        false

      character in ~c"*+?" ->
        portable_regex?(rest, :outside, :repeat)

      character in ~c"^$" ->
        portable_regex?(rest, :outside, :assertion)

      character == ?( ->
        portable_regex?(rest, :outside, :open)

      character == ?) and previous in [:open, :empty] ->
        portable_regex?(rest, :outside, :empty)

      character == ?| ->
        portable_regex?(rest, :outside, :alternation)

      character == ?} ->
        false

      true ->
        portable_regex?(rest, :outside, :literal)
    end
  end

  defp class_content(:outside), do: :outside
  defp class_content(_class), do: :inside

  defp shorthand_start?(<<"\\", character, _rest::binary>>), do: character in ~c"dDsSwW"
  defp shorthand_start?(_rest), do: false

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
      minimal_flag_called_events: definitions.minimal_flag_called_events,
      reason: "Evaluated locally",
      locally_evaluated: true
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

  defp exact_match?(property, filter, property_matching_version) do
    cond do
      # The service treats an empty filter as recursive ALL truthiness in both modes.
      filter == [] ->
        truthy?(property)

      property_matching_version != 2 and boolean_like?(filter) ->
        truthy?(property) == truthy?(filter)

      is_list(filter) ->
        prepared_property = prepare_exact_comparison(property)
        Enum.any?(filter, &case_insensitive_equal?(prepared_property, &1))

      true ->
        case_insensitive_equal?(prepare_exact_comparison(property), filter)
    end
  end

  defp boolean_like?(value) when is_boolean(value), do: true
  defp boolean_like?(value) when is_binary(value), do: String.downcase(value) in ["true", "false"]
  defp boolean_like?(value) when is_list(value), do: Enum.all?(value, &boolean_like?/1)
  defp boolean_like?(_value), do: false

  defp truthy?(value) when is_boolean(value), do: value
  defp truthy?(value) when is_binary(value), do: String.downcase(value) == "true"
  defp truthy?(value) when is_list(value), do: Enum.all?(value, &truthy?/1)

  # Jason sends non-boolean atoms as strings, but a struct's encoder is opaque.
  defp truthy?(value) when is_atom(value) and not is_nil(value),
    do: value |> Atom.to_string() |> truthy?()

  defp truthy?(value) when is_struct(value) do
    raise ArgumentError, "opaque JSON struct truthiness"
  end

  defp truthy?(_value), do: false

  defp prepare_exact_comparison(value) do
    string = exact_string(value)
    {String.downcase(string), composite_json?(value), String.contains?(string, "Σ")}
  end

  defp case_insensitive_equal?({left_string, left_composite?, left_sigma?}, right) do
    {right_string, right_composite?, right_sigma?} = prepare_exact_comparison(right)

    # Rust lowercases sigma contextually; String.downcase/1 does not. Keep newly
    # supported composite comparisons inconclusive if either side could differ.
    if (left_composite? or right_composite?) and (left_sigma? or right_sigma?) do
      raise ArgumentError, "ambiguous composite Unicode casing"
    end

    left_string == right_string
  end

  defp composite_json?(value), do: is_list(value) or (is_map(value) and not is_struct(value))

  defp exact_string(value) when is_struct(value), do: to_string(value)

  # Lists must remain whole JSON values, not Elixir charlists; known null is not missing.
  defp exact_string(value) when is_nil(value) or is_list(value) or is_map(value),
    do: value |> sort_json_objects() |> Jason.encode!()

  defp exact_string(value), do: to_string(value)

  # Nested encoders can hide unsorted keys and ambiguous numbers from normalization.
  # Top-level scalar structs use exact_string/1 instead. OrderedObjects generated
  # below contain already-normalized members and are never passed back through here.
  defp sort_json_objects(value) when is_struct(value) do
    raise ArgumentError, "opaque composite JSON struct"
  end

  # Map iteration order is not JSON key order, including for mixed atom/string keys.
  defp sort_json_objects(value) when is_map(value) and not is_struct(value) do
    members =
      Enum.map(value, fn {key, member} ->
        # Jason uses atom names for keys, including nil as "nil", not "".
        key = if is_atom(key), do: Atom.to_string(key), else: to_string(key)
        {key, sort_json_objects(member)}
      end)

    # JSON parsing on the service drops duplicate keys, unlike Jason.OrderedObject.
    if length(Enum.uniq_by(members, &elem(&1, 0))) != map_size(value) do
      raise ArgumentError, "ambiguous composite JSON keys"
    end

    members
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  defp sort_json_objects(value) when is_list(value), do: Enum.map(value, &sort_json_objects/1)

  # Jason and serde_json differ for floats and integers outside the service's i64/u64 range.
  # Leave these composite comparisons inconclusive through the existing evaluation boundary.
  defp sort_json_objects(value)
       when is_float(value) or
              (is_integer(value) and
                 (value < -9_223_372_036_854_775_808 or value > 18_446_744_073_709_551_615)) do
    raise ArgumentError, "ambiguous composite JSON number"
  end

  defp sort_json_objects(value), do: value

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
