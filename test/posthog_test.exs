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

    for {name, callback} <- [
          {"returns invalid value", &__MODULE__.invalid_before_send/1},
          {"raises", &__MODULE__.raise_before_send/1},
          {"throws", &__MODULE__.throw_before_send/1},
          {"exits", &__MODULE__.exit_before_send/1}
        ] do
      @tag config: [before_send: callback, supervisor_name: PostHog]
      test "before_send sends the original event when callback #{name}" do
        assert :ok = PostHog.bare_capture("case tested", "distinct_id", %{original: true})

        assert [%{event: "case tested", properties: properties}] = all_captured()
        assert properties[:original] == true
        refute properties[:before_send]
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
      PostHog.set_context(%{hello: "world", distinct_id: "distinct_id"})
      PostHog.set_event_context("case tested", %{foo: "bar"})
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
