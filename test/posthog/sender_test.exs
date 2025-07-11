defmodule PostHog.SenderTest do
  use ExUnit.Case, async: true

  import Mox

  alias PostHog.Sender
  alias PostHog.API

  @supervisor_name __MODULE__

  setup_all do
    start_link_supervised!(
      {Registry, keys: :unique, name: PostHog.Registry.registry_name(@supervisor_name)}
    )

    %{api_client: %API.Client{client: :fake_client, module: API.Mock}}
  end

  setup :verify_on_exit!

  test "puts events into state", %{api_client: api_client} do
    pid =
      start_link_supervised!(
        {Sender,
         supervisor_name: @supervisor_name,
         api_client: api_client,
         max_batch_time_ms: 60_000,
         max_batch_events: 100}
      )

    Sender.send("my_event", @supervisor_name)

    assert %{events: ["my_event"]} = :sys.get_state(pid)
  end

  test "immediately sends after reaching max_batch_events", %{api_client: api_client} do
    pid =
      start_link_supervised!(
        {Sender,
         supervisor_name: @supervisor_name,
         api_client: api_client,
         max_batch_time_ms: 60_000,
         max_batch_events: 2}
      )

    expect(API.Mock, :request, fn _client, method, url, opts ->
      assert method == :post
      assert url == "/batch"

      assert opts[:json] == %{
               batch: ["bar", "foo"]
             }
    end)

    Sender.send("foo", @supervisor_name)
    Sender.send("bar", @supervisor_name)

    assert %{events: []} = :sys.get_state(pid)
  end

  test "immediately sends after reaching max_batch_time_ms", %{
    api_client: api_client,
    test_pid: test_pid
  } do
    start_link_supervised!(
      {Sender,
       supervisor_name: @supervisor_name,
       api_client: api_client,
       max_batch_time_ms: 0,
       max_batch_events: 100}
    )

    expect(API.Mock, :request, fn _client, method, url, opts ->
      assert method == :post
      assert url == "/batch"

      assert opts[:json] == %{
               batch: ["foo"]
             }

      send(test_pid, :ready)
    end)

    Sender.send("foo", @supervisor_name)

    assert_receive :ready
  end

  test "sends leftovers on shutdown", %{api_client: api_client} do
    pid =
      start_supervised!(
        {Sender,
         supervisor_name: @supervisor_name,
         api_client: api_client,
         max_batch_time_ms: 60_000,
         max_batch_events: 100}
      )

    expect(API.Mock, :request, fn _client, method, url, opts ->
      assert method == :post
      assert url == "/batch"

      assert opts[:json] == %{
               batch: ["foo"]
             }
    end)

    Sender.send("foo", @supervisor_name)

    assert :ok = GenServer.stop(pid)
  end
end
