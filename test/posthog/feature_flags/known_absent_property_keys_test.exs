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

  defp person_filter(operator, value \\ nil) do
    filter = %{"key" => "plan", "type" => "person", "operator" => operator}
    if is_nil(value), do: filter, else: Map.put(filter, "value", value)
  end

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

    test "malformed condition values on a listed key keep their existing result" do
      context = %{person_property_keys_known_absent: ["plan"]}

      for {operator, value} <- [
            {"gt", "not-a-number"},
            {"is_date_before", "not-a-date"},
            {"semver_eq", "not-a-version"},
            {"not_regex", "(?<=a)b"}
          ] do
        definitions = snapshot([flag("f", [person_filter(operator, value)])])

        assert local(definitions, context, "f") == {:unresolved, :unsupported_definition},
               operator
      end

      # An invalid regex is a definitive non-match locally, as for a present value.
      definitions = snapshot([flag("f", [person_filter("not_regex", "[")])])
      assert local(definitions, context, "f") == {:ok, false}
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
