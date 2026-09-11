defmodule SdkComplianceAdapter.RouterTest.Server do
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  match _ do
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    body =
      if Plug.Conn.get_req_header(conn, "content-encoding") == ["gzip"],
        do: :zlib.gunzip(body),
        else: body

    request = %{path: conn.request_path, query: conn.query_string, body: JSON.decode!(body)}

    {status, response} =
      Agent.get_and_update(__MODULE__, fn state ->
        {response, remaining} =
          if conn.request_path == "/flags" do
            [response | remaining] = state.responses
            {response, remaining}
          else
            {{200, %{}}, state.responses}
          end

        {response, %{state | requests: state.requests ++ [request], responses: remaining}}
      end)

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, JSON.encode!(response))
  end
end

defmodule SdkComplianceAdapter.RouterTest do
  use ExUnit.Case, async: false

  import Plug.Test
  alias SdkComplianceAdapter.RouterTest.Server

  setup_all do
    start_supervised!(%{
      id: Server,
      start: {Agent, :start_link, [fn -> %{requests: [], responses: []} end, [name: Server]]}
    })

    port = System.get_env("MOCK_PORT", "19281") |> String.to_integer()
    start_supervised!({Plug.Cowboy, scheme: :http, plug: Server, options: [port: port]})
    %{host: "http://127.0.0.1:#{port}"}
  end

  setup %{host: host} do
    post("/reset", %{})
    Agent.update(Server, fn _ -> %{requests: [], responses: []} end)
    assert post("/init", %{api_key: "phc_test_key", host: host}) == %{"success" => true}
    on_exit(fn -> post("/reset", %{}) end)
    :ok
  end

  test "evaluates scoped rich v2 flags and emits SDK called-event metadata" do
    respond([rich_response()])

    assert post("/get_feature_flag", %{
             key: "checkout",
             distinct_id: "user",
             person_properties: %{"$device_id" => "device"},
             groups: %{company: "acme"},
             group_properties: %{company: %{plan: "paid"}},
             disable_geoip: false,
             force_remote: true
           }) == %{"success" => true, "value" => "control"}

    [request] = requests("/flags")
    assert request.query == "v=2"

    assert request.body == %{
             "api_key" => "phc_test_key",
             "distinct_id" => "user",
             "flag_keys_to_evaluate" => ["checkout"],
             "person_properties" => %{"$device_id" => "device"},
             "groups" => %{"company" => "acme"},
             "group_properties" => %{"company" => %{"plan" => "paid"}},
             "geoip_disable" => false
           }

    [batch] = requests("/batch")
    [event] = batch.body["batch"]
    assert event["event"] == "$feature_flag_called"
    assert event["distinct_id"] == "user"
    assert event["properties"]["$feature_flag_response"] == "control"
    assert event["properties"]["$feature_flag_id"] == 42
    assert event["properties"]["$feature_flag_version"] == 3
    assert event["properties"]["$feature_flag_request_id"] == "request-123"
    assert event["properties"]["$feature_flag_has_experiment"] == true
  end

  test "preserves omitted options and uses remote evaluation for either force_remote value" do
    respond([rich_response(), rich_response()])

    for force_remote <- [false, true] do
      assert post("/get_feature_flag", %{
               key: "checkout",
               distinct_id: "user",
               force_remote: force_remote
             }) == %{"success" => true, "value" => "control"}
    end

    assert length(requests("/flags")) == 2

    for request <- requests("/flags") do
      assert request.body == %{
               "api_key" => "phc_test_key",
               "distinct_id" => "user",
               "flag_keys_to_evaluate" => ["checkout"]
             }
    end
  end

  test "returns SDK errors for legacy-only responses without capturing a called event" do
    respond([{200, %{"featureFlags" => %{"checkout" => true}}}])
    result = post("/get_feature_flag", %{key: "checkout", distinct_id: "user"})
    assert result["success"] == false
    assert is_binary(result["error"])
    assert length(requests("/flags")) == 1
    post("/flush", %{})
    assert requests("/batch") == []
  end

  for status <- [502, 504] do
    test "lets the SDK retry #{status} before evaluating a rich v2 result" do
      respond([{unquote(status), %{}}, rich_response()])

      assert post("/get_feature_flag", %{key: "checkout", distinct_id: "user"}) ==
               %{"success" => true, "value" => "control"}

      assert length(requests("/flags")) == 2
      assert length(requests("/batch")) == 1
    end
  end

  test "requires a flag key and distinct ID" do
    for params <- [%{key: "checkout"}, %{distinct_id: "user"}] do
      assert post("/get_feature_flag", params)["success"] == false
    end

    assert requests("/flags") == []
  end

  defp rich_response do
    {200,
     %{
       "flags" => %{
         "checkout" => %{
           "key" => "checkout",
           "enabled" => true,
           "variant" => "control",
           "metadata" => %{"id" => 42, "version" => 3, "has_experiment" => true}
         }
       },
       "requestId" => "request-123"
     }}
  end

  defp respond(responses), do: Agent.update(Server, &%{&1 | responses: responses})

  defp requests(path),
    do: Agent.get(Server, &Enum.filter(&1.requests, fn r -> r.path == path end))

  defp post(path, params) do
    conn(:post, path, JSON.encode!(params))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> SdkComplianceAdapter.Router.call(SdkComplianceAdapter.Router.init([]))
    |> Map.fetch!(:resp_body)
    |> JSON.decode!()
  end
end
