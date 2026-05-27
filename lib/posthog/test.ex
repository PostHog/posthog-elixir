defmodule PostHog.Test do
  @moduledoc """
  PostHog Test Utilities Module

  PostHog makes it simple to test captured events. Make sure to set `mode: :test` in your `config/test.exs`:

  ```
  config :posthog, 
    mode: test
  ```

  Now PostHog will not send your captured events to the server and will instead
  keep them in memory, easily accessible for assertions:

  ```
  test "capture event" do
    PostHog.capture("event", %{distinct_id: "distinct_id"})

    assert [event] = PostHog.Test.all_captured()

    assert %{
              event: "event",
              distinct_id: "distinct_id",
              properties: %{},
              timestamp: _
            } = event
  end
  ```

  ## Concurrency

  PostHog uses `NimbleOwnership` ownership mechanism to determine
  which events belong to which tests. This should work very well for most tests.

  However, in some cases captured events cannot be traced back to tests. Those
  tests are usually well-known and are run with `async: false` mode. For those,
  PostHog lets you enable "global" or "shared" mode, where _all_ events captured
  within the system will be accessible by the test.

  To switch PostHog to shared mode, just call `PostHog.Test.set_posthog_shared/1`
  in your setup:

  ```
  defmodule MyTest do
    use ExUnit.Case, async: false
    
    setup_all {PostHog.Test, :set_posthog_shared}
    
    test "complex test" do
      # run some code
      assert events = PostHog.Test.all_captured()
      assert Enum.any?(events, & match?(%{event: "my event"}, &1))
    end
  end
  ```

  PostHog will revert back from shared mode to private once the test suite or test
  process exits.

  > #### Assertions in shared mode {: .info}
  >
  > In shared mode, your test can easily pick up events from background jobs,
  > other tests, or some rogue processes. Design your assertions accordingly to
  > avoid flaky tests!
  """
  @ownership_server PostHog.Ownership

  @doc false
  def remember_event(name, event) do
    # Usually, ownership is tracked by mocking libraries and they define
    # "expectations" at the beginning of the test. Our case is different—we
    # don't know beforehand that a test expects an event to be captured, so it's
    # very likely that none of the processes "own" anything yet. So we basically
    # declare them all owners and add the event to their personal stashes. If any of
    # the pids is the test pid, the test will be able to retrieve this event.
    [self() | Process.get(:"$callers", [])]
    |> get_owners(name)
    |> Enum.each(fn pid ->
      NimbleOwnership.get_and_update(@ownership_server, pid, name, fn maybe_meta ->
        {:ok, [event | maybe_meta || []]}
      end)
    end)
  end

  @doc """
  Retrieves all events captured by PostHog.

  In private mode, these are all events that can be attributed to the current
  process via ownership.

  In shared mode, these are all captured events.
  """
  @spec all_captured(PostHog.supervisor_name()) :: [map()]
  def all_captured(name \\ PostHog) do
    [owner_pid] = get_owners([self()], name)

    {:ok, events} =
      NimbleOwnership.get_and_update(@ownership_server, owner_pid, name, fn maybe_events ->
        {maybe_events || [], maybe_events || []}
      end)

    events
  end

  @doc """
  Allows a process to share captured events with another process.

  Imagine that your test spawns an asynchronous process that captures an event.
  By default, the test process won't be able to access this event. To mitigate this,
  the test process should explicitly _allow_ the spawned process' events to appear in
  its own personal stash of captured events.

  ```
  test "allowance" do
    test_pid = self()

    pid =
      spawn(fn ->
        receive do
          :go -> :ok
        end

        PostHog.capture("event", "user123")
        send(test_pid, :ready)
      end)

    PostHog.Test.allow(test_pid, pid)

    send(pid, :go)
    assert_receive :ready

    assert [%{event: "event"}] = PostHog.Test.all_captured()
  end
  ```

  > #### Caller Tracking {: .tip}
  >
  > In practice, explicit allowances are a tool of last resort. [Caller
  >  tracking](https://hexdocs.pm/elixir/Task.html#module-ancestor-and-caller-tracking)
  > allows for automatic ownership propagation. Designing your app with this in
  > mind is the key to painless testing.
  """
  @spec allow(PostHog.supervisor_name(), pid(), pid() | (-> resolved_pid)) ::
          :ok | {:error, NimbleOwnership.Error.t()}
        when resolved_pid: pid() | [pid()]
  def allow(name \\ PostHog, owner, pid_to_allow) do
    NimbleOwnership.get_and_update(@ownership_server, owner, name, fn maybe_events ->
      {nil, maybe_events || []}
    end)

    NimbleOwnership.allow(@ownership_server, owner, pid_to_allow, name)
  end

  @doc """
  Sets PostHog to shared (or "global") mode.

  In this mode, all events captured by all processes are accessible by the test.

  Usually used in combination with `async: false`.

  ## Examples:

      setup :set_posthog_shared
  """
  @spec set_posthog_shared(map()) :: :ok
  def set_posthog_shared(_test_context \\ %{}) do
    NimbleOwnership.set_mode_to_shared(@ownership_server, self())
  end

  defp get_owners(callers, key) do
    case NimbleOwnership.fetch_owner(@ownership_server, callers, key) do
      {:ok, owner_pid} -> [owner_pid]
      {:shared_owner, pid} -> [pid]
      :error -> callers
    end
  end
end
