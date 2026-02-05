defmodule PostHog.SenderTest do
  use ExUnit.Case, async: true

  import Mox

  alias PostHog.API
  alias PostHog.Sender

  @supervisor_name __MODULE__

  setup_all do
    registry = PostHog.Registry.registry_name(@supervisor_name)

    start_link_supervised!(
      {Registry, keys: :unique, name: registry, meta: [config: %{test_mode: false}]}
    )

    %{api_client: %API.Client{client: :fake_client, module: API.Mock}, registry: registry}
  end

  setup :verify_on_exit!

  describe "send/2" do
    test "picks available sender", %{registry: registry} do
      busy_pid =
        start_link_supervised!(
          Supervisor.child_spec(
            {Agent, fn -> Registry.register(registry, {PostHog.Sender, 0}, :busy) end},
            id: Agent0
          )
        )

      available_pid =
        start_link_supervised!(
          Supervisor.child_spec(
            {Agent, fn -> Registry.register(registry, {PostHog.Sender, 1}, :available) end},
            id: Agent1
          )
        )

      :sys.suspend(busy_pid)
      :sys.suspend(available_pid)

      Sender.send("my_event", @supervisor_name)
      assert {:message_queue_len, 0} = Process.info(busy_pid, :message_queue_len)

      assert {:messages, ["$gen_cast": {:event, "my_event"}]} =
               Process.info(available_pid, :messages)
    end

    test "busy sender is ok if there are no available", %{registry: registry} do
      busy_pid =
        start_link_supervised!(
          Supervisor.child_spec(
            {Agent, fn -> Registry.register(registry, {PostHog.Sender, 0}, :busy) end},
            id: Agent0
          )
        )

      :sys.suspend(busy_pid)

      Sender.send("my_event", @supervisor_name)

      assert {:messages, ["$gen_cast": {:event, "my_event"}]} =
               Process.info(busy_pid, :messages)
    end
  end

  describe "retry behavior" do
    test "retries on retryable status codes", %{api_client: api_client} do
      test_pid = self()

      # First call returns 500, second returns 200
      expect(API.Mock, :request, fn _client, :post, "/batch", opts ->
        send(test_pid, {:request, opts})
        {:ok, %Req.Response{status: 500, headers: %{}, body: ""}}
      end)

      expect(API.Mock, :request, fn _client, :post, "/batch", opts ->
        send(test_pid, {:request, opts})
        {:ok, %Req.Response{status: 200, headers: %{}, body: %{"status" => "Ok"}}}
      end)

      start_link_supervised!(
        {Sender,
         supervisor_name: @supervisor_name,
         index: 1,
         api_client: api_client,
         max_batch_time_ms: 60_000,
         max_batch_events: 1,
         max_retries: 3}
      )

      Sender.send("event1", @supervisor_name)

      assert_receive {:request, _opts}, 5_000
      assert_receive {:request, _opts}, 5_000
    end

    test "does not retry on non-retryable status codes", %{api_client: api_client} do
      test_pid = self()

      expect(API.Mock, :request, 1, fn _client, :post, "/batch", _opts ->
        send(test_pid, :request_made)
        {:ok, %Req.Response{status: 400, headers: %{}, body: ""}}
      end)

      start_link_supervised!(
        {Sender,
         supervisor_name: @supervisor_name,
         index: 1,
         api_client: api_client,
         max_batch_time_ms: 60_000,
         max_batch_events: 1,
         max_retries: 3}
      )

      Sender.send("event1", @supervisor_name)

      assert_receive :request_made, 5_000
      refute_receive :request_made, 500
    end

    test "respects max_retries", %{api_client: api_client} do
      test_pid = self()

      # With max_retries: 2, expect 1 initial + 2 retries = 3 total
      expect(API.Mock, :request, 3, fn _client, :post, "/batch", _opts ->
        send(test_pid, :request_made)
        {:ok, %Req.Response{status: 500, headers: %{}, body: ""}}
      end)

      start_link_supervised!(
        {Sender,
         supervisor_name: @supervisor_name,
         index: 1,
         api_client: api_client,
         max_batch_time_ms: 60_000,
         max_batch_events: 1,
         max_retries: 2}
      )

      Sender.send("event1", @supervisor_name)

      assert_receive :request_made, 5_000
      assert_receive :request_made, 5_000
      assert_receive :request_made, 5_000
      refute_receive :request_made, 500
    end

    test "retries on network errors", %{api_client: api_client} do
      test_pid = self()

      expect(API.Mock, :request, fn _client, :post, "/batch", _opts ->
        send(test_pid, :request_made)
        {:error, %RuntimeError{message: "connection refused"}}
      end)

      expect(API.Mock, :request, fn _client, :post, "/batch", _opts ->
        send(test_pid, :request_made)
        {:ok, %Req.Response{status: 200, headers: %{}, body: %{"status" => "Ok"}}}
      end)

      start_link_supervised!(
        {Sender,
         supervisor_name: @supervisor_name,
         index: 1,
         api_client: api_client,
         max_batch_time_ms: 60_000,
         max_batch_events: 1,
         max_retries: 3}
      )

      Sender.send("event1", @supervisor_name)

      assert_receive :request_made, 5_000
      assert_receive :request_made, 5_000
    end

    test "preserves events across retries", %{api_client: api_client} do
      test_pid = self()

      expect(API.Mock, :request, fn _client, :post, "/batch", opts ->
        send(test_pid, {:request, opts})
        {:ok, %Req.Response{status: 500, headers: %{}, body: ""}}
      end)

      expect(API.Mock, :request, fn _client, :post, "/batch", opts ->
        send(test_pid, {:request, opts})
        {:ok, %Req.Response{status: 200, headers: %{}, body: %{"status" => "Ok"}}}
      end)

      start_link_supervised!(
        {Sender,
         supervisor_name: @supervisor_name,
         index: 1,
         api_client: api_client,
         max_batch_time_ms: 60_000,
         max_batch_events: 1,
         max_retries: 3}
      )

      Sender.send(%{event: "test", uuid: "abc-123"}, @supervisor_name)

      assert_receive {:request, opts1}, 5_000
      assert_receive {:request, opts2}, 5_000

      # Same batch payload sent both times
      assert opts1[:json][:batch] == opts2[:json][:batch]
    end
  end

  describe "Server" do
    test "starts in :available state", %{api_client: api_client, registry: registry} do
      pid =
        start_link_supervised!(
          {Sender,
           supervisor_name: @supervisor_name,
           index: 1,
           api_client: api_client,
           max_batch_time_ms: 60_000,
           max_batch_events: 100}
        )

      [{^pid, :available}] = Registry.lookup(registry, {PostHog.Sender, 1})
    end

    test "puts events into state", %{api_client: api_client} do
      pid =
        start_link_supervised!(
          {Sender,
           supervisor_name: @supervisor_name,
           index: 1,
           api_client: api_client,
           max_batch_time_ms: 60_000,
           max_batch_events: 100}
        )

      Sender.send("my_event", @supervisor_name)

      assert %{events: ["my_event"]} = :sys.get_state(pid)
    end

    test "immediately sends after reaching max_batch_events", %{
      api_client: api_client,
      registry: registry
    } do
      test_pid = self()

      pid =
        start_link_supervised!(
          {Sender,
           supervisor_name: @supervisor_name,
           index: 1,
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

        send(test_pid, :ready)

        receive do
          :go -> :ok
        end
      end)

      Sender.send("foo", @supervisor_name)
      Sender.send("bar", @supervisor_name)

      assert_receive :ready

      [{^pid, :busy}] = Registry.lookup(registry, {PostHog.Sender, 1})
      send(pid, :go)

      assert %{events: []} = :sys.get_state(pid)
      [{^pid, :available}] = Registry.lookup(registry, {PostHog.Sender, 1})
    end

    test "immediately sends after reaching max_batch_time_ms", %{
      api_client: api_client,
      registry: registry
    } do
      test_pid = self()

      pid =
        start_link_supervised!(
          {Sender,
           supervisor_name: @supervisor_name,
           index: 1,
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

        receive do
          :go -> :ok
        end

        send(test_pid, :done)
      end)

      Sender.send("foo", @supervisor_name)

      assert_receive :ready
      [{^pid, :busy}] = Registry.lookup(registry, {PostHog.Sender, 1})
      send(pid, :go)
      assert_receive :done
      :sys.get_status(pid)
      [{^pid, :available}] = Registry.lookup(registry, {PostHog.Sender, 1})
    end

    test "sends leftovers on shutdown", %{api_client: api_client} do
      pid =
        start_supervised!(
          {Sender,
           supervisor_name: @supervisor_name,
           index: 1,
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
end
