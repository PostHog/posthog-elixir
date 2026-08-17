defmodule PostHog.WireSnapshotTest do
  use ExUnit.Case, async: true

  alias PostHog.API
  alias PostHog.API.Client
  alias PostHog.Sender

  @batch_supervisor Module.concat(__MODULE__, Batch)
  @exception_supervisor Module.concat(__MODULE__, Exception)
  @fixture_dir Path.expand("../fixtures/wire_snapshots", __DIR__)
  @fixed_timestamp "2024-01-02T03:04:05.678Z"
  @fixed_uuid "018cc820-db2e-7abc-8def-0123456789ab"
  @fixed_version "0.0.0-test"
  @authorization_secret "Bearer snapshot-authorization-secret"

  defmodule Adapter do
    @moduledoc false

    def run(request) do
      body = request.body |> IO.iodata_to_binary() |> decompress(request)

      envelope = %{
        "body" => Jason.decode!(body),
        "headers" => Map.new(request.headers),
        "method" => request.method |> Atom.to_string() |> String.upcase(),
        "url" => URI.to_string(request.url)
      }

      request
      |> Req.Request.get_private(:wire_snapshot_owner)
      |> send({:wire_request, body, envelope})

      {request, Req.Response.new(status: 200, body: %{"flags" => %{}})}
    end

    defp decompress(body, request) do
      case Req.Request.get_header(request, "content-encoding") do
        ["gzip"] -> :zlib.gunzip(body)
        [] -> body
      end
    end
  end

  test "snapshots the final /batch JSON and characterizes Jason duplicate-key decoding" do
    registry = PostHog.Registry.registry_name(@batch_supervisor)

    start_link_supervised!(
      {Registry, keys: :unique, name: registry, meta: [config: %{test_mode: false}]}
    )

    start_link_supervised!(
      {Sender,
       supervisor_name: @batch_supervisor,
       index: 1,
       api_client: wire_client(),
       max_batch_time_ms: 60_000,
       max_batch_events: 2}
    )

    Sender.send(
      %{
        event: "first-event",
        distinct_id: "user-1",
        uuid: @fixed_uuid,
        timestamp: @fixed_timestamp,
        properties: %{
          "collision" => "string-key-is-the-second-encoded-member",
          "nested" => %{"items" => [1, %{"position" => 2}]},
          collision: "atom-key-wins-after-jason-decode"
        }
      },
      @batch_supervisor
    )

    Sender.send(
      %{
        event: "second-event",
        distinct_id: "user-2",
        uuid: "018cc820-db2e-7abc-8def-0123456789ac",
        timestamp: @fixed_timestamp,
        properties: %{"sequence" => 2}
      },
      @batch_supervisor
    )

    assert_receive {:wire_request, raw_json, envelope}

    assert envelope["body"] |> canonicalize() == fixture!("batch.json")
    assert Enum.map(envelope["body"]["batch"], & &1["event"]) == ["second-event", "first-event"]

    assert raw_json =~
             ~s("collision":"atom-key-wins-after-jason-decode","collision":"string-key-is-the-second-encoded-member")

    # Duplicate JSON names are ambiguous; this characterizes Jason's first-member-wins decode.
    assert envelope["body"]["batch"] |> Enum.at(1) |> get_in(["properties", "collision"]) ==
             "atom-key-wins-after-jason-decode"
  end

  test "snapshots the full /flags HTTP envelope" do
    body = %{
      distinct_id: "flags-user",
      groups: %{"organization" => "org-42"},
      person_properties: %{"plan" => "enterprise", "roles" => ["admin", "author"]},
      group_properties: %{"organization" => %{"region" => "eu"}},
      disable_geoip: true,
      flag_keys_to_evaluate: ["checkout-v2", "billing-copy"]
    }

    assert {:ok, %Req.Response{status: 200}} = API.flags(wire_client(), body)
    assert_receive {:wire_request, _raw_json, envelope}

    assert canonicalize(envelope) == fixture!("flags_envelope.json")
  end

  test "snapshots a complete deterministic exception wire event without request secrets" do
    config =
      [
        api_key: "phc_snapshot",
        api_client_module: PostHog.API.Stub,
        before_send: &__MODULE__.stabilize_exception_event/1,
        root_source_code_paths: ["/workspace"],
        supervisor_name: @exception_supervisor,
        test_mode: true
      ]
      |> PostHog.Config.validate!()
      |> Map.put(:sender_pool_size, 1)

    start_link_supervised!({PostHog.Supervisor, config})

    conn =
      :post
      |> Plug.Test.conn("https://app.example.test/checkout?page=2")
      |> Plug.Conn.put_req_header("authorization", @authorization_secret)
      |> Plug.Conn.put_req_header("user-agent", "Snapshot Browser/1.0")

    handler_config = Map.put(config, :in_app_modules, MapSet.new([SnapshotApp.Checkout]))

    PostHog.Handler.log(
      %{
        level: :error,
        msg: {:string, "Card authorization failed"},
        meta: %{
          conn: conn,
          distinct_id: "exception-user",
          domain: [:elixir],
          file: ~c"/workspace/lib/snapshot_app/checkout.ex",
          line: 42,
          mfa: {SnapshotApp.Checkout, :authorize, 1}
        }
      },
      %{config: handler_config}
    )

    assert [event] = PostHog.Test.all_captured(@exception_supervisor)
    raw_json = Jason.encode!(event)

    refute raw_json =~ @authorization_secret
    assert raw_json |> Jason.decode!() |> canonicalize() == fixture!("exception_event.json")
  end

  @doc false
  def stabilize_exception_event(event) do
    event
    |> Map.put(:timestamp, @fixed_timestamp)
    |> Map.put(:uuid, @fixed_uuid)
    |> update_in([:properties, :"$lib_version"], fn _ -> @fixed_version end)
  end

  defp wire_client do
    client = Client.client("phc_snapshot", "https://snapshot.posthog.test")

    request =
      client.client
      |> Req.merge(adapter: Adapter)
      |> Req.Request.put_header("user-agent", "posthog-elixir/#{@fixed_version}")
      |> Req.Request.put_private(:wire_snapshot_owner, self())

    %{client | client: request}
  end

  defp fixture!(name) do
    @fixture_dir
    |> Path.join(name)
    |> File.read!()
    |> Jason.decode!()
    |> canonicalize()
  end

  defp canonicalize(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} -> {to_string(key), canonicalize(nested_value)} end)
  end

  defp canonicalize(value) when is_list(value), do: Enum.map(value, &canonicalize/1)
  defp canonicalize(value), do: value
end
