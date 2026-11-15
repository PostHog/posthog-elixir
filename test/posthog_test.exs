defmodule PostHogTest do
  use PostHog.Case,
    async: Version.match?(System.version(), ">= 1.18.0"),
    group: PostHog

  @moduletag config: [supervisor_name: PostHog]

  import Mox

  setup :setup_supervisor
  setup :verify_on_exit!

  describe "config/0" do
    test "fetches from PostHog by default" do
      assert %{supervisor_name: PostHog} = PostHog.config()
    end

    @tag config: [supervisor_name: CustomPostHog]
    test "uses custom supervisor name" do
      assert %{supervisor_name: CustomPostHog} = PostHog.config(CustomPostHog)
    end
  end

  describe "bare_capture/4" do
    test "simple call" do
      PostHog.bare_capture("case tested", "distinct_id")

      assert [event] = all_captured()

      assert %{
               event: "case tested",
               uuid: _,
               distinct_id: "distinct_id",
               properties: %{},
               timestamp: _
             } = event
    end

    test "with properties" do
      PostHog.bare_capture("case tested", "distinct_id", %{foo: "bar"})

      assert [event] = all_captured()

      assert %{
               event: "case tested",
               uuid: _,
               distinct_id: "distinct_id",
               properties: %{foo: "bar"},
               timestamp: _
             } = event
    end

    @tag config: [
           global_properties: %{egg: "spam", struct: %LoggerHandlerKit.FakeStruct{}},
           supervisor_name: PostHog
         ]
    test "adds global properties" do
      PostHog.bare_capture("case tested", "distinct_id")

      assert [event] = all_captured()

      assert %{
               event: "case tested",
               uuid: _,
               distinct_id: "distinct_id",
               properties: %{
                 egg: "spam",
                 struct: %{hello: nil},
                 "$lib": "posthog-elixir",
                 "$lib_version": _,
                 "$is_server": true
               },
               timestamp: _
             } = event

      Jason.encode!(event)
    end

    @tag config: [is_server: false, supervisor_name: PostHog]
    test "omits $is_server when is_server is false" do
      PostHog.bare_capture("case tested", "distinct_id")

      assert [%{properties: properties}] = all_captured()

      assert %{"$lib": "posthog-elixir", "$lib_version": _} = properties
      refute Map.has_key?(properties, :"$is_server")
    end

    @tag config: [
           global_properties: %{source: "global"},
           before_send: &__MODULE__.modify_before_send/1,
           supervisor_name: PostHog
         ]
    test "before_send can modify fully enriched events" do
      PostHog.bare_capture("case tested", "distinct_id", %{secret: "remove"})

      assert [%{properties: properties}] = all_captured()
      assert properties[:before_send] == true
      assert properties[:saw_fully_enriched_event] == true
      refute Map.has_key?(properties, :secret)
    end

    @tag config: [before_send: &__MODULE__.drop_before_send/1, supervisor_name: PostHog]
    test "before_send drops events when callback returns nil" do
      assert :ok = PostHog.bare_capture("case tested", "distinct_id")

      assert [] = all_captured()
    end

    @tag config: [before_send: &__MODULE__.invalid_before_send/1, supervisor_name: PostHog]
    test "before_send sends the original event when callback returns invalid value" do
      assert :ok = PostHog.bare_capture("case tested", "distinct_id", %{original: true})

      assert [%{event: "case tested", properties: properties}] = all_captured()
      assert properties[:original] == true
      refute properties[:before_send]
    end

    for {name, callback} <- [
          {"raises", &__MODULE__.raise_before_send/1},
          {"throws", &__MODULE__.throw_before_send/1},
          {"exits", &__MODULE__.exit_before_send/1}
        ] do
      @tag config: [before_send: callback, supervisor_name: PostHog]
      test "before_send drops events when callback #{name}" do
        assert :ok = PostHog.bare_capture("case tested", "distinct_id", %{original: true})

        assert [] = all_captured()
      end
    end

    @tag config: [supervisor_name: CustomPostHog]
    test "simple call for custom supervisor" do
      PostHog.bare_capture(CustomPostHog, "case tested", "distinct_id")

      assert [event] = all_captured(CustomPostHog)

      assert %{
               event: "case tested",
               uuid: _,
               distinct_id: "distinct_id",
               properties: %{},
               timestamp: _
             } = event
    end

    @tag config: [supervisor_name: CustomPostHog]
    test "with properties for custom supervisor" do
      PostHog.bare_capture(CustomPostHog, "case tested", "distinct_id", %{foo: "bar"})

      assert [event] = all_captured(CustomPostHog)

      assert %{
               event: "case tested",
               uuid: _,
               distinct_id: "distinct_id",
               properties: %{foo: "bar"},
               timestamp: _
             } = event
    end

    test "ignores set context but uses global one from the config" do
      PostHog.set_context(%{hello: "world"})
      PostHog.bare_capture("case tested", "distinct_id", %{foo: "bar"})

      assert [%{properties: properties}] = all_captured()

      assert %{foo: "bar", "$lib": "posthog-elixir", "$lib_version": _} = properties
      assert properties[:"$is_server"] == true
      refute properties[:hello]
    end

    test "encodes properties for safe json serialization" do
      PostHog.bare_capture("case tested", "distinct_id", %{
        struct: %LoggerHandlerKit.FakeStruct{},
        ref: make_ref()
      })

      assert [event] = all_captured()

      assert %{
               event: "case tested",
               uuid: _,
               distinct_id: "distinct_id",
               properties: %{struct: %{hello: nil}, ref: _} = properties,
               timestamp: _
             } = event

      Jason.encode!(properties)
    end

    @tag config: [before_send: &__MODULE__.override_event_timestamp/1, supervisor_name: PostHog]
    test "normalizes before_send timestamp offsets to UTC without changing properties" do
      for {timestamp, expected} <- [
            {"2025-01-02T08:34:05+05:30", "2025-01-02T03:04:05Z"},
            {"2025-01-02T00:04:05.123456-03:00", "2025-01-02T03:04:05.123456Z"},
            {"2025-01-02T03:04:05.123Z", "2025-01-02T03:04:05.123Z"}
          ] do
        PostHog.bare_capture("timestamp override", "distinct_id", %{timestamp_like: timestamp})
        event = Enum.find(all_captured(), &(&1.properties.timestamp_like == timestamp))
        assert event.timestamp == expected
        assert event.properties.timestamp_like == timestamp
      end
    end

    for {name, timestamp, expected} <- [
          {"UTC", "2025-01-02T03:04:05.123456789Z", "2025-01-02T03:04:05.123456789Z"},
          {"positive offset", "2025-01-02T00:34:05.123456789+05:30",
           "2025-01-01T19:04:05.123456789Z"},
          {"negative offset", "2025-01-02T23:34:05.987654321-03:00",
           "2025-01-03T02:34:05.987654321Z"}
        ] do
      @tag config: [before_send: &__MODULE__.override_event_timestamp/1, supervisor_name: PostHog]
      test "preserves all nine fractional timestamp digits from before_send with #{name}" do
        timestamp = unquote(timestamp)
        properties = %{timestamp_like: timestamp}

        assert :ok = PostHog.bare_capture("precise timestamp", "distinct_id", properties)
        assert [event] = all_captured()
        assert event.timestamp == unquote(expected)
        assert event.properties.timestamp_like == properties.timestamp_like

        wire_event = event |> Jason.encode!() |> Jason.decode!()
        assert wire_event["timestamp"] == unquote(expected)
        assert wire_event["properties"]["timestamp_like"] == timestamp
      end
    end

    @tag config: [before_send: &__MODULE__.override_event_timestamp/1, supervisor_name: PostHog]
    test "preserves malformed and native before_send timestamp values" do
      for timestamp <- [
            "invalid",
            "2025-02-30T03:04:05.123456789+05:30",
            nil,
            ~U[2025-01-02 03:04:05.123456Z]
          ] do
        assert :ok =
                 PostHog.bare_capture("unchanged timestamp", "distinct_id", %{
                   timestamp_like: timestamp
                 })

        assert Enum.any?(all_captured(), fn event ->
                 event.timestamp == timestamp and event.properties.timestamp_like == timestamp
               end)
      end
    end

    test "generates a UTC timestamp without changing DateTime properties" do
      local_datetime = %DateTime{
        year: 2024,
        month: 1,
        day: 2,
        hour: 3,
        minute: 4,
        second: 5,
        microsecond: {678_000, 3},
        time_zone: "Asia/Kathmandu",
        zone_abbr: "+0545",
        utc_offset: 20_700,
        std_offset: 0
      }

      PostHog.bare_capture("timestamp test", "distinct_id", %{occurred_at: local_datetime})

      assert [%{timestamp: timestamp, properties: %{occurred_at: ^local_datetime}} = event] =
               all_captured()

      assert String.ends_with?(timestamp, "Z")
      assert {:ok, _datetime, 0} = DateTime.from_iso8601(timestamp)

      wire_event = event |> Jason.encode!() |> Jason.decode!()
      assert wire_event["timestamp"] == timestamp
      assert wire_event["properties"]["occurred_at"] == "2024-01-02T03:04:05.678+05:45"
    end

    test "uuid is valid v7" do
      PostHog.bare_capture("uuid test", "distinct_id")

      assert [event] = all_captured()

      assert is_binary(event.uuid)

      assert Regex.match?(
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i,
               event.uuid
             )
    end
  end

  describe "capture/4" do
    test "simple call" do
      PostHog.capture("case tested", %{distinct_id: "distinct_id"})

      assert [event] = all_captured()

      assert %{
               event: "case tested",
               uuid: _,
               distinct_id: "distinct_id",
               properties: %{},
               timestamp: _
             } = event
    end

    test "distinct_id is required" do
      assert {:error, :missing_distinct_id} = PostHog.capture("case tested")
    end

    test "with properties" do
      PostHog.capture("case tested", %{distinct_id: "distinct_id", foo: "bar"})

      assert [event] = all_captured()

      assert %{
               event: "case tested",
               uuid: _,
               distinct_id: "distinct_id",
               properties: %{foo: "bar"},
               timestamp: _
             } = event
    end

    @tag config: [supervisor_name: CustomPostHog]
    test "simple call for custom supervisor" do
      PostHog.capture(CustomPostHog, "case tested", %{distinct_id: "distinct_id"})

      assert [event] = all_captured(CustomPostHog)

      assert %{
               event: "case tested",
               distinct_id: "distinct_id",
               properties: %{},
               timestamp: _
             } = event
    end

    @tag config: [supervisor_name: CustomPostHog]
    test "with properties for custom supervisor" do
      PostHog.capture(CustomPostHog, "case tested", %{distinct_id: "distinct_id", foo: "bar"})

      assert [event] = all_captured(CustomPostHog)

      assert %{
               event: "case tested",
               distinct_id: "distinct_id",
               properties: %{foo: "bar"},
               timestamp: _
             } = event
    end

    test "includes relevant event context" do
      PostHog.set_context(%{hello: "world", distinct_id: "distinct_id", final: "global"})
      PostHog.set_event_context("case tested", %{foo: "bar", final: "event"})
      PostHog.set_context(MyPostHog, %{spam: "eggs"})
      PostHog.capture("case tested", %{final: "override"})

      assert [event] = all_captured()

      assert %{
               event: "case tested",
               distinct_id: "distinct_id",
               properties: %{
                 hello: "world",
                 foo: "bar",
                 final: "override"
               },
               timestamp: _
             } = event

      refute Map.has_key?(event.properties, :spam)
      refute Map.has_key?(event.properties, :distinct_id)
    end
  end

  describe "set_context/2 + get_context/2" do
    test "default scope" do
      PostHog.set_context(%{foo: "bar"})
      assert PostHog.get_context() == %{foo: "bar"}
      assert PostHog.get_context(PostHog) == %{foo: "bar"}
      assert PostHog.get_event_context("$exception") == %{foo: "bar"}
      assert PostHog.get_event_context(PostHog, "$exception") == %{foo: "bar"}
    end

    test "named scope, all events" do
      PostHog.set_context(MyPostHog, %{foo: "bar"})
      assert PostHog.get_context() == %{}
      assert PostHog.get_event_context("$exception") == %{}
      assert PostHog.get_context(MyPostHog) == %{foo: "bar"}
      assert PostHog.get_event_context(MyPostHog, "$exception") == %{foo: "bar"}
    end
  end

  def override_event_timestamp(event),
    do: Map.put(event, :timestamp, event.properties.timestamp_like)

  def modify_before_send(event) do
    saw_fully_enriched_event =
      event.properties[:"$lib"] == "posthog-elixir" and
        is_binary(event.properties[:"$lib_version"]) and
        event.properties[:"$is_server"] == true and
        event.properties[:source] == "global"

    event
    |> put_in([:properties, :before_send], true)
    |> put_in([:properties, :saw_fully_enriched_event], saw_fully_enriched_event)
    |> update_in([:properties], &Map.delete(&1, :secret))
  end

  def drop_before_send(_event), do: nil

  def invalid_before_send(_event), do: :invalid

  def raise_before_send(_event), do: raise("before_send failed")

  def throw_before_send(_event), do: throw(:before_send_failed)

  def exit_before_send(_event), do: exit(:before_send_failed)

  describe "set_event_context/2 + get_event_context/2" do
    test "default scope" do
      PostHog.set_event_context("$exception", %{foo: "bar"})
      assert PostHog.get_context() == %{}
      assert PostHog.get_event_context("$exception") == %{foo: "bar"}
      assert PostHog.get_context(PostHog) == %{}
      assert PostHog.get_event_context(PostHog, "$exception") == %{foo: "bar"}
    end

    test "named scope" do
      PostHog.set_event_context(MyPostHog, "$exception", %{foo: "bar"})
      assert PostHog.get_context() == %{}
      assert PostHog.get_event_context("$exception") == %{}
      assert PostHog.get_context(MyPostHog) == %{}
      assert PostHog.get_event_context(MyPostHog, "$exception") == %{foo: "bar"}
    end
  end
end
