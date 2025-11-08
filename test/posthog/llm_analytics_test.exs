defmodule Posthog.LLMAnalyticsTest do
  use PostHog.Case,
    async: Version.match?(System.version(), ">= 1.18.0"),
    group: PostHog

  @moduletag config: [supervisor_name: PostHog]

  import Mox

  alias PostHog.LLMAnalytics

  setup :setup_supervisor
  setup :verify_on_exit!

  describe "set_trace/2" do
    test "generates new trace_id of not passed" do
      assert "" <> id = LLMAnalytics.set_trace()

      assert [
               __posthog__: %{
                 PostHog => %{
                   "$ai_trace" => %{"$ai_trace_id": ^id},
                   "$ai_span" => %{"$ai_trace_id": ^id},
                   "$ai_generation" => %{"$ai_trace_id": ^id},
                   "$ai_embedding" => %{"$ai_trace_id": ^id},
                   "$exception" => %{"$ai_trace_id": ^id}
                 }
               }
             ] = Logger.metadata()
    end

    test "explicit trace_id" do
      assert "foo" = LLMAnalytics.set_trace("foo")

      assert [
               __posthog__: %{
                 PostHog => %{
                   "$ai_trace" => %{"$ai_trace_id": "foo"},
                   "$ai_span" => %{"$ai_trace_id": "foo"},
                   "$ai_generation" => %{"$ai_trace_id": "foo"},
                   "$ai_embedding" => %{"$ai_trace_id": "foo"},
                   "$exception" => %{"$ai_trace_id": "foo"}
                 }
               }
             ] = Logger.metadata()
    end

    @tag config: [supervisor_name: MyPostHog]
    test "custom PostHog instance" do
      assert "" <> id = LLMAnalytics.set_trace(MyPostHog)

      assert [
               __posthog__: %{
                 MyPostHog => %{
                   "$ai_trace" => %{"$ai_trace_id": ^id},
                   "$ai_span" => %{"$ai_trace_id": ^id},
                   "$ai_generation" => %{"$ai_trace_id": ^id},
                   "$ai_embedding" => %{"$ai_trace_id": ^id},
                   "$exception" => %{"$ai_trace_id": ^id}
                 }
               }
             ] = Logger.metadata()
    end

    @tag config: [supervisor_name: MyPostHog]
    test "custom PostHog instance and explicit trace_id" do
      assert "foo" = LLMAnalytics.set_trace(MyPostHog, "foo")

      assert [
               __posthog__: %{
                 MyPostHog => %{
                   "$ai_trace" => %{"$ai_trace_id": "foo"},
                   "$ai_span" => %{"$ai_trace_id": "foo"},
                   "$ai_generation" => %{"$ai_trace_id": "foo"},
                   "$ai_embedding" => %{"$ai_trace_id": "foo"},
                   "$exception" => %{"$ai_trace_id": "foo"}
                 }
               }
             ] = Logger.metadata()
    end
  end

  describe "get_trace/1" do
    test "retrieves trace_id" do
      assert "" <> id = LLMAnalytics.set_trace()
      assert ^id = LLMAnalytics.get_trace()
    end

    @tag config: [supervisor_name: MyPostHog]
    test "custom PostHog instance" do
      assert "" <> id = LLMAnalytics.set_trace(MyPostHog)
      assert ^id = LLMAnalytics.get_trace(MyPostHog)
    end
  end

  describe "set_root_span/2" do
    test "sets root span in process dictionary" do
      LLMAnalytics.set_root_span("foo")
      assert "foo" = Process.get({PostHog, :__llm_analytics_root_span_id})
    end

    test "custom PostHog instance" do
      LLMAnalytics.set_root_span(MyPostHog, "foo")
      assert nil == Process.get({PostHog, :__llm_analytics_root_span_id})
      assert "foo" = Process.get({MyPostHog, :__llm_analytics_root_span_id})
    end
  end

  describe "get_root_span/1" do
    test "sets root span in process dictionary" do
      LLMAnalytics.set_root_span("foo")
      assert "foo" = LLMAnalytics.get_root_span()
    end

    test "custom PostHog instance" do
      LLMAnalytics.set_root_span(MyPostHog, "foo")
      assert nil == LLMAnalytics.get_root_span()
      assert "foo" == LLMAnalytics.get_root_span(MyPostHog)
    end
  end

  describe "start_span/2" do
    test "pushes new span to the backlog in process dictionary" do
      assert "" <> span_id = LLMAnalytics.start_span(%{foo: "bar"})

      assert [%{foo: "bar", "$ai_span_id": span_id}] ==
               Process.get({PostHog, :__llm_analytics_spans})
    end

    test "nested spans" do
      assert "" <> span_id1 = LLMAnalytics.start_span(%{foo: "bar"})
      assert "" <> span_id2 = LLMAnalytics.start_span(%{spam: "eggs"})

      assert [
               %{spam: "eggs", "$ai_span_id": span_id2, "$ai_parent_id": span_id1},
               %{foo: "bar", "$ai_span_id": span_id1}
             ] == Process.get({PostHog, :__llm_analytics_spans})
    end

    test "respects root_span_id for topmost span" do
      LLMAnalytics.set_root_span("root_span_id")
      assert "" <> span_id1 = LLMAnalytics.start_span(%{foo: "bar"})
      assert "" <> span_id2 = LLMAnalytics.start_span(%{spam: "eggs"})

      assert [
               %{spam: "eggs", "$ai_span_id": span_id2, "$ai_parent_id": span_id1},
               %{foo: "bar", "$ai_span_id": span_id1, "$ai_parent_id": "root_span_id"}
             ] == Process.get({PostHog, :__llm_analytics_spans})
    end

    test "no properties" do
      assert "" <> span_id = LLMAnalytics.start_span()
      assert [%{"$ai_span_id": span_id}] == Process.get({PostHog, :__llm_analytics_spans})
    end

    test "does not override properties" do
      # users can do whatever they want
      LLMAnalytics.set_root_span("root_span_id")

      assert "span1" =
               LLMAnalytics.start_span(%{
                 foo: "bar",
                 "$ai_span_id": "span1",
                 "$ai_parent_id": "parent_id"
               })

      assert "span2" =
               LLMAnalytics.start_span(%{
                 spam: "eggs",
                 "$ai_span_id": "span2",
                 "$ai_parent_id": "parent_id"
               })

      assert [
               %{spam: "eggs", "$ai_span_id": "span2", "$ai_parent_id": "parent_id"},
               %{foo: "bar", "$ai_span_id": "span1", "$ai_parent_id": "parent_id"}
             ] == Process.get({PostHog, :__llm_analytics_spans})
    end

    @tag config: [supervisor_name: MyPostHog]
    test "custom PostHog instance" do
      assert "" <> span_id = LLMAnalytics.start_span(MyPostHog)
      assert nil == Process.get({PostHog, :__llm_analytics_spans})
      assert [%{"$ai_span_id": span_id}] == Process.get({MyPostHog, :__llm_analytics_spans})
    end
  end

  describe "capture_current_span/3" do
    setup %{test: test_name} do
      PostHog.set_context(%{distinct_id: test_name})
    end

    test "no span started" do
      assert :ok = LLMAnalytics.capture_current_span("$ai_generation", %{foo: "bar"})
      assert [event] = all_captured()

      assert %{
               event: "$ai_generation",
               properties: %{foo: "bar"}
             } = event

      refute event[:"$ai_span_id"]
    end

    test "respects root_span_id" do
      LLMAnalytics.set_root_span("root_span_id")
      assert :ok = LLMAnalytics.capture_current_span("$ai_generation", %{foo: "bar"})
      assert [event] = all_captured()

      assert %{
               event: "$ai_generation",
               properties: %{foo: "bar", "$ai_parent_id": "root_span_id"}
             } = event

      refute event[:"$ai_span_id"]
    end

    test "respects trace_id" do
      trace_id = LLMAnalytics.set_trace()
      assert :ok = LLMAnalytics.capture_current_span("$ai_generation", %{foo: "bar"})
      assert [event] = all_captured()

      assert %{
               event: "$ai_generation",
               properties: %{foo: "bar", "$ai_trace_id": ^trace_id}
             } = event

      refute event[:"$ai_span_id"]
    end

    test "pops started span from backlog" do
      span_id = LLMAnalytics.start_span(%{"$ai_span_name": "llm call"})
      assert :ok = LLMAnalytics.capture_current_span("$ai_generation", %{foo: "bar"})
      assert [event] = all_captured()

      assert %{
               event: "$ai_generation",
               properties: %{
                 foo: "bar",
                 "$ai_span_id": ^span_id,
                 "$ai_span_name": "llm call"
               }
             } = event

      refute event[:"$ai_parent_id"]
    end

    test "deep nested spans" do
      grandparent_id = LLMAnalytics.start_span(%{"$ai_span_name": "Chat"})
      parent_id = LLMAnalytics.start_span(%{"$ai_span_name": "Single turn"})
      child_id = LLMAnalytics.start_span(%{"$ai_span_name": "LLM call"})
      assert :ok = LLMAnalytics.capture_current_span("$ai_generation", %{foo: "bar"})
      assert :ok = LLMAnalytics.capture_current_span("$ai_span", %{spam: "eggs"})
      assert :ok = LLMAnalytics.capture_current_span("$ai_span", %{chat: "ok"})

      assert [
               %{
                 event: "$ai_span",
                 properties: %{
                   chat: "ok",
                   "$ai_span_id": ^grandparent_id,
                   "$ai_span_name": "Chat"
                 }
               },
               %{
                 event: "$ai_span",
                 properties: %{
                   spam: "eggs",
                   "$ai_span_id": ^parent_id,
                   "$ai_span_name": "Single turn",
                   "$ai_parent_id": ^grandparent_id
                 }
               },
               %{
                 event: "$ai_generation",
                 properties: %{
                   foo: "bar",
                   "$ai_span_id": ^child_id,
                   "$ai_span_name": "LLM call",
                   "$ai_parent_id": ^parent_id
                 }
               }
             ] = all_captured()
    end

    test "multiple children" do
      LLMAnalytics.set_root_span("root_span_id")
      parent_id = LLMAnalytics.start_span(%{"$ai_span_name": "Chat"})
      child_id1 = LLMAnalytics.start_span(%{"$ai_span_name": "LLM call"})
      assert :ok = LLMAnalytics.capture_current_span("$ai_generation", %{foo: "bar"})
      child_id2 = LLMAnalytics.start_span(%{"$ai_span_name": "Tool call"})
      assert :ok = LLMAnalytics.capture_current_span("$ai_span", %{tool_name: "tool"})
      assert :ok = LLMAnalytics.capture_current_span("$ai_span", %{chat: "ok"})

      assert [
               %{
                 event: "$ai_span",
                 properties: %{
                   chat: "ok",
                   "$ai_span_id": ^parent_id,
                   "$ai_span_name": "Chat",
                   "$ai_parent_id": "root_span_id"
                 }
               },
               %{
                 event: "$ai_span",
                 properties: %{
                   tool_name: "tool",
                   "$ai_span_id": ^child_id2,
                   "$ai_span_name": "Tool call",
                   "$ai_parent_id": ^parent_id
                 }
               },
               %{
                 event: "$ai_generation",
                 properties: %{
                   foo: "bar",
                   "$ai_span_id": ^child_id1,
                   "$ai_span_name": "LLM call",
                   "$ai_parent_id": ^parent_id
                 }
               }
             ] = all_captured()
    end

    test "no properties" do
      assert :ok = LLMAnalytics.capture_current_span("$ai_generation")
      assert [event] = all_captured()

      assert %{
               event: "$ai_generation",
               properties: %{}
             } = event
    end

    @tag config: [supervisor_name: MyPostHog]
    test "custom PostHog instance" do
      PostHog.set_context(MyPostHog, %{distinct_id: "foo"})
      assert :ok = LLMAnalytics.capture_current_span(MyPostHog, "$ai_generation")
      assert :ok = LLMAnalytics.capture_current_span(MyPostHog, "$ai_generation", %{foo: "bar"})

      assert [
               %{
                 event: "$ai_generation",
                 properties: %{foo: "bar"}
               },
               %{
                 event: "$ai_generation",
                 properties: %{}
               }
             ] = all_captured(MyPostHog)
    end
  end

  describe "capture_span/2" do
    setup %{test: test_name} do
      PostHog.set_context(%{distinct_id: test_name})
    end

    test "completely isolated span" do
      assert {:ok, "" <> id} = LLMAnalytics.capture_span("$ai_generation", %{foo: "bar"})
      assert [event] = all_captured()

      assert %{
               event: "$ai_generation",
               properties: %{foo: "bar", "$ai_span_id": ^id}
             } = event

      refute event[:properties][:"$ai_parent_id"]
    end

    test "respects trace and root span" do
      LLMAnalytics.set_trace("foo")
      LLMAnalytics.set_root_span("root_span_id")
      assert {:ok, "" <> id} = LLMAnalytics.capture_span("$ai_generation", %{foo: "bar"})
      assert [event] = all_captured()

      assert %{
               event: "$ai_generation",
               properties: %{
                 foo: "bar",
                 "$ai_trace_id": "foo",
                 "$ai_parent_id": "root_span_id",
                 "$ai_span_id": ^id
               }
             } = event
    end

    test "uses current span as parent if present" do
      LLMAnalytics.set_root_span("root_span_id")
      current_span_id = LLMAnalytics.start_span(%{foo: "bar"})
      assert {:ok, "" <> id} = LLMAnalytics.capture_span("$ai_generation", %{bar: "baz"})
      assert [event] = all_captured()

      assert %{
               event: "$ai_generation",
               properties: %{bar: "baz", "$ai_parent_id": ^current_span_id, "$ai_span_id": ^id}
             } = event
    end

    test "no properties" do
      assert {:ok, "" <> id} = LLMAnalytics.capture_span("$ai_generation")
      assert [event] = all_captured()

      assert %{
               event: "$ai_generation",
               properties: %{"$ai_span_id": ^id}
             } = event
    end

    @tag config: [supervisor_name: MyPostHog]
    test "custom PostHog instance" do
      PostHog.set_context(MyPostHog, %{distinct_id: "foo"})
      assert {:ok, "" <> id1} = LLMAnalytics.capture_span(MyPostHog, "$ai_generation")

      assert {:ok, "" <> id2} =
               LLMAnalytics.capture_span(MyPostHog, "$ai_generation", %{foo: "bar"})

      assert [
               %{
                 event: "$ai_generation",
                 properties: %{foo: "bar", "$ai_span_id": ^id2}
               },
               %{
                 event: "$ai_generation",
                 properties: %{"$ai_span_id": ^id1}
               }
             ] = all_captured(MyPostHog)
    end
  end
end
