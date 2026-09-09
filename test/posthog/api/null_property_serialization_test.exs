defmodule PostHog.API.NullPropertySerializationTest do
  use ExUnit.Case, async: true

  alias PostHog.API
  alias PostHog.FeatureFlags.Evaluations

  defp properties do
    %{
      test: nil,
      nested: %{drop: nil},
      items: ["1", nil, 2, %{drop: nil}, [nil]],
      empty: "",
      zero: 0,
      enabled: false,
      literal: "null",
      literalUndefined: "undefined",
      emptyArray: [],
      emptyObject: %{},
      "$set": %{drop: nil},
      "$group_set": %{drop: nil},
      "$ai_input": [%{content: nil}]
    }
  end

  defp expected do
    %{
      "nested" => %{},
      "items" => ["1", nil, 2, %{}, [nil]],
      "empty" => "",
      "zero" => 0,
      "enabled" => false,
      "literal" => "null",
      "literalUndefined" => "undefined",
      "emptyArray" => [],
      "emptyObject" => %{},
      "$set" => %{},
      "$group_set" => %{},
      "$ai_input" => [%{}]
    }
  end

  defmodule Adapter do
    @moduledoc false

    def run(req) do
      body = IO.iodata_to_binary(req.body)

      body =
        if Req.Request.get_header(req, "content-encoding") == ["gzip"],
          do: :zlib.gunzip(body),
          else: body

      message =
        if Req.Request.get_private(req, :raw_wire),
          do: {:raw_wire, body},
          else: {:wire, Jason.decode!(body)}

      send(Req.Request.get_private(req, :test_owner), message)
      {req, Req.Response.new(status: 200, body: %{})}
    end
  end

  defp client(parent, compressed, raw_wire \\ false) do
    default = API.Client.client("fake-key", "http://127.0.0.1:1")

    req =
      default.client
      |> Req.merge(compress_body: compressed, adapter: Adapter)
      |> Req.Request.put_private(:test_owner, parent)
      |> Req.Request.put_private(:raw_wire, raw_wire)

    %{default | client: req}
  end

  for compressed <- [false, true] do
    test "batch normalizes real JSON bytes (gzip=#{compressed})" do
      properties = properties()
      client = client(self(), unquote(compressed))
      event = %{event: "capture", timestamp: nil, properties: properties}
      assert {:ok, _} = API.batch(client, [event])
      assert_receive {:wire, %{"batch" => [wire], "api_key" => "fake-key"}}
      assert wire["properties"] == expected()
      assert Map.has_key?(wire, "timestamp")
      assert wire["timestamp"] == nil
      assert properties.test == nil

      assert {:ok, _} = API.batch(client, [%{event: "only-null", properties: %{test: nil}}])
      assert_receive {:wire, %{"batch" => [%{"properties" => %{}}]}}
    end
  end

  test "post-hook JSON structs/fragments use their encoders; exception metadata stays typed" do
    client = client(self(), false)

    properties = %{
      "date" => ~D[2026-01-02],
      "struct" => %PostHog.Test.NullableJSONValue{value: %{drop: nil}, private: "not serialized"},
      "null_struct" => %PostHog.Test.NullableJSONValue{value: nil},
      "list_struct" => %PostHog.Test.NullableJSONValue{value: [nil, %{drop: nil}]},
      "fragment" => Jason.Fragment.new(~s({"drop":null,"items":[null,{"drop":null}]})),
      "null_fragment" => Jason.Fragment.new("null"),
      "$exception_list" => [%{stacktrace: %{frames: [%{lineno: nil}]}}],
      "custom" => %{drop: nil}
    }

    assert {:ok, _} = API.batch(client, [%{event: "$exception", properties: properties}])
    assert_receive {:wire, %{"batch" => [%{"properties" => wire}]}}
    assert wire["date"] == "2026-01-02"
    assert wire["struct"] == %{}
    refute Map.has_key?(wire, "null_struct")
    assert wire["list_struct"] == [nil, %{}]
    assert wire["fragment"] == %{"items" => [nil, %{}]}
    refute Map.has_key?(wire, "null_fragment")
    assert wire["custom"] == %{}
    assert wire["$exception_list"] == [%{"stacktrace" => %{"frames" => [%{"lineno" => nil}]}}]

    assert {:ok, _} = API.batch(client, [%{event: "custom", properties: properties}])
    assert_receive {:wire, %{"batch" => [%{"properties" => wire}]}}
    assert wire["$exception_list"] == [%{"stacktrace" => %{"frames" => [%{}]}}]
  end

  def request(parent, _method, path, opts) do
    send(parent, {:dispatch, path, opts[:json]})
    {:ok, %{status: 200}}
  end

  test "custom clients receive cleaned events, not cleaned flags or envelope containers" do
    client = %API.Client{client: self(), module: __MODULE__}
    event = %{"event" => "custom", "properties" => %{"drop" => nil, "items" => [nil]}}
    assert {:ok, _} = API.batch(client, [event, %{properties: nil}, %{event: "no-properties"}])

    assert_receive {:dispatch, "/batch",
                    %{batch: [wire, %{properties: nil}, %{event: "no-properties"}]}}

    assert wire["properties"] == %{"items" => [nil]}
    assert {:ok, _} = API.flags(client, %{person_properties: %{keep: nil}})
    assert_receive {:dispatch, "/flags", %{person_properties: %{keep: nil}}}
  end

  for trigger <- [:count, :timer, :shutdown] do
    @tag trigger: trigger
    test "capture/AI/Handler after enrichment and hook, #{trigger} delivery", context do
      parent = self()
      name = context.test

      config =
        PostHog.Config.validate!(
          api_key: "fake-key",
          api_host: "http://127.0.0.1:1",
          supervisor_name: name,
          test_mode: false,
          capture_level: :error,
          metadata: :all,
          enable_source_code_context: false,
          global_properties: %{globalNull: nil},
          before_send: fn
            %{event: "drop"} ->
              nil

            event ->
              update_in(event.properties, fn properties ->
                Map.merge(properties, %{
                  hookNull: nil,
                  hookItems: [nil, %{drop: nil}],
                  hookFragment: Jason.Fragment.new(~s({"drop":null})),
                  hookStruct: %PostHog.Test.NullableJSONValue{value: %{drop: nil}}
                })
              end)
          end
        )
        |> Map.merge(%{
          api_client: client(parent, true),
          sender_pool_size: 1,
          max_batch_events: if(context.trigger == :count, do: 4, else: 100),
          max_batch_time_ms: if(context.trigger == :timer, do: 20, else: 60_000)
        })

      start_supervised!({PostHog.Supervisor, config})
      PostHog.set_context(name, %{distinct_id: "user", contextNull: nil})
      assert :ok = PostHog.capture(name, "capture", properties())
      assert :ok = PostHog.bare_capture(name, "only-null", "user", %{test: nil})
      assert {:ok, _} = PostHog.LLMAnalytics.capture_span(name, "$ai_generation", properties())

      assert :ok =
               PostHog.Handler.log(
                 %{level: :error, msg: {:string, "test"}, meta: properties()},
                 %{config: config}
               )

      assert :ok = PostHog.capture(name, "drop", %{})

      if context.trigger == :shutdown do
        [{pid, _}] = Registry.lookup(PostHog.Registry.registry_name(name), {PostHog.Sender, 1})
        :sys.get_state(pid)
        GenServer.stop(pid)
      end

      events = receive_events(4, [])

      assert Enum.sort(Enum.map(events, & &1["event"])) == [
               "$ai_generation",
               "$exception",
               "capture",
               "only-null"
             ]

      for event <- events do
        props = event["properties"]

        for key <- ["test", "contextNull", "globalNull", "hookNull"],
            do: refute(Map.has_key?(props, key))

        assert props["hookItems"] == [nil, %{}]
        assert props["hookFragment"] == %{}
        assert props["hookStruct"] == %{}

        if event["event"] != "only-null",
          do: assert(Map.take(props, Map.keys(expected())) == expected())

        if event["event"] == "$exception", do: assert(is_list(props["$exception_list"]))
      end

      refute_receive {:wire, _}, 50
    end
  end

  for compressed <- [false, true] do
    @tag compressed: compressed
    test "generated missing/error flag events retain only typed nulls (gzip=#{compressed})",
         context do
      name = context.test

      config =
        PostHog.Config.validate!(
          api_key: "fake-key",
          supervisor_name: name,
          test_mode: false,
          global_properties: %{custom: %{drop: nil}, "$feature/unrelated": nil}
        )
        |> Map.merge(%{
          api_client: client(self(), context.compressed),
          sender_pool_size: 1,
          max_batch_events: 1,
          max_batch_time_ms: 60_000
        })

      start_supervised!({PostHog.Supervisor, config})

      snapshot =
        Evaluations.new(name, "user", %{
          "flags" => %{},
          "errorsWhileComputingFlags" => true
        })

      assert Evaluations.get_flag(snapshot, "missing") == nil
      assert_receive {:wire, %{"batch" => [%{"properties" => props}]}}
      assert Map.fetch!(props, "$feature_flag_response") == nil
      assert Map.fetch!(props, "$feature/missing") == nil
      assert props["$feature_flag_error"] == "errors_while_computing_flags,flag_missing"
      assert props["custom"] == %{}
      refute Map.has_key?(props, "$feature/unrelated")
      Agent.stop(snapshot.accessed_pid)

      # Missing snapshots lack experiment metadata and therefore use the full path.
      # Exercise the minimal producer with its actual typed result and flag_missing error.
      result = %PostHog.FeatureFlags.Result{
        key: "minimal",
        enabled: false,
        has_experiment: false,
        minimal_flag_called_events: true,
        errors_while_computing: true
      }

      assert :ok =
               PostHog.FeatureFlags.log_feature_flag_usage(name, "user", result, ["flag_missing"])

      assert_receive {:wire, %{"batch" => [%{"properties" => props}]}}
      assert Map.fetch!(props, "$feature_flag_response") == nil
      refute Map.has_key?(props, "$feature/minimal")
      refute Map.has_key?(props, "custom")
      refute Map.has_key?(props, "$feature/unrelated")

      for event <- ["ordinary", "$feature_flag_called"] do
        properties = %{
          "$feature_flag" => "exact",
          "$feature_flag_response" => nil,
          "$feature/exact" => nil,
          "$feature/other" => nil,
          "custom" => nil
        }

        assert {:ok, _} =
                 API.batch(client(self(), context.compressed), [
                   %{"event" => event, "properties" => properties}
                 ])

        assert_receive {:wire, %{"batch" => [%{"properties" => props}]}}
        assert Map.has_key?(props, "$feature_flag_response") == (event == "$feature_flag_called")
        assert Map.has_key?(props, "$feature/exact") == (event == "$feature_flag_called")
        refute Map.has_key?(props, "$feature/other")
        refute Map.has_key?(props, "custom")
      end
    end

    @tag compressed: compressed
    test "hook encoder duplicate members survive Sender and Req (gzip=#{compressed})", context do
      json = ~s({"x":1,"x":null,"x":2,"drop":null,"items":[null,{"drop":null}]})
      expected = ~s({"x":1,"x":2,"items":[null,{}]})

      ordered =
        Jason.OrderedObject.new([
          {"x", 1},
          {"x", nil},
          {"x", 2},
          {"drop", nil},
          {"items", [nil, %{drop: nil}]}
        ])

      assert_hook_wire(
        context,
        [
          Jason.Fragment.new(json),
          ordered,
          %PostHog.Test.NullableJSONValue{value: Jason.Fragment.new(json)}
        ],
        expected
      )
    end

    @tag compressed: compressed
    test "hook encoder precise numeric tokens survive Sender and Req (gzip=#{compressed})",
         context do
      json =
        ~s({"n":1.234567890123456789123456789,"large":1e400,"zero":-0,"exp":-0.0e+10,"drop":null})

      expected = ~s({"n":1.234567890123456789123456789,"large":1e400,"zero":-0,"exp":-0.0e+10})

      assert_hook_wire(
        context,
        [
          Jason.Fragment.new(json),
          %PostHog.Test.NullableJSONValue{value: Jason.Fragment.new(json)}
        ],
        expected
      )
    end
  end

  defp assert_hook_wire(context, values, expected) do
    name = context.test

    config =
      PostHog.Config.validate!(
        api_key: "fake-key",
        supervisor_name: name,
        test_mode: false,
        before_send: fn event -> put_in(event.properties[:hook], values) end
      )
      |> Map.merge(%{
        api_client: client(self(), context.compressed, true),
        sender_pool_size: 1,
        max_batch_events: 1,
        max_batch_time_ms: 60_000
      })

    start_supervised!({PostHog.Supervisor, config})
    assert :ok = PostHog.capture(name, "encoded", %{distinct_id: "user"})
    assert_receive {:raw_wire, body}
    assert body =~ ~s("hook":[#{Enum.map_join(values, ",", fn _ -> expected end)}])
  end

  test "encoder long strings and native numeric values retain baseline bytes" do
    for value <- [String.duplicate(~S(a\"\\), 30_000), -0.0, 1.25, 123_456_789_123_456_789] do
      event = %{
        event: "control",
        properties: %{value: %PostHog.Test.NullableJSONValue{value: value}}
      }

      assert Jason.encode!(PostHog.EventProperties.normalize(event)) == Jason.encode!(event)
    end

    properties =
      Jason.Fragment.new(~S({"\u0073key":"\u006e1e400","\u0000key":"\u0000value","drop":null}))

    event = PostHog.EventProperties.normalize(%{properties: properties})

    assert Jason.decode!(Jason.encode!(event)) == %{
             "properties" => %{"skey" => "n1e400", "\u0000key" => "\u0000value"}
           }
  end

  test "fractional tokens are not rounded on wire" do
    json = ~s({"n":1.234567890123456789123456789,"drop":null})

    assert {:ok, _} =
             API.batch(client(self(), false, true), [
               %{event: "precision", properties: %{value: Jason.Fragment.new(json)}}
             ])

    assert_receive {:raw_wire, body}
    assert body =~ ~s("value":{"n":1.234567890123456789123456789})
  end

  test "encoded strings, duplicate tag-looking keys and malformed tokens" do
    json =
      ~S({"skey":"n1e400","skey":"svalue","escaped\"\\雪":"1.23","items":["-0",null,{"drop":null}]})

    expected = ~S({"skey":"n1e400","skey":"svalue","escaped\"\\雪":"1.23","items":["-0",null,{}]})

    assert {:ok, _} =
             API.batch(client(self(), false, true), [
               %{event: "strings", properties: Jason.Fragment.new(json)}
             ])

    assert_receive {:raw_wire, body}
    assert body =~ expected

    for invalid <- [
          "01",
          "1e",
          "1e+",
          "1.",
          "+1",
          "--1",
          "1 2",
          "1true",
          "NaN",
          "[1,]",
          ~S({"x":1 "y":2}),
          ~S({1 :2}),
          ~S({1e400:2}),
          ~S({"x":1e400x}),
          ~S("\q"),
          ~S("unterminated),
          ~S("x"1),
          "[.1]",
          "[-01]",
          "[1e-]",
          "[1e+2.3]"
        ] do
      assert_raise Jason.DecodeError, fn ->
        PostHog.EventProperties.normalize(%{properties: %{value: Jason.Fragment.new(invalid)}})
      end
    end
  end

  defp receive_events(0, events), do: events

  defp receive_events(remaining, events) do
    assert_receive {:wire, %{"batch" => batch}}
    receive_events(remaining - length(batch), batch ++ events)
  end
end
