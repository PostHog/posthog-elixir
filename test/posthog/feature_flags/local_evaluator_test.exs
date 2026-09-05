defmodule PostHog.FeatureFlags.LocalEvaluatorTest do
  use ExUnit.Case, async: true

  alias PostHog.FeatureFlags.LocalEvaluator
  alias PostHog.FeatureFlags.Result

  defp snapshot(flags, extras \\ %{}) do
    Map.merge(
      %{
        flags: flags,
        flags_by_key: Map.new(flags, &{&1["key"], &1}),
        group_type_mapping: %{},
        cohorts: %{},
        minimal_flag_called_events: false
      },
      extras
    )
  end

  defp flag(key, properties \\ [], rollout \\ 100) do
    %{
      "id" => 1,
      "version" => 2,
      "key" => key,
      "active" => true,
      "filters" => %{
        "groups" => [%{"properties" => properties, "rollout_percentage" => rollout}]
      }
    }
  end

  defp evaluate(flag, context \\ %{}) do
    context = Map.merge(%{distinct_id: "user", person_properties: %{}}, context)
    LocalEvaluator.evaluate(snapshot([flag]), context, [flag["key"]])
  end

  # Expected values are the released service v1 and explicit v2 results, not
  # Elixir truthiness or the SDK's former unversioned array membership behavior.
  for version <- [:missing, 1, 2, 0, 3, "2", nil] do
    @matching_version version
    test "version #{inspect(version)} selects service exact matching and is_not complements" do
      rows = [
        {false, "banana", true, false},
        {false, 0, true, false},
        {false, 1, true, false},
        {"FaLsE", "banana", true, false},
        {["FALSE"], "banana", true, false},
        {["true", "false"], "true", false, true},
        {["true", "false"], "pro", true, false},
        {[], true, true, true},
        {[], [], true, true},
        {true, [true], true, false},
        {"TrUe", [true], true, false},
        {[true], [true], true, false},
        {true, [], true, false},
        {false, "FALSE", true, true},
        {false, nil, true, false},
        {false, "", true, false},
        {false, %{}, true, false},
        {[], [true, ["TRUE", []]], true, true},
        {[], [true, [false]], false, false},
        {[], false, false, false},
        {[], nil, false, false},
        {[], 0, false, false},
        {[], 1, false, false},
        {[], "banana", false, false},
        {["FREE", "PRO"], "pro", true, true},
        {[false, "PRO"], "pro", true, true},
        {[false, "PRO"], "banana", false, false},
        {[[true], "PRO"], [true], true, true},
        {[["ÉLITE", true], "PRO"], ["élite", true], true, true},
        {[[true], ["FALSE"]], "banana", true, false},
        {["TrUe", "FALSE"], true, false, true},
        {["TrUe", "FALSE"], false, true, true},
        {nil, nil, true, true},
        {[nil], nil, true, true},
        {nil, "", false, false},
        {%{"plan" => "PRO"}, %{"plan" => "pro"}, true, true},
        {"ÉLITE", "élite", true, true},
        {[1, "pro"], "1", true, true}
      ]

      for {filter, property, legacy, explicit} <- rows,
          operator <- ["exact", "is_not"] do
        condition = %{"key" => "prop", "operator" => operator, "value" => filter}
        definitions = versioned_snapshot([flag("versioned", [condition])], @matching_version)
        context = %{distinct_id: "user", person_properties: %{"prop" => property}}
        result = LocalEvaluator.evaluate(definitions, context)
        expected = if @matching_version == 2, do: explicit, else: legacy
        expected = if operator == "is_not", do: not expected, else: expected

        assert %Result{enabled: ^expected, locally_evaluated: true} = result.results["versioned"],
               inspect({@matching_version, operator, filter, property, expected, result})

        assert MapSet.size(result.unresolved) == 0
      end
    end
  end

  for {name, property, canonical} <- [
        {"mixed atom and string keys", %{"a" => true, :z => true}, ~s({"a":true,"z":true})},
        {"nested objects and arrays", %{"a" => [%{"b" => 1, :z => 2}], :z => %{a: true}},
         ~s({"a":[{"b":1,"z":2}],"z":{"a":true}})},
        {"large string-key maps",
         Map.new(1..40, &{"key#{String.pad_leading("#{&1}", 2, "0")}", &1}),
         "{" <>
           Enum.map_join(1..40, ",", &~s("key#{String.pad_leading("#{&1}", 2, "0")}":#{&1})) <>
           "}"}
      ] do
    @composite_property property
    @canonical_json canonical
    test "exact and is_not use recursively sorted JSON for #{name}" do
      for version <- [:missing, 1, 2],
          operator <- ["exact", "is_not"],
          {filter, property} <- [
            {@canonical_json, @composite_property},
            {@composite_property, @canonical_json},
            {[@composite_property], @canonical_json}
          ] do
        condition = %{"key" => "prop", "operator" => operator, "value" => filter}
        definitions = versioned_snapshot([flag("canonical", [condition])], version)
        context = %{distinct_id: "user", person_properties: %{"prop" => property}}
        result = LocalEvaluator.evaluate(definitions, context)
        expected = operator == "exact"

        assert %Result{enabled: ^expected, locally_evaluated: true} = result.results["canonical"],
               inspect({version, operator, filter, property, result})

        assert MapSet.size(result.unresolved) == 0
      end
    end
  end

  for version <- [:missing, 1, 2], operator <- ["exact", "is_not"] do
    @matching_version version
    @matching_operator operator
    test "version #{version} #{@matching_operator} leaves composite sigma casing inconclusive" do
      for {upper, lower} <- [
            {%{"name" => "ΟΣ"}, %{"name" => "ος"}},
            {%{"name" => "ΟΣ"}, %{"name" => "οσ"}},
            {%{"ΟΣ" => [%{"name" => "ΟΣ"}]}, %{"ος" => [%{"name" => "ος"}]}},
            {[%{"name" => "ΟΣ"}], [%{"name" => "ος"}]}
          ],
          {filter, property} <- [
            {lower, upper},
            {upper, lower},
            {Jason.encode!(upper), lower},
            {lower, Jason.encode!(upper)},
            {[upper], lower},
            {[lower], upper}
          ] do
        condition = %{"key" => "prop", "operator" => @matching_operator, "value" => filter}
        definitions = versioned_snapshot([flag("unicode", [condition])], @matching_version)
        context = %{distinct_id: "user", person_properties: %{"prop" => property}}
        result = LocalEvaluator.evaluate(definitions, context)

        assert result.results == %{}, inspect({filter, property, result})
        assert result.unresolved == MapSet.new(["unicode"])
      end
    end
  end

  for version <- [:missing, 1, 2], operator <- ["exact", "is_not"] do
    @matching_version version
    @matching_operator operator
    test "version #{version} #{operator} leaves colliding composite keys inconclusive" do
      for {composite, candidates} <- [
            {%{:a => 1, "a" => 2}, [%{"a" => 1}, %{"a" => 2}]},
            {%{"nested" => [%{:a => 1, "a" => 2}]},
             [%{"nested" => [%{"a" => 1}]}, %{"nested" => [%{"a" => 2}]}]}
          ],
          {filter, property} <- [
            {candidates, composite},
            {[composite], hd(candidates)}
          ] do
        condition = %{"key" => "prop", "operator" => @matching_operator, "value" => filter}
        definitions = versioned_snapshot([flag("colliding-keys", [condition])], @matching_version)
        context = %{distinct_id: "user", person_properties: %{"prop" => property}}
        result = LocalEvaluator.evaluate(definitions, context)

        assert result.results == %{}, inspect({filter, property, result})
        assert result.unresolved == MapSet.new(["colliding-keys"])
      end
    end
  end

  test "composite numeric serialization ambiguity stays inconclusive" do
    for version <- [:missing, 1, 2],
        operator <- ["exact", "is_not"],
        {number, service_json} <- [
          {0.00001, "0.00001"},
          {1.0e-7, "1e-7"},
          {1.0e20, "1e20"},
          {18_446_744_073_709_551_616, "1.8446744073709552e19"},
          {-9_223_372_036_854_775_809, "-9.223372036854776e18"}
        ],
        {composite, canonical} <- [
          {%{"n" => number}, ~s({"n":#{service_json}})},
          {[%{"n" => [number]}], ~s([{"n":[#{service_json}]}])}
        ],
        {filter, property} <- [
          {canonical, composite},
          {[composite], canonical}
        ] do
      condition = %{"key" => "prop", "operator" => operator, "value" => filter}
      definitions = versioned_snapshot([flag("numeric-composite", [condition])], version)
      context = %{distinct_id: "user", person_properties: %{"prop" => property}}
      result = LocalEvaluator.evaluate(definitions, context)

      assert result.results == %{}, inspect({version, operator, filter, property, result})
      assert result.unresolved == MapSet.new(["numeric-composite"])
    end
  end

  test "composite integers within the service range still match locally" do
    property = %{"min" => -9_223_372_036_854_775_808, "max" => 18_446_744_073_709_551_615}
    canonical = ~s({"max":18446744073709551615,"min":-9223372036854775808})

    for version <- [:missing, 1, 2], operator <- ["exact", "is_not"] do
      condition = %{"key" => "prop", "operator" => operator, "value" => canonical}
      definitions = versioned_snapshot([flag("integer-composite", [condition])], version)
      context = %{distinct_id: "user", person_properties: %{"prop" => property}}
      result = LocalEvaluator.evaluate(definitions, context)
      expected = operator == "exact"

      assert %Result{enabled: ^expected, locally_evaluated: true} =
               result.results["integer-composite"]

      assert MapSet.size(result.unresolved) == 0
    end
  end

  for {name, property, string} <- [
        {"Date", ~D[2025-01-01], "2025-01-01"},
        {"Time", ~T[12:34:56], "12:34:56"}
      ] do
    @scalar_struct property
    @scalar_string string
    test "exact and is_not preserve ordinary string matching for #{name} properties" do
      for version <- [:missing, 1, 2],
          operator <- ["exact", "is_not"],
          {filter, matches} <- [
            {@scalar_string, true},
            {[@scalar_string], true},
            {"different", false}
          ] do
        condition = %{"key" => "prop", "operator" => operator, "value" => filter}
        definitions = versioned_snapshot([flag("scalar-struct", [condition])], version)
        context = %{distinct_id: "user", person_properties: %{"prop" => @scalar_struct}}
        result = LocalEvaluator.evaluate(definitions, context)
        expected = if operator == "exact", do: matches, else: not matches

        assert %Result{enabled: ^expected, locally_evaluated: true} =
                 result.results["scalar-struct"],
               inspect({version, operator, filter, @scalar_struct, result})

        assert MapSet.size(result.unresolved) == 0
      end
    end
  end

  test "missing properties stay inconclusive for both operators and matching versions" do
    for version <- [:missing, 1, 2], operator <- ["exact", "is_not"] do
      condition = %{"key" => "prop", "operator" => operator, "value" => false}
      definitions = versioned_snapshot([flag("missing", [condition])], version)
      result = LocalEvaluator.evaluate(definitions, %{distinct_id: "user"})
      assert result.results == %{}
      assert MapSet.equal?(result.unresolved, MapSet.new(["missing"]))
    end
  end

  test "person, group, recursive cohort and dependency share one snapshot version" do
    for version <- [:missing, 1, 2], operator <- ["exact", "is_not"] do
      condition = %{"key" => "prop", "operator" => operator, "value" => false}
      person = flag("person", [condition])
      group = put_in(flag("group", [condition]), ["filters", "aggregation_group_type_index"], 0)
      cohort = flag("cohort", [%{"type" => "cohort", "value" => 1}])

      dependency =
        flag("dependency", [
          %{
            "type" => "flag",
            "key" => "person",
            "operator" => "flag_evaluates_to",
            "value" => true,
            "dependency_chain" => ["person"]
          }
        ])

      definitions =
        versioned_snapshot([person, group, cohort, dependency], version)
        |> Map.put(:group_type_mapping, %{"0" => "organization"})
        |> Map.put(:cohorts, %{
          "1" => %{
            "type" => "AND",
            "values" => [
              %{"type" => "OR", "values" => [condition]}
            ]
          }
        })

      context = %{
        distinct_id: "user",
        person_properties: %{prop: "banana"},
        groups: %{organization: "org"},
        group_properties: %{organization: %{prop: "banana"}}
      }

      expected = if operator == "exact", do: version != 2, else: version == 2

      for keys <- [nil, ["dependency"], ["person"], ["group"], ["cohort"]] do
        result = LocalEvaluator.evaluate(definitions, context, keys)
        assert MapSet.size(result.unresolved) == 0

        for key <- keys || ["person", "group", "cohort", "dependency"] do
          assert result.results[key].enabled == expected, inspect({version, operator, key})
        end
      end
    end
  end

  defp versioned_snapshot(flags, :missing), do: snapshot(flags)

  defp versioned_snapshot(flags, version),
    do: snapshot(flags, %{property_matching_version: version})

  test "canonical hash vectors and fractional rollout boundaries" do
    assert_in_delta LocalEvaluator.hash("flag", "user"), 0.4357368498163313, 1.0e-15
    assert_in_delta LocalEvaluator.hash("flag", "user", "variant"), 0.4727021985667222, 1.0e-15

    assert %{"zero" => %Result{enabled: false}} = evaluate(flag("zero", [], 0)).results
    assert %{"all" => %Result{enabled: true}} = evaluate(flag("all", [], 100)).results

    fractional = flag("fractional", [], 0.1)

    assert evaluate(fractional, %{distinct_id: "user-471"}).results["fractional"].enabled
    refute evaluate(fractional, %{distinct_id: "user-0"}).results["fractional"].enabled
  end

  test "inactive, experience continuity, and malformed flags are isolated" do
    good = flag("good")
    inactive = %{flag("inactive") | "active" => false}
    continuity = Map.put(flag("continuity"), "ensure_experience_continuity", true)
    malformed = %{"key" => "bad", "active" => true}
    definitions = snapshot([good, inactive, continuity, malformed])

    result = LocalEvaluator.evaluate(definitions, %{distinct_id: "user"})
    assert result.results["good"].enabled
    refute result.results["inactive"].enabled
    assert MapSet.equal?(result.unresolved, MapSet.new(["continuity", "bad"]))
  end

  test "multivariate variants, overrides, and payload decoding" do
    flag =
      flag("variant")
      |> put_in(["filters", "multivariate"], %{
        "variants" => [
          %{"key" => "control", "rollout_percentage" => 50},
          %{"key" => "test", "rollout_percentage" => 50}
        ]
      })
      |> put_in(["filters", "payloads"], %{"control" => ~s({"color":"blue"}), "test" => "false"})

    result = evaluate(flag).results["variant"]
    assert result.variant in ["control", "test"]
    assert result.payload in [%{"color" => "blue"}, false]

    override = put_in(flag, ["filters", "groups", Access.at(0), "variant"], "test")
    assert %Result{variant: "test", payload: false} = evaluate(override).results["variant"]

    invalid = put_in(flag, ["filters", "groups", Access.at(0), "variant"], "missing")
    assert evaluate(invalid).results["variant"].variant == result.variant

    boolean = put_in(flag("boolean-payload"), ["filters", "payloads"], %{"true" => "true"})
    assert %Result{payload: true} = evaluate(boolean).results["boolean-payload"]
  end

  test "canonical property operators have positive and negative cases" do
    cases = [
      {"exact", "HELLO", "hello", true},
      {"is_not", "hello", "world", true},
      {"is_set", 1, nil, true},
      {"is_not_set", 1, nil, false},
      {"icontains", "Hello World", "WORLD", true},
      {"not_icontains", "Hello", "world", true},
      {"starts_with", 12_345, 123, true},
      {"not_starts_with", "hello", "x", true},
      {"ends_with", "HELLO", "llo", true},
      {"not_ends_with", "hello", "x", true},
      {"regex", "hello123", "[0-9]+$", true},
      {"not_regex", "hello", "[0-9]+$", true},
      {"gt", 3, 2, true},
      {"gte", 3, 3, true},
      {"lt", 2, 3, true},
      {"lte", 3, 3, true},
      {"semver_eq", "1.2.3", "1.2.3", true},
      {"semver_neq", "1.2.4", "1.2.3", true},
      {"semver_gt", "2.0.0", "1.2.3", true},
      {"semver_gte", "1.2.3", "1.2.3", true},
      {"semver_lt", "1.2.2", "1.2.3", true},
      {"semver_lte", "1.2.3", "1.2.3", true},
      {"semver_tilde", "1.2.9", "1.2.3", true},
      {"semver_caret", "1.9.0", "1.2.3", true},
      {"semver_wildcard", "1.2.9", "1.2.*", true}
    ]

    for {operator, actual, expected, enabled} <- cases do
      property = %{"key" => "prop", "operator" => operator, "value" => expected}
      result = evaluate(flag(operator, [property]), %{person_properties: %{prop: actual}})
      assert result.results[operator].enabled == enabled, operator
    end
  end

  test "exact operators use Unicode lowercasing like the flags service" do
    exact = %{"key" => "tier", "operator" => "exact", "value" => "ÉLITE"}
    is_not = %{exact | "operator" => "is_not"}
    context = %{person_properties: %{tier: "élite"}}

    assert evaluate(flag("exact", [exact]), context).results["exact"].enabled
    refute evaluate(flag("is-not", [is_not]), context).results["is-not"].enabled
  end

  test "canonical property operators return definitive false for non-matches" do
    cases = [
      {"exact", "goodbye", "hello"},
      {"is_not", "hello", "hello"},
      {"icontains", "hello", "world"},
      {"not_icontains", "hello world", "world"},
      {"starts_with", "hello", "world"},
      {"not_starts_with", "hello", "hell"},
      {"ends_with", "hello", "world"},
      {"not_ends_with", "hello", "ello"},
      {"regex", "hello", "[0-9]+$"},
      {"not_regex", "hello123", "[0-9]+$"},
      {"gt", 1, 2},
      {"gte", 1, 2},
      {"lt", 2, 1},
      {"lte", 2, 1},
      {"is_date_before", "2025-01-02", "2025-01-01"},
      {"is_date_after", "2025-01-01", "2025-01-02"},
      {"semver_eq", "1.2.4", "1.2.3"},
      {"semver_neq", "1.2.3", "1.2.3"},
      {"semver_gt", "1.2.2", "1.2.3"},
      {"semver_gte", "1.2.2", "1.2.3"},
      {"semver_lt", "1.2.4", "1.2.3"},
      {"semver_lte", "1.2.4", "1.2.3"},
      {"semver_tilde", "1.3.0", "1.2.3"},
      {"semver_caret", "2.0.0", "1.2.3"},
      {"semver_wildcard", "1.3.0", "1.2.*"}
    ]

    for {operator, actual, expected} <- cases do
      property = %{"key" => "prop", "operator" => operator, "value" => expected}
      result = evaluate(flag(operator, [property]), %{person_properties: %{prop: actual}})
      refute result.results[operator].enabled, operator
    end
  end

  test "numeric operators leave semver-shaped strings inconclusive" do
    property = %{"key" => "version", "operator" => "gt", "value" => "2.0.0"}

    result =
      evaluate(flag("numeric-semver", [property]), %{
        person_properties: %{version: "2.5.0"}
      })

    assert MapSet.member?(result.unresolved, "numeric-semver")
  end

  test "semver normalization matches maintained server SDKs" do
    parity = [
      {"  V1.2.3-beta+build  ", "1.2.3", true},
      {"v1.2", "1.2.0", true},
      {"1", "1.0.0", true},
      {"1.2.4-alpha", "1.2.3+build", false}
    ]

    for {actual, expected, equal?} <- parity do
      property = %{"key" => "version", "operator" => "semver_eq", "value" => expected}
      result = evaluate(flag("semver", [property]), %{person_properties: %{version: actual}})
      assert result.results["semver"].enabled == equal?
    end

    for invalid <- ["01", "1.02", "1.2.03"] do
      property = %{"key" => "version", "operator" => "semver_eq", "value" => "1.2.3"}
      result = evaluate(flag("invalid", [property]), %{person_properties: %{version: invalid}})
      assert MapSet.member?(result.unresolved, "invalid")
    end

    ignored_extra = %{"key" => "version", "operator" => "semver_eq", "value" => "1.2.3"}

    assert evaluate(flag("extra", [ignored_extra]), %{
             person_properties: %{version: "1.2.3.999.unused"}
           }).results["extra"].enabled

    wildcard = %{"key" => "version", "operator" => "semver_wildcard", "value" => " V1.2.* "}

    assert evaluate(flag("wildcard", [wildcard]), %{person_properties: %{version: "1.2.9-rc"}}).results[
             "wildcard"
           ].enabled

    malformed = %{wildcard | "value" => "1x.*"}

    assert MapSet.member?(
             evaluate(flag("malformed", [malformed]), %{
               person_properties: %{version: "1.2.3"}
             }).unresolved,
             "malformed"
           )
  end

  test "date operators use the injected clock and timezone-less ISO values as UTC" do
    now = ~U[2025-01-10 00:00:00Z]
    before = %{"key" => "created", "operator" => "is_date_before", "value" => "1d"}
    after_property = %{"key" => "created", "operator" => "is_date_after", "value" => "2025-01-01"}

    assert evaluate(flag("before", [before]), %{
             person_properties: %{created: "2025-01-01"},
             now: now
           }).results["before"].enabled

    assert evaluate(flag("after", [after_property]), %{
             person_properties: %{created: "2025-01-02"},
             now: now
           }).results["after"].enabled

    for datetime <- ["2025-01-02T03:04:05", "2025-01-02 03:04:05"] do
      property = %{
        "key" => "created",
        "operator" => "is_date_after",
        "value" => "2025-01-02T03:04:04Z"
      }

      assert evaluate(flag("timezone-less", [property]), %{
               person_properties: %{created: datetime},
               now: now
             }).results["timezone-less"].enabled
    end

    for property <- [
          %{"key" => "x", "operator" => "unknown", "value" => 1},
          %{"key" => "x", "operator" => "regex", "value" => "["},
          %{"key" => "x", "operator" => "is_date_before", "value" => "never"},
          %{"key" => "x", "operator" => "semver_eq", "value" => "01.2.3"}
        ] do
      result = evaluate(flag("bad", [property]), %{person_properties: %{x: "bad"}})
      assert MapSet.member?(result.unresolved, "bad")
    end
  end

  test "is_set uses property presence while other operators handle nil values" do
    no_match_operators = [
      "exact",
      "icontains",
      "not_icontains",
      "starts_with",
      "not_starts_with",
      "ends_with",
      "not_ends_with",
      "regex",
      "not_regex",
      "gt",
      "gte",
      "lt",
      "lte",
      "is_date_before",
      "is_date_after",
      "semver_eq",
      "semver_neq",
      "semver_gt",
      "semver_gte",
      "semver_lt",
      "semver_lte",
      "semver_tilde",
      "semver_caret",
      "semver_wildcard"
    ]

    for operator <- no_match_operators do
      property = %{"key" => "prop", "operator" => operator, "value" => "value"}
      result = evaluate(flag(operator, [property]), %{person_properties: %{prop: nil}})
      assert %Result{enabled: false} = result.results[operator], operator
    end

    is_not = %{"key" => "prop", "operator" => "is_not", "value" => "value"}

    assert evaluate(flag("is-not", [is_not]), %{person_properties: %{prop: nil}}).results[
             "is-not"
           ].enabled

    is_set = %{"key" => "prop", "operator" => "is_set", "value" => nil}

    assert evaluate(flag("is-set", [is_set]), %{person_properties: %{prop: nil}}).results[
             "is-set"
           ].enabled

    for value <- [false, 0, "", [], %{}] do
      assert evaluate(flag("is-set", [is_set]), %{person_properties: %{prop: value}}).results[
               "is-set"
             ].enabled
    end

    absent = %{"key" => "prop", "operator" => "is_not_set", "value" => nil}
    assert MapSet.member?(evaluate(flag("absent", [absent])).unresolved, "absent")

    refute evaluate(flag("present", [absent]), %{person_properties: %{prop: nil}}).results[
             "present"
           ].enabled
  end

  test "early exit preserves prior inconclusive state and later conditions can recover" do
    missing = %{"properties" => [%{"key" => "missing", "value" => true}]}
    out_of_rollout = %{"properties" => [], "rollout_percentage" => 0}

    early =
      flag("early")
      |> put_in(["filters", "early_exit"], true)
      |> put_in(["filters", "groups"], [missing, out_of_rollout])

    assert MapSet.member?(evaluate(early).unresolved, "early")

    recovered =
      put_in(early, ["filters", "groups"], [
        missing,
        %{"properties" => [], "rollout_percentage" => 100}
      ])

    assert evaluate(recovered).results["early"].enabled
  end

  test "missing properties are inconclusive without contaminating another flag" do
    definitions =
      snapshot([
        flag("missing", [%{"key" => "plan", "operator" => "exact", "value" => "pro"}]),
        flag("good")
      ])

    result = LocalEvaluator.evaluate(definitions, %{distinct_id: "user", person_properties: %{}})

    assert result.results["good"].enabled
    assert MapSet.member?(result.unresolved, "missing")
  end

  test "built-in identity properties are available without caller property maps" do
    person_property = %{
      "key" => "distinct_id",
      "operator" => "exact",
      "value" => "person-1"
    }

    assert evaluate(flag("person", [person_property]), %{distinct_id: "person-1"}).results[
             "person"
           ].enabled

    refute evaluate(flag("person", [person_property]), %{
             distinct_id: "person-1",
             person_properties: %{distinct_id: "override"}
           }).results["person"].enabled

    group =
      flag("group", [%{"key" => "$group_key", "operator" => "exact", "value" => "org-1"}])
      |> put_in(["filters", "aggregation_group_type_index"], 0)

    definitions = snapshot([group], %{group_type_mapping: %{"0" => "organization"}})

    assert LocalEvaluator.evaluate(definitions, %{
             distinct_id: "person-1",
             groups: %{organization: "org-1"}
           }).results["group"].enabled

    refute LocalEvaluator.evaluate(definitions, %{
             distinct_id: "person-1",
             groups: %{organization: "org-1"},
             group_properties: %{organization: %{"$group_key" => "override"}}
           }).results["group"].enabled
  end

  test "group and mixed targeting use group properties and group keys" do
    group = put_in(flag("group"), ["filters", "aggregation_group_type_index"], 0)

    group =
      put_in(group, ["filters", "groups", Access.at(0), "properties"], [
        %{"key" => "tier", "value" => "pro", "operator" => "exact"}
      ])

    definitions = snapshot([group], %{group_type_mapping: %{"0" => "organization"}})

    context = %{
      distinct_id: "person",
      groups: %{organization: "org-1"},
      group_properties: %{organization: %{tier: "pro"}}
    }

    assert LocalEvaluator.evaluate(definitions, context).results["group"].enabled

    missing_group_properties = %{distinct_id: "person", groups: %{organization: "org-1"}}

    assert MapSet.member?(
             LocalEvaluator.evaluate(definitions, missing_group_properties).unresolved,
             "group"
           )

    bucketed_group = put_in(group, ["filters", "groups", Access.at(0), "rollout_percentage"], 50)

    bucketed_definitions =
      snapshot([bucketed_group], %{group_type_mapping: %{"0" => "organization"}})

    inside_group = put_in(context, [:groups, :organization], "id-3")
    outside_group = put_in(context, [:groups, :organization], "id-0")
    assert LocalEvaluator.evaluate(bucketed_definitions, inside_group).results["group"].enabled
    refute LocalEvaluator.evaluate(bucketed_definitions, outside_group).results["group"].enabled

    assert MapSet.member?(
             LocalEvaluator.evaluate(definitions, %{distinct_id: "person"}).unresolved,
             "group"
           )

    mixed = flag("mixed")

    condition = %{
      "aggregation_group_type_index" => 0,
      "properties" => [%{"key" => "tier", "value" => "pro"}],
      "rollout_percentage" => 100
    }

    mixed = put_in(mixed, ["filters", "groups"], [condition])
    definitions = snapshot([mixed], %{group_type_mapping: %{"0" => "organization"}})
    assert LocalEvaluator.evaluate(definitions, context).results["mixed"].enabled
  end

  test "device bucketing requires a device id and uses it for rollout" do
    device_flag = Map.put(flag("device", [], 50), "bucketing_identifier", "device_id")
    assert MapSet.member?(evaluate(device_flag).unresolved, "device")
    assert evaluate(device_flag, %{device_id: "id-0"}).results["device"].enabled
    refute evaluate(device_flag, %{device_id: "id-2"}).results["device"].enabled
  end

  test "nested cohorts and negation, missing cohorts, dependencies, and cycles" do
    cohort_property = %{"type" => "cohort", "value" => 1, "operator" => "exact"}
    cohort_flag = flag("cohort", [cohort_property])

    cohort = %{
      "type" => "OR",
      "values" => [
        %{"key" => "region", "value" => "UK"},
        %{"key" => "plan", "value" => "pro", "negation" => true}
      ]
    }

    definitions = snapshot([cohort_flag], %{cohorts: %{"1" => cohort}})

    assert LocalEvaluator.evaluate(definitions, %{
             distinct_id: "u",
             person_properties: %{region: "UK"}
           }).results["cohort"].enabled

    missing =
      LocalEvaluator.evaluate(snapshot([cohort_flag]), %{
        distinct_id: "u",
        person_properties: %{region: "UK"}
      })

    assert MapSet.member?(missing.unresolved, "cohort")

    base = flag("base")

    dependency = %{
      "type" => "flag",
      "key" => "base",
      "operator" => "flag_evaluates_to",
      "value" => true,
      "dependency_chain" => ["base"]
    }

    dependent = flag("dependent", [dependency])
    result = LocalEvaluator.evaluate(snapshot([base, dependent]), %{distinct_id: "u"})
    assert result.results["dependent"].enabled

    a_dep = %{dependency | "key" => "b", "dependency_chain" => ["b"]}
    b_dep = %{dependency | "key" => "a", "dependency_chain" => ["a"]}
    cycle = snapshot([flag("a", [a_dep]), flag("b", [b_dep])])
    result = LocalEvaluator.evaluate(cycle, %{distinct_id: "u"})
    assert MapSet.equal?(result.unresolved, MapSet.new(["a", "b"]))
  end

  test "cohort requires-server precedence, nested empty groups, and nested negation" do
    cohort_property = %{"type" => "cohort", "value" => "outer"}
    cohort_flag = flag("cohort", [cohort_property])

    missing_static = %{"type" => "cohort", "value" => "static"}
    matching = %{"key" => "region", "value" => "UK"}

    for type <- ["AND", "OR"] do
      cohort = %{"type" => type, "values" => [matching, missing_static]}
      definitions = snapshot([cohort_flag], %{cohorts: %{"outer" => cohort}})

      result =
        LocalEvaluator.evaluate(definitions, %{
          distinct_id: "u",
          person_properties: %{region: "UK"}
        })

      assert MapSet.member?(result.unresolved, "cohort")
    end

    nested = %{
      "type" => "AND",
      "values" => [
        %{},
        %{
          "type" => "OR",
          "values" => [%{"key" => "region", "value" => "US"}],
          "negation" => true
        }
      ]
    }

    definitions = snapshot([cohort_flag], %{cohorts: %{"outer" => nested}})

    assert LocalEvaluator.evaluate(definitions, %{
             distinct_id: "u",
             person_properties: %{region: "UK"}
           }).results["cohort"].enabled

    malformed = snapshot([cohort_flag], %{cohorts: %{"outer" => %{"values" => []}}})

    assert MapSet.member?(
             LocalEvaluator.evaluate(malformed, %{distinct_id: "u"}).unresolved,
             "cohort"
           )
  end

  test "dependency chains validate every member and compare false and variant results" do
    false_flag = %{flag("false-flag") | "active" => false}

    variant =
      flag("variant")
      |> put_in(["filters", "multivariate"], %{
        "variants" => [%{"key" => "control", "rollout_percentage" => 100}]
      })

    false_dependency = %{
      "type" => "flag",
      "key" => "false-flag",
      "operator" => "flag_evaluates_to",
      "value" => false,
      "dependency_chain" => ["false-flag"]
    }

    variant_dependency = %{
      "type" => "flag",
      "key" => "variant",
      "operator" => "flag_evaluates_to",
      "value" => "control",
      "dependency_chain" => ["variant"]
    }

    repeated = flag("repeated", [variant_dependency, variant_dependency])

    definitions =
      snapshot([false_flag, variant, flag("false-parent", [false_dependency]), repeated])

    result = LocalEvaluator.evaluate(definitions, %{distinct_id: "u"})
    assert result.results["false-parent"].enabled
    assert result.results["repeated"].enabled

    missing_member = %{variant_dependency | "dependency_chain" => ["missing", "variant"]}
    definitions = snapshot([variant, flag("missing-parent", [missing_member])])
    result = LocalEvaluator.evaluate(definitions, %{distinct_id: "u"})
    assert MapSet.member?(result.unresolved, "missing-parent")
  end

  test "fixed context and clock are deterministic and unknown operators stay flag scoped" do
    unknown = flag("unknown", [%{"key" => "x", "operator" => "future", "value" => 1}])
    dated = flag("dated", [%{"key" => "date", "operator" => "is_date_after", "value" => "1d"}])
    definitions = snapshot([unknown, dated, flag("good")])

    context = %{
      distinct_id: "u",
      person_properties: %{x: 1, date: "2025-01-11"},
      now: ~U[2025-01-11 12:00:00Z]
    }

    first = LocalEvaluator.evaluate(definitions, context)
    second = LocalEvaluator.evaluate(definitions, context)
    assert first.results == second.results
    assert first.results["good"].enabled
    assert first.results["dated"].enabled
    assert MapSet.equal?(first.unresolved, MapSet.new(["unknown"]))
  end
end
