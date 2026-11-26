defmodule PostHog.FeatureFlags.KnownAbsentPropertyKeysTest do
  use ExUnit.Case, async: false
  import Mox

  alias PostHog.FeatureFlags
  alias PostHog.FeatureFlags.LocalEvaluator

  @moduletag capture_log: true

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    stub(PostHog.API.Mock, :client, fn _api_key, _host ->
      %PostHog.API.Client{client: :stub_client, module: PostHog.API.Mock}
    end)

    :ok
  end

  defp flag(key, properties, extra_filters \\ %{}) do
    %{
      "id" => 1,
      "version" => 1,
      "key" => key,
      "active" => true,
      "filters" =>
        Map.merge(
          %{"groups" => [%{"properties" => properties, "rollout_percentage" => 100}]},
          extra_filters
        )
    }
  end

  defp snapshot(flags, extras \\ %{}) do
    Map.merge(
      %{
        flags: flags,
        flags_by_key: Map.new(flags, &{&1["key"], &1}),
        group_type_mapping: %{"0" => "organization", "1" => "project"},
        cohorts: %{},
        minimal_flag_called_events: false
      },
      extras
    )
  end

  defp local(definitions, context, key) do
    result = LocalEvaluator.evaluate(definitions, Map.put_new(context, :distinct_id, "user"))

    case result.results do
      %{^key => flag_result} -> {:ok, flag_result.enabled}
      _unresolved -> {:unresolved, result.reasons[key]}
    end
  end

  defp group_filter(key, operator, value \\ nil) do
    filter = %{"key" => key, "type" => "group", "operator" => operator, "group_type_index" => 0}
    if is_nil(value), do: filter, else: Map.put(filter, "value", value)
  end

  defp flag_dependency(key) do
    %{
      "type" => "flag",
      "key" => key,
      "operator" => "flag_evaluates_to",
      "value" => true,
      "dependency_chain" => [key]
    }
  end

  defp person_filter(operator, value \\ nil) do
    filter = %{"key" => "plan", "type" => "person", "operator" => operator}
    if is_nil(value), do: filter, else: Map.put(filter, "value", value)
  end

  # The flags service decides each operator for a missing key before it reads the condition
  # value, so invalid, malformed or non-portable values don't change the result.
  @unread_condition_values [
    {"not_regex", "[", true},
    {"regex", "[", false},
    {"not_regex", "(?<=a)b", true},
    {"regex", "(?<=a)b", false},
    {"not_regex", "\\p{L}", true},
    {"regex", "\\p{L}", false},
    {"gt", "not-a-number", false},
    {"gte", "not-a-number", false},
    {"lt", "not-a-number", false},
    {"lte", "not-a-number", false},
    {"semver_eq", "not-a-version", false},
    {"semver_gt", "not-a-version", false},
    {"semver_tilde", "not-a-version", false},
    {"is_date_before", "not-a-date", false},
    {"is_date_after", "not-a-date", false}
  ]

  # Operators that read the condition value, so a listed key needs one to resolve.
  @value_operators ["exact", "is_not", "icontains", "gt", "is_date_before"]

  # A usable group key is a non-empty string or a number, as in the flags service.
  @unusable_group_keys ["", nil, true, false, [], ["acme"], %{}, %{"id" => "acme"}]

  describe "local evaluation" do
    for {operator, value, expected} <- [
          {"is_not_set", nil, true},
          {"is_set", nil, false},
          {"exact", "pro", false},
          {"is_not", "pro", true},
          {"icontains", "pro", false},
          {"not_icontains", "pro", true},
          {"starts_with", "pro", false},
          {"not_starts_with", "pro", true},
          {"ends_with", "pro", false},
          {"not_ends_with", "pro", true},
          {"regex", "^pro", false},
          {"not_regex", "^pro", true},
          {"gt", "10", false},
          {"gte", "10", false},
          {"lt", "10", false},
          {"lte", "10", false},
          {"semver_eq", "1.2.3", false},
          {"semver_neq", "1.2.3", false},
          {"semver_gt", "1.2.3", false},
          {"semver_tilde", "1.2.3", false},
          {"semver_caret", "1.2.3", false},
          {"semver_wildcard", "1.2.*", false},
          {"is_date_before", "2025-01-01T10:00:00Z", false},
          {"is_date_after", "2025-01-01T10:00:00Z", false}
        ] do
      @operator operator
      @value value
      @expected expected

      test "listed key resolves #{operator} to #{expected}" do
        definitions = snapshot([flag("f", [person_filter(@operator, @value)])])

        for context <- [
              %{person_property_keys_known_absent: ["plan"]},
              # A listed key wins over a supplied value.
              %{
                person_properties: %{"plan" => "pro"},
                person_property_keys_known_absent: [:plan]
              },
              %{person_properties: %{plan: "pro"}, person_property_keys_known_absent: ["plan"]}
            ] do
          assert local(definitions, context, "f") == {:ok, @expected}, inspect(context)
        end
      end
    end

    test "listed key overrides the injected distinct_id and $group_key" do
      person = snapshot([flag("person", [%{"key" => "distinct_id", "operator" => "is_set"}])])

      assert local(person, %{}, "person") == {:ok, true}

      assert local(person, %{person_property_keys_known_absent: ["distinct_id"]}, "person") ==
               {:ok, false}

      group =
        flag(
          "group",
          [%{"key" => "$group_key", "type" => "group", "operator" => "is_not_set"}],
          %{
            "aggregation_group_type_index" => 0
          }
        )

      definitions = snapshot([group])
      context = %{groups: %{organization: "acme"}}

      assert local(definitions, context, "group") == {:ok, false}

      assert local(
               definitions,
               Map.put(context, :group_property_keys_known_absent, %{
                 "organization" => ["$group_key"]
               }),
               "group"
             ) == {:ok, true}
    end

    test "an omitted key that is not listed stays inconclusive" do
      definitions = snapshot([flag("f", [person_filter("is_not_set")])])

      assert local(definitions, %{}, "f") == {:unresolved, :missing_context}

      assert local(definitions, %{person_property_keys_known_absent: ["region"]}, "f") ==
               {:unresolved, :missing_context}
    end

    test "person metadata keys are ignored" do
      key = "__posthog_person_metadata__created_at"
      definitions = snapshot([flag("f", [%{"key" => key, "operator" => "is_set"}])])

      context = %{
        person_properties: %{key => "2024-01-01"},
        person_property_keys_known_absent: [key]
      }

      assert local(definitions, context, "f") == {:ok, true}

      assert local(definitions, %{person_property_keys_known_absent: [key]}, "f") ==
               {:unresolved, :missing_context}
    end

    test "group keys apply only to their own group type" do
      tier = %{
        "key" => "tier",
        "type" => "group",
        "operator" => "is_not_set",
        "group_type_index" => 0
      }

      definitions = snapshot([flag("org", [tier], %{"aggregation_group_type_index" => 0})])
      groups = %{"organization" => "acme", "project" => "web"}

      assert local(
               definitions,
               %{groups: groups, group_property_keys_known_absent: %{"project" => ["tier"]}},
               "org"
             ) == {:unresolved, :missing_context}

      assert local(
               definitions,
               %{groups: groups, person_property_keys_known_absent: ["tier"]},
               "org"
             ) == {:unresolved, :missing_context}

      assert local(
               definitions,
               %{
                 groups: groups,
                 group_properties: %{organization: %{tier: "gold"}},
                 group_property_keys_known_absent: %{organization: ["tier"]}
               },
               "org"
             ) == {:ok, true}
    end

    test "group keys apply to a group condition inside a person flag" do
      condition = %{
        "properties" => [%{"key" => "tier", "type" => "group", "operator" => "is_set"}],
        "rollout_percentage" => 100,
        "aggregation_group_type_index" => 0
      }

      mixed = %{flag("mixed", []) | "filters" => %{"groups" => [condition]}}
      definitions = snapshot([mixed])

      assert local(
               definitions,
               %{
                 groups: %{organization: "acme"},
                 group_property_keys_known_absent: %{"organization" => ["tier"]}
               },
               "mixed"
             ) == {:ok, false}
    end

    for {operator, value} <- [
          {"icontains_multi", ["pro"]},
          {"not_icontains_multi", ["pro"]},
          {"between", [1, 2]},
          {"not_between", [1, 2]},
          {"future_operator", "pro"}
        ] do
      @operator operator
      @value value

      test "unsupported #{operator} on a listed key stays inconclusive" do
        definitions = snapshot([flag("f", [person_filter(@operator, @value)])])
        context = %{person_property_keys_known_absent: ["plan"]}

        assert local(definitions, context, "f") == {:unresolved, :unsupported_definition}
      end
    end

    test "a listed key resolves without reading a present condition value" do
      context = %{person_property_keys_known_absent: ["plan"]}

      for {operator, value, expected} <- @unread_condition_values do
        definitions =
          snapshot(
            [
              flag("f", [person_filter(operator, value)]),
              flag("cohort", [%{"type" => "cohort", "value" => 1}])
            ],
            %{
              cohorts: %{
                "1" => %{"type" => "AND", "values" => [person_filter(operator, value)]}
              }
            }
          )

        assert local(definitions, context, "f") == {:ok, expected}, inspect({operator, value})

        assert local(definitions, context, "cohort") == {:ok, expected},
               inspect({:cohort, operator, value})
      end
    end

    test "an omitted or null condition value on a listed key stays inconclusive" do
      context = %{person_property_keys_known_absent: ["plan"]}

      filters = [
        %{"key" => "plan", "type" => "person", "operator" => "is_not"},
        %{"key" => "plan", "type" => "person", "operator" => "is_not", "value" => nil},
        %{"key" => "plan", "type" => "person", "operator" => "exact", "value" => nil},
        %{"key" => "plan", "type" => "person", "operator" => "gt", "value" => nil}
      ]

      for filter <- filters do
        definitions = snapshot([flag("f", [filter])])

        assert local(definitions, context, "f") == {:unresolved, :unsupported_definition},
               inspect(filter)
      end
    end

    test "an omitted or null condition value on a listed and supplied key stays inconclusive" do
      for operator <- @value_operators,
          filter <- [person_filter(operator), Map.put(person_filter(operator), "value", nil)],
          context <- [
            %{person_property_keys_known_absent: ["plan"]},
            %{person_properties: %{"plan" => "pro"}, person_property_keys_known_absent: ["plan"]},
            %{
              person_properties: %{plan: "2020-01-01"},
              person_property_keys_known_absent: [:plan]
            }
          ] do
        definitions = snapshot([flag("f", [filter])])

        assert local(definitions, context, "f") == {:unresolved, :unsupported_definition},
               inspect({filter, context})
      end
    end

    test "is_set and is_not_set without a condition value on a listed and supplied key resolve" do
      for {operator, expected} <- [{"is_not_set", true}, {"is_set", false}],
          filter <- [person_filter(operator), Map.put(person_filter(operator), "value", nil)],
          context <- [
            %{person_property_keys_known_absent: ["plan"]},
            %{person_properties: %{"plan" => "pro"}, person_property_keys_known_absent: ["plan"]}
          ] do
        definitions = snapshot([flag("f", [filter])])

        assert local(definitions, context, "f") == {:ok, expected}, inspect({filter, context})
      end
    end

    test "an omitted or null condition value on a supplied key that is not listed keeps its result" do
      context = %{person_properties: %{"plan" => "pro"}}

      for {operator, expected} <- [
            {"exact", {:ok, false}},
            {"is_not", {:ok, true}},
            {"icontains", {:ok, true}},
            {"gt", {:unresolved, :unsupported_definition}},
            {"is_date_before", {:unresolved, :unsupported_definition}}
          ],
          filter <- [person_filter(operator), Map.put(person_filter(operator), "value", nil)] do
        definitions = snapshot([flag("f", [filter])])

        assert local(definitions, context, "f") == expected, inspect(filter)
      end
    end

    test "is_set and is_not_set with a null condition value on a listed key keep their result" do
      context = %{person_property_keys_known_absent: ["plan"]}

      for {operator, expected} <- [{"is_not_set", true}, {"is_set", false}] do
        filter = %{"key" => "plan", "type" => "person", "operator" => operator, "value" => nil}
        definitions = snapshot([flag("f", [filter])])

        assert local(definitions, context, "f") == {:ok, expected}, operator
      end
    end

    test "dynamic cohort leaves apply known absence before negation" do
      cohort = %{
        "type" => "AND",
        "values" => [
          %{"key" => "plan", "operator" => "exact", "value" => "pro", "negation" => true}
        ]
      }

      negated_not_set = %{
        "type" => "AND",
        "values" => [%{"key" => "plan", "operator" => "is_not_set", "negation" => true}]
      }

      definitions =
        snapshot(
          [
            flag("cohort", [%{"type" => "cohort", "value" => 1}]),
            flag("negated", [%{"type" => "cohort", "value" => 2}])
          ],
          %{cohorts: %{"1" => cohort, "2" => negated_not_set}}
        )

      context = %{person_properties: %{plan: "pro"}, person_property_keys_known_absent: ["plan"]}

      assert local(definitions, context, "cohort") == {:ok, true}
      assert local(definitions, context, "negated") == {:ok, false}
      assert local(definitions, %{}, "cohort") == {:unresolved, :missing_context}
    end

    test "unsupported not_between in a dynamic cohort leaf on a listed key stays inconclusive" do
      leaf = %{
        "key" => "plan",
        "type" => "person",
        "operator" => "not_between",
        "value" => [1, 2]
      }

      definitions =
        snapshot(
          [
            flag("cohort", [%{"type" => "cohort", "value" => 1}]),
            flag("negated", [%{"type" => "cohort", "value" => 2}])
          ],
          %{
            cohorts: %{
              "1" => %{"type" => "AND", "values" => [leaf]},
              "2" => %{"type" => "AND", "values" => [Map.put(leaf, "negation", true)]}
            }
          }
        )

      context = %{person_property_keys_known_absent: ["plan"]}

      assert local(definitions, context, "cohort") == {:unresolved, :unsupported_definition}
      assert local(definitions, context, "negated") == {:unresolved, :unsupported_definition}
    end

    test "person_metadata created_at never resolves from a listed created_at" do
      date = %{
        "type" => "person_metadata",
        "key" => "created_at",
        "operator" => "is_date_after",
        "value" => "2000-01-01"
      }

      not_set = %{"type" => "person_metadata", "key" => "created_at", "operator" => "is_not_set"}

      definitions =
        snapshot(
          [
            flag("date", [date]),
            flag("not_set", [not_set]),
            flag("cohort_date", [%{"type" => "cohort", "value" => 1}]),
            flag("cohort_not_set", [%{"type" => "cohort", "value" => 2}])
          ],
          %{
            cohorts: %{
              "1" => %{"type" => "AND", "values" => [date]},
              "2" => %{"type" => "AND", "values" => [not_set]}
            }
          }
        )

      listed = %{person_property_keys_known_absent: ["created_at"]}

      for context <- [
            listed,
            %{person_property_keys_known_absent: ["created_at", :created_at, "created_at"]}
          ],
          key <- ["date", "not_set", "cohort_date", "cohort_not_set"] do
        assert local(definitions, context, key) == {:unresolved, :missing_context},
               inspect({context, key})
      end

      # A supplied value resolves as if the key were not listed.
      supplied = Map.put(listed, :person_properties, %{"created_at" => "2024-01-01"})

      assert local(definitions, supplied, "date") == {:ok, true}
      assert local(definitions, supplied, "not_set") == {:ok, false}
      assert local(definitions, supplied, "cohort_date") == {:ok, true}
      assert local(definitions, supplied, "cohort_not_set") == {:ok, false}
    end

    test "group keys apply only to group filters of their own group type" do
      project_tier = %{
        "key" => "tier",
        "type" => "group",
        "operator" => "is_not_set",
        "group_type_index" => 1
      }

      definitions =
        snapshot([flag("org", [project_tier], %{"aggregation_group_type_index" => 0})])

      context = %{
        groups: %{"organization" => "acme", "project" => "web"},
        group_property_keys_known_absent: %{"organization" => ["tier"]}
      }

      assert local(definitions, context, "org") == {:unresolved, :missing_context}
    end

    test "group keys never apply to person filters or person cohort leaves" do
      plan = person_filter("is_not_set")

      definitions =
        snapshot(
          [
            flag("person_filter", [plan], %{"aggregation_group_type_index" => 0}),
            flag("person_leaf", [%{"type" => "cohort", "value" => 1}], %{
              "aggregation_group_type_index" => 0
            })
          ],
          %{cohorts: %{"1" => %{"type" => "AND", "values" => [plan]}}}
        )

      context = %{
        groups: %{"organization" => "acme"},
        group_property_keys_known_absent: %{"organization" => ["plan"]}
      }

      assert local(definitions, context, "person_filter") == {:unresolved, :missing_context}
      assert local(definitions, context, "person_leaf") == {:unresolved, :missing_context}
    end

    test "flag dependencies with a different aggregation don't use the other scope's listing" do
      depends_on = fn key, dependency, extra_filters ->
        flag(
          key,
          [
            %{
              "type" => "flag",
              "key" => dependency,
              "operator" => "flag_evaluates_to",
              "value" => true,
              "dependency_chain" => [dependency]
            }
          ],
          extra_filters
        )
      end

      group_tier = %{
        "key" => "tier",
        "type" => "group",
        "operator" => "is_not_set",
        "group_type_index" => 0
      }

      definitions =
        snapshot([
          flag("group_base", [group_tier], %{"aggregation_group_type_index" => 0}),
          flag("person_base", [person_filter("is_not_set")]),
          depends_on.("person_parent", "group_base", %{}),
          depends_on.("group_parent", "person_base", %{"aggregation_group_type_index" => 0})
        ])

      groups = %{"organization" => "acme"}

      assert local(
               definitions,
               %{groups: groups, person_property_keys_known_absent: ["tier"]},
               "person_parent"
             ) == {:unresolved, :unresolved_dependency}

      assert local(
               definitions,
               %{groups: groups, group_property_keys_known_absent: %{"organization" => ["plan"]}},
               "group_parent"
             ) == {:unresolved, :unresolved_dependency}

      assert local(
               definitions,
               %{
                 groups: groups,
                 person_property_keys_known_absent: ["plan"],
                 group_property_keys_known_absent: %{"organization" => ["tier"]}
               },
               "person_parent"
             ) == {:ok, true}
    end

    test "a dependency is evaluated with its own aggregation" do
      definitions =
        snapshot([
          flag("org-parent", [group_filter("region", "exact", "us")], %{
            "aggregation_group_type_index" => 0
          }),
          flag("person-child", [flag_dependency("org-parent")])
        ])

      context = %{
        groups: %{"organization" => "acme"},
        person_properties: %{"region" => "us"},
        group_properties: %{"organization" => %{"region" => "eu"}}
      }

      assert local(definitions, context, "org-parent") == {:ok, false}
      assert local(definitions, context, "person-child") == {:ok, false}
    end

    test "a group dependency without its group resolves as false" do
      definitions =
        snapshot([
          flag("org-parent", [group_filter("tier", "is_not_set")], %{
            "aggregation_group_type_index" => 0
          }),
          flag("person-child", [flag_dependency("org-parent")])
        ])

      context = %{group_property_keys_known_absent: %{"organization" => ["tier"]}}

      assert local(definitions, context, "org-parent") == {:ok, false}
      assert local(definitions, context, "person-child") == {:ok, false}
    end

    test "a group dependency with its group key but without the group properties stays inconclusive" do
      definitions =
        snapshot([
          flag("org-parent", [group_filter("tier", "exact", "pro")], %{
            "aggregation_group_type_index" => 0
          }),
          flag("person-child", [flag_dependency("org-parent")])
        ])

      context = %{groups: %{"organization" => "acme"}}

      assert local(definitions, context, "org-parent") == {:unresolved, :missing_context}
      assert local(definitions, context, "person-child") == {:unresolved, :unresolved_dependency}
    end

    test "a group dependency buckets by its group key" do
      definitions =
        snapshot([
          flag("org-parent", [], %{"aggregation_group_type_index" => 0})
          |> put_in(["filters", "groups", Access.at(0), "rollout_percentage"], 50),
          flag("person-child", [flag_dependency("org-parent")])
        ])

      for {distinct_id, group_key} <- [{"u3", "q1"}, {"u2", "zzz"}, {"u1", "acme"}] do
        in_rollout = LocalEvaluator.hash("org-parent", group_key) < 0.5
        context = %{distinct_id: distinct_id, groups: %{"organization" => group_key}}

        assert local(definitions, context, "person-child") == {:ok, in_rollout}
      end

      assert LocalEvaluator.hash("org-parent", "q1") < 0.5
      refute LocalEvaluator.hash("org-parent", "u3") < 0.5
    end

    test "a person dependency of a group flag reads person properties and the distinct id" do
      definitions =
        snapshot([
          flag("person-parent", [
            person_filter("is_not_set"),
            %{"key" => "region", "type" => "person", "operator" => "exact", "value" => "us"}
          ]),
          flag("org-child", [flag_dependency("person-parent")], %{
            "aggregation_group_type_index" => 0
          })
        ])

      context = %{
        groups: %{"organization" => "acme"},
        person_properties: %{"region" => "us"},
        group_properties: %{"organization" => %{"region" => "eu"}},
        person_property_keys_known_absent: ["plan"]
      }

      assert local(definitions, context, "person-parent") == {:ok, true}
      assert local(definitions, context, "org-child") == {:ok, true}
    end

    test "a group filter without a group type index reads the condition's group type" do
      legacy = fn key, operator, value ->
        filter = %{"key" => "tier", "type" => "group", "operator" => operator}
        filter = if is_nil(value), do: filter, else: Map.put(filter, "value", value)
        flag(key, [filter], %{"aggregation_group_type_index" => 0})
      end

      definitions =
        snapshot([
          legacy.("legacy-exact", "exact", "enterprise"),
          legacy.("legacy-unset", "is_not_set", nil)
        ])

      context = %{
        groups: %{"organization" => "acme"},
        group_properties: %{"organization" => %{"tier" => "enterprise"}},
        group_property_keys_known_absent: %{"organization" => ["tier"]}
      }

      assert local(definitions, context, "legacy-exact") == {:ok, false}
      assert local(definitions, context, "legacy-unset") == {:ok, true}
    end

    test "an unusable group key counts as no group key" do
      definitions =
        snapshot([
          flag("org", [], %{"aggregation_group_type_index" => 0}),
          flag("org-tier", [group_filter("tier", "exact", "pro")], %{
            "aggregation_group_type_index" => 0
          }),
          %{
            flag("mixed", [])
            | "filters" => %{
                "groups" => [
                  %{
                    "properties" => [],
                    "rollout_percentage" => 100,
                    "aggregation_group_type_index" => 0
                  },
                  %{"properties" => [person_filter("exact", "pro")], "rollout_percentage" => 100}
                ]
              }
          },
          flag("person-child", [flag_dependency("org")])
        ])

      for group_key <- @unusable_group_keys do
        context = %{
          groups: %{organization: group_key},
          group_properties: %{organization: %{"tier" => "pro"}}
        }

        assert local(definitions, context, "org") == {:ok, false}, inspect(group_key)
        assert local(definitions, context, "org-tier") == {:ok, false}, inspect(group_key)
        assert local(definitions, context, "person-child") == {:ok, false}, inspect(group_key)

        # The group condition is skipped, so the person condition decides.
        assert local(definitions, context, "mixed") == {:unresolved, :missing_context},
               inspect(group_key)

        for {plan, expected} <- [{"pro", true}, {"free", false}] do
          context = Map.put(context, :person_properties, %{"plan" => plan})
          assert local(definitions, context, "mixed") == {:ok, expected}, inspect(group_key)
        end
      end
    end

    test "a person condition in a group flag runs without the group key" do
      group_condition = %{"properties" => [], "rollout_percentage" => 100}

      person_condition = %{
        "properties" => [person_filter("exact", "pro")],
        "rollout_percentage" => 100,
        "aggregation_group_type_index" => nil
      }

      group_flag = fn key, conditions ->
        %{
          flag(key, [])
          | "filters" => %{"aggregation_group_type_index" => 0, "groups" => conditions}
        }
      end

      definitions =
        snapshot([
          group_flag.("org-person", [person_condition]),
          group_flag.("org-mixed", [group_condition, person_condition]),
          flag("person-child", [flag_dependency("org-person")])
        ])

      for groups <- [%{}, %{organization: ""}],
          {plan, expected} <- [{"pro", true}, {"free", false}] do
        context = %{groups: groups, person_properties: %{"plan" => plan}}

        for key <- ["org-person", "org-mixed", "person-child"] do
          assert local(definitions, context, key) == {:ok, expected}, inspect({key, groups, plan})
        end
      end
    end

    test "a group flag with a holdout and no usable group key is inconclusive" do
      holdout_flag = fn key, percentage ->
        flag(key, [], %{
          "aggregation_group_type_index" => 0,
          "holdout" => %{"id" => 7, "exclusion_percentage" => percentage}
        })
      end

      definitions =
        snapshot([
          holdout_flag.("org-holdout", 50),
          holdout_flag.("org-no-holdout", 0),
          flag("person-child", [flag_dependency("org-holdout")])
        ])

      for groups <- [%{}, %{organization: ""}] do
        context = %{groups: groups}
        assert local(definitions, context, "org-holdout") == {:unresolved, :missing_context}
        assert local(definitions, context, "org-no-holdout") == {:ok, false}

        assert local(definitions, context, "person-child") ==
                 {:unresolved, :unresolved_dependency}
      end

      context = %{groups: %{organization: "acme"}}
      assert local(definitions, context, "org-holdout") == {:ok, true}
      assert local(definitions, context, "org-no-holdout") == {:ok, true}
    end

    test "a usable string or number group key still evaluates and buckets" do
      rollout =
        flag("org-rollout", [], %{"aggregation_group_type_index" => 0})
        |> put_in(["filters", "groups", Access.at(0), "rollout_percentage"], 50)

      definitions =
        snapshot([
          rollout,
          flag("org-tier", [group_filter("tier", "exact", "pro")], %{
            "aggregation_group_type_index" => 0
          })
        ])

      for {group_key, bucketing} <- [
            {"acme", "acme"},
            {"a", "a"},
            {:acme, "acme"},
            {42, "42"},
            {1.5, "1.5"}
          ] do
        context = %{groups: %{organization: group_key}}
        in_rollout = LocalEvaluator.hash("org-rollout", bucketing) < 0.5

        assert local(definitions, context, "org-rollout") == {:ok, in_rollout}
        assert local(definitions, context, "org-tier") == {:unresolved, :missing_context}

        context = Map.put(context, :group_properties, %{organization: %{"tier" => "pro"}})
        assert local(definitions, context, "org-tier") == {:ok, true}
      end

      assert LocalEvaluator.hash("org-rollout", "a") < 0.5
      refute LocalEvaluator.hash("org-rollout", "acme") < 0.5
    end

    test "flag dependencies evaluate with the same listing" do
      base = flag("base", [person_filter("is_not_set")])

      dependent =
        flag("dependent", [
          %{
            "type" => "flag",
            "key" => "base",
            "operator" => "flag_evaluates_to",
            "value" => true,
            "dependency_chain" => ["base"]
          }
        ])

      definitions = snapshot([base, dependent])

      assert local(definitions, %{}, "dependent") == {:unresolved, :unresolved_dependency}

      assert local(definitions, %{person_property_keys_known_absent: ["plan"]}, "dependent") ==
               {:ok, true}
    end
  end

  describe "public API" do
    defp envelope(flags) do
      %{"flags" => flags, "group_type_mapping" => %{"0" => "organization"}, "cohorts" => %{}}
    end

    defp start_instance(name, flags) do
      expect(PostHog.API.Mock, :request, fn :stub_client, :get, "/flags/definitions", _opts ->
        {:ok, %{status: 200, body: envelope(flags), headers: %{}}}
      end)

      config =
        PostHog.Config.validate!(
          api_key: "token",
          secret_key: "secret",
          api_client_module: PostHog.API.Mock,
          supervisor_name: name,
          test_mode: true,
          feature_flags_poll_interval_ms: 60_000
        )
        |> Map.put(:sender_pool_size, 1)

      start_supervised!({PostHog.Supervisor, config})
    end

    defp null_value_filters(operator) do
      omitted = person_filter(operator)
      [{"omitted", omitted}, {"null", Map.put(omitted, "value", nil)}]
    end

    defp expect_flags_request(owner) do
      expect(PostHog.API.Mock, :request, fn :stub_client, :post, "/flags", opts ->
        send(owner, {:flags_body, opts[:json]})
        {:ok, %{status: 200, body: %{"flags" => %{"other" => %{"enabled" => true}}}}}
      end)
    end

    test "resolves a listed key locally without a /flags request" do
      name = __MODULE__.Local
      start_instance(name, [flag("incomplete", [person_filter("is_not_set")])])
      body = %{distinct_id: "user", person_property_keys_known_absent: ["plan"]}

      assert {:ok, snapshot} = FeatureFlags.evaluate_flags(name, body)
      assert snapshot.flags["incomplete"].enabled
      assert snapshot.flags["incomplete"].locally_evaluated

      assert {:ok, %{enabled: true}} =
               FeatureFlags.get_feature_flag_result(name, "incomplete", body, send_event: false)

      assert {:ok, true} = FeatureFlags.check(name, "incomplete", body)
    end

    test "remote fallback sends the listed keys" do
      name = __MODULE__.Fallback
      unsupported = %{"key" => "x", "operator" => "future_operator", "value" => 1}
      start_instance(name, [flag("other", [unsupported])])

      body = %{
        distinct_id: "user",
        groups: %{organization: "acme"},
        person_property_keys_known_absent: [:plan, "region"],
        group_property_keys_known_absent: %{organization: ["tier"], project: []}
      }

      expect_flags_request(self())
      assert {:ok, snapshot} = FeatureFlags.evaluate_flags(name, body)
      assert snapshot.flags["other"].enabled
      assert_received {:flags_body, sent}
      assert sent.person_property_keys_known_absent == ["plan", "region"]
      assert sent.group_property_keys_known_absent == %{"organization" => ["tier"]}

      expect_flags_request(self())

      assert {:ok, %{enabled: true}} =
               FeatureFlags.get_feature_flag_result(name, "other", body, send_event: false)

      assert_received {:flags_body, sent}
      assert sent.person_property_keys_known_absent == ["plan", "region"]
      assert sent.group_property_keys_known_absent == %{"organization" => ["tier"]}
    end

    test "an unsupported operator on a listed key falls back to /flags" do
      name = __MODULE__.UnsupportedFallback
      start_instance(name, [flag("other", [person_filter("icontains_multi", ["pro"])])])

      expect_flags_request(self())

      assert {:ok, snapshot} =
               FeatureFlags.evaluate_flags(name, %{
                 distinct_id: "user",
                 person_property_keys_known_absent: ["plan"]
               })

      refute snapshot.flags["other"].locally_evaluated
      assert_received {:flags_body, %{person_property_keys_known_absent: ["plan"]}}
    end

    test "a listed key resolves without reading a present condition value or a /flags request" do
      name = __MODULE__.UnreadConditionValue

      flags =
        for {{operator, value, _expected}, index} <- Enum.with_index(@unread_condition_values) do
          flag("f#{index}", [person_filter(operator, value)])
        end

      start_instance(name, flags)
      body = %{distinct_id: "user", person_property_keys_known_absent: ["plan"]}

      for {{operator, value, expected}, index} <- Enum.with_index(@unread_condition_values) do
        assert {:ok, %{enabled: ^expected, locally_evaluated: true}} =
                 FeatureFlags.get_feature_flag_result(name, "f#{index}", body, send_event: false),
               inspect({operator, value})
      end

      assert {:ok, snapshot} =
               FeatureFlags.evaluate_flags(name, Map.put(body, :only_evaluate_locally, true))

      for {{_operator, _value, expected}, index} <- Enum.with_index(@unread_condition_values) do
        assert snapshot.flags["f#{index}"].enabled == expected
      end
    end

    test "an omitted or null condition value on a listed key falls back to /flags" do
      name = __MODULE__.NullValueFallback
      omitted = %{"key" => "plan", "type" => "person", "operator" => "is_not"}
      null = Map.put(omitted, "value", nil)
      start_instance(name, [flag("omitted", [omitted]), flag("null", [null])])
      body = %{distinct_id: "user", person_property_keys_known_absent: ["plan"]}
      owner = self()

      for key <- ["omitted", "null"] do
        expect(PostHog.API.Mock, :request, fn :stub_client, :post, "/flags", opts ->
          send(owner, {:flags_body, opts[:json]})
          {:ok, %{status: 200, body: %{"flags" => %{key => %{"enabled" => false}}}}}
        end)

        assert {:ok, %{enabled: false}} =
                 FeatureFlags.get_feature_flag_result(name, key, body, send_event: false)

        assert_received {:flags_body, %{person_property_keys_known_absent: ["plan"]}}, key
      end
    end

    test "an omitted or null condition value on a listed and supplied key falls back to /flags" do
      name = __MODULE__.NullValueSuppliedFallback

      flags =
        for operator <- @value_operators, {suffix, filter} <- null_value_filters(operator) do
          flag("#{operator}-#{suffix}", [filter])
        end

      start_instance(name, flags)

      body = %{
        distinct_id: "user",
        person_properties: %{"plan" => "pro"},
        person_property_keys_known_absent: ["plan"]
      }

      owner = self()

      for %{"key" => key} <- flags do
        expect(PostHog.API.Mock, :request, fn :stub_client, :post, "/flags", opts ->
          send(owner, {:flags_body, opts[:json]})
          {:ok, %{status: 200, body: %{"flags" => %{key => %{"enabled" => false}}}}}
        end)

        assert {:ok, %{enabled: false, locally_evaluated: false}} =
                 FeatureFlags.get_feature_flag_result(name, key, body, send_event: false),
               key

        assert_received {:flags_body, %{person_property_keys_known_absent: ["plan"]}}, key
      end
    end

    test "remote requests omit the fields when nothing is listed" do
      name = __MODULE__.Omitted
      unsupported = %{"key" => "x", "operator" => "future_operator", "value" => 1}
      start_instance(name, [flag("other", [unsupported])])

      for body <- [
            %{distinct_id: "user"},
            %{
              distinct_id: "user",
              person_property_keys_known_absent: [],
              group_property_keys_known_absent: %{organization: []}
            },
            %{
              distinct_id: "user",
              person_property_keys_known_absent: nil,
              group_property_keys_known_absent: nil
            }
          ] do
        expect_flags_request(self())
        assert {:ok, _snapshot} = FeatureFlags.evaluate_flags(name, body)
        assert_received {:flags_body, sent}
        refute Map.has_key?(sent, :person_property_keys_known_absent)
        refute Map.has_key?(sent, :group_property_keys_known_absent)
      end
    end

    test "an unusable group key resolves false without a /flags request or a crash" do
      name = __MODULE__.UnusableGroupKey

      start_instance(name, [
        flag("org", [], %{"aggregation_group_type_index" => 0}),
        flag("person-child", [flag_dependency("org")])
      ])

      owner = self()

      stub(PostHog.API.Mock, :request, fn :stub_client, :post, "/flags", opts ->
        send(owner, {:flags_body, opts[:json]})
        {:ok, %{status: 200, body: %{"flags" => %{}}}}
      end)

      for group_key <- @unusable_group_keys, only_local <- [true, false] do
        body = %{
          distinct_id: "user",
          groups: %{organization: group_key},
          only_evaluate_locally: only_local
        }

        assert {:ok, snapshot} = FeatureFlags.evaluate_flags(name, body), inspect(group_key)
        refute snapshot.flags["org"].enabled
        refute snapshot.flags["person-child"].enabled
        refute PostHog.FeatureFlags.Evaluations.enabled?(snapshot, "org")

        assert {:ok, snapshot} =
                 FeatureFlags.evaluate_flags(name, Map.put(body, :flag_keys, ["org"]))

        refute snapshot.flags["org"].enabled

        for key <- ["org", "person-child"] do
          assert {:ok, %{enabled: false}} =
                   FeatureFlags.get_feature_flag_result(name, key, body)

          assert {:ok, false} = FeatureFlags.check(name, key, body)
        end

        FeatureFlags.set_in_context(name, snapshot)
        PostHog.capture(name, "page_viewed", %{distinct_id: "user"})

        refute_received {:flags_body, _sent}
      end

      events = PostHog.Test.all_captured(name)

      assert Enum.any?(
               events,
               &(&1.event == "page_viewed" and &1.properties["$feature/org"] == false)
             )

      called = for %{event: "$feature_flag_called", properties: props} <- events, do: props
      assert called != []
      assert Enum.all?(called, &(&1[:"$feature_flag_response"] == false))
    end

    test "a person condition in a group flag decides without the group key or a /flags request" do
      name = __MODULE__.GroupFlagPersonCondition

      person_flag =
        %{
          flag("org-person", [])
          | "filters" => %{
              "aggregation_group_type_index" => 0,
              "groups" => [
                %{"properties" => [], "rollout_percentage" => 100},
                %{
                  "properties" => [person_filter("exact", "pro")],
                  "rollout_percentage" => 100,
                  "aggregation_group_type_index" => nil
                }
              ]
            }
        }

      start_instance(name, [person_flag, flag("person-child", [flag_dependency("org-person")])])
      owner = self()

      stub(PostHog.API.Mock, :request, fn :stub_client, :post, "/flags", opts ->
        send(owner, {:flags_body, opts[:json]})
        {:ok, %{status: 200, body: %{"flags" => %{}}}}
      end)

      for groups <- [%{}, %{organization: ""}],
          {plan, expected} <- [{"pro", true}, {"free", false}] do
        body = %{distinct_id: "user", groups: groups, person_properties: %{"plan" => plan}}

        assert {:ok, snapshot} = FeatureFlags.evaluate_flags(name, body)
        assert snapshot.flags["org-person"].enabled == expected
        assert snapshot.flags["person-child"].enabled == expected

        for key <- ["org-person", "person-child"] do
          assert {:ok, %{enabled: ^expected}} =
                   FeatureFlags.get_feature_flag_result(name, key, body, send_event: false)
        end

        refute_received {:flags_body, _sent}
      end
    end

    test "a group flag with a holdout and no usable group key falls back to /flags" do
      name = __MODULE__.GroupHoldout

      holdout_flag =
        flag("org-holdout", [], %{
          "aggregation_group_type_index" => 0,
          "holdout" => %{"id" => 7, "exclusion_percentage" => 50}
        })

      start_instance(name, [holdout_flag])
      owner = self()

      stub(PostHog.API.Mock, :request, fn :stub_client, :post, "/flags", opts ->
        send(owner, {:flags_body, opts[:json]})

        {:ok,
         %{
           status: 200,
           body: %{"flags" => %{"org-holdout" => %{"enabled" => true, "variant" => "holdout-7"}}}
         }}
      end)

      body = %{distinct_id: "user", groups: %{organization: ""}}

      assert {:ok, %{enabled: true, variant: "holdout-7"}} =
               FeatureFlags.get_feature_flag_result(name, "org-holdout", body, send_event: false)

      assert_received {:flags_body, _sent}

      assert {:ok, snapshot} =
               FeatureFlags.evaluate_flags(name, Map.put(body, :only_evaluate_locally, true))

      refute Map.has_key?(snapshot.flags, "org-holdout")
      refute_received {:flags_body, _sent}
    end

    test "context bodies carry the listed keys" do
      name = __MODULE__.Context
      start_instance(name, [flag("incomplete", [person_filter("is_not_set")])])

      PostHog.set_context(name, %{
        distinct_id: "user",
        person_property_keys_known_absent: ["plan"]
      })

      assert {:ok, snapshot} = FeatureFlags.evaluate_flags(name, nil)
      assert snapshot.flags["incomplete"].enabled
    end

    test "lists over 1000 keys fail locally without a request" do
      name = __MODULE__.Limit
      start_instance(name, [flag("incomplete", [person_filter("is_not_set")])])
      keys = for index <- 1..1000, do: "key-#{index}"

      # Duplicates count toward the limit.
      over_limit = [
        %{person_property_keys_known_absent: ["plan" | keys]},
        %{person_property_keys_known_absent: List.duplicate("plan", 1001)},
        %{group_property_keys_known_absent: %{organization: ["tier" | keys]}}
      ]

      for extra <- over_limit do
        body = Map.put(extra, :distinct_id, "user")

        assert {:error, %PostHog.Error{message: message}} =
                 FeatureFlags.evaluate_flags(name, body)

        assert message =~ "known_absent"
        assert message =~ "1000"

        assert {:error, %PostHog.Error{}} =
                 FeatureFlags.get_feature_flag_result(name, "incomplete", body, send_event: false)

        assert {:error, %PostHog.Error{}} = FeatureFlags.check(name, "incomplete", body)
        assert {:error, %PostHog.Error{}} = FeatureFlags.flags(name, body)
        assert {:error, %PostHog.Error{}} = FeatureFlags.flags_for(name, body)
      end

      # The limit applies to each group type separately.
      at_limit = %{
        distinct_id: "user",
        person_property_keys_known_absent: ["plan" | Enum.drop(keys, 1)],
        group_property_keys_known_absent: %{organization: keys, project: keys}
      }

      assert {:ok, snapshot} = FeatureFlags.evaluate_flags(name, at_limit)
      assert snapshot.flags["incomplete"].enabled
    end

    test "values of the wrong type fail locally without a request" do
      name = __MODULE__.InvalidType
      start_instance(name, [flag("incomplete", [person_filter("is_not_set")])])

      for extra <- [
            %{person_property_keys_known_absent: "plan"},
            %{person_property_keys_known_absent: [1]},
            %{person_property_keys_known_absent: [true]},
            %{person_property_keys_known_absent: [false]},
            %{group_property_keys_known_absent: %{organization: [true]}},
            %{group_property_keys_known_absent: %{true => ["tier"]}},
            %{group_property_keys_known_absent: %{false => ["tier"]}},
            %{group_property_keys_known_absent: ["tier"]},
            %{group_property_keys_known_absent: %{organization: "tier"}},
            %{person_property_keys_known_absent: ["plan" | :improper]},
            %{group_property_keys_known_absent: %{organization: ["tier" | :improper]}},
            %{group_property_keys_known_absent: %{{:organization} => ["tier"]}},
            %{person_property_keys_known_absent: [<<255>>]},
            %{group_property_keys_known_absent: %{<<255>> => ["tier"]}},
            %{group_property_keys_known_absent: %{"organization" => [], organization: ["x"]}},
            %{group_property_keys_known_absent: %{"organization" => ["x"], organization: []}},
            %{
              group_property_keys_known_absent: %{"organization" => ["tier"], organization: ["x"]}
            }
          ] do
        body = Map.put(extra, :distinct_id, "user")
        assert {:error, %PostHog.Error{}} = FeatureFlags.evaluate_flags(name, body)
        assert {:error, %PostHog.Error{}} = FeatureFlags.flags(name, body)
      end
    end

    test "raw /flags bodies validate and send string-keyed fields once" do
      name = __MODULE__.StringKeys
      start_instance(name, [])
      keys = for index <- 1..1001, do: "key-#{index}"

      assert {:error, %PostHog.Error{}} =
               FeatureFlags.flags(name, %{
                 "distinct_id" => "user",
                 "person_property_keys_known_absent" => keys
               })

      expect_flags_request(self())

      assert {:ok, _response} =
               FeatureFlags.flags(name, %{
                 "distinct_id" => "user",
                 "person_property_keys_known_absent" => ["region"],
                 "group_property_keys_known_absent" => %{"organization" => ["tier"]}
               })

      assert_received {:flags_body, sent}
      assert sent.person_property_keys_known_absent == ["region"]
      assert sent.group_property_keys_known_absent == %{"organization" => ["tier"]}
      refute Map.has_key?(sent, "person_property_keys_known_absent")
      refute Map.has_key?(sent, "group_property_keys_known_absent")
    end
  end
end
