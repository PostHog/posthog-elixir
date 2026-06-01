defmodule PostHog.UninitializedTest do
  use ExUnit.Case, async: true

  alias PostHog.FeatureFlags
  alias PostHog.FeatureFlags.Evaluations

  @supervisor_name __MODULE__.MissingSupervisor

  test "public APIs no-op when the supervisor was not started" do
    assert %{enabled: false, supervisor_name: @supervisor_name} = PostHog.config(@supervisor_name)
    assert :ok = PostHog.bare_capture(@supervisor_name, "event", "distinct_id", %{})

    PostHog.set_context(@supervisor_name, %{distinct_id: "distinct_id"})
    assert :ok = PostHog.capture(@supervisor_name, "event", %{})

    assert {:ok, %{}} = FeatureFlags.flags_for(@supervisor_name, "distinct_id")
    assert {:ok, snapshot} = FeatureFlags.evaluate_flags(@supervisor_name, "distinct_id")
    assert Evaluations.keys(snapshot) == []
    assert Evaluations.enabled?(snapshot, "flag") == false
  end
end
