defmodule PostHog.FeatureFlags.LocalEvaluatorNormalizationTest do
  # Call-count tracing is VM-wide, so it must not overlap other evaluator tests.
  use ExUnit.Case, async: false

  alias PostHog.FeatureFlags.LocalEvaluator

  test "normalizes a composite property once when scanning nonmatching candidates" do
    Code.ensure_loaded!(LocalEvaluator)
    traced_function = {LocalEvaluator, :sort_json_objects, 1}

    on_exit(fn -> :erlang.trace_pattern(traced_function, false, [:call_count]) end)

    for property <- [Map.new(1..20, &{"key-#{&1}", &1}), Enum.to_list(1..20)],
        version <- [1, 2],
        operator <- ["exact", "is_not"] do
      calls =
        for candidate_count <- [1, 10] do
          flag = %{
            "id" => 1,
            "key" => "normalization",
            "active" => true,
            "filters" => %{
              "groups" => [
                %{
                  "properties" => [
                    %{
                      "key" => "prop",
                      "operator" => operator,
                      "value" => List.duplicate("nonmatching", candidate_count)
                    }
                  ]
                }
              ]
            }
          }

          definitions = %{
            flags_by_key: %{"normalization" => flag},
            group_type_mapping: %{},
            cohorts: %{},
            property_matching_version: version,
            minimal_flag_called_events: false
          }

          context = %{distinct_id: "user", person_properties: %{prop: property}}
          :erlang.trace_pattern(traced_function, true, [:call_count])
          result = LocalEvaluator.evaluate(definitions, context)
          {:call_count, count} = :erlang.trace_info(traced_function, :call_count)
          :erlang.trace_pattern(traced_function, false, [:call_count])

          assert result.results["normalization"].enabled == (operator == "is_not")
          assert result.unresolved == MapSet.new()
          count
        end

      [single_candidate_calls, many_candidate_calls] = calls
      assert single_candidate_calls > 0
      assert many_candidate_calls == single_candidate_calls
    end
  end
end
