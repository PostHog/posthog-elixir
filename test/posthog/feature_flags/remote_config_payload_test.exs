defmodule PostHog.FeatureFlags.RemoteConfigPayloadTest do
  use PostHog.Case, async: Version.match?(System.version(), ">= 1.18.0"), group: PostHog

  # A secret key would also start the flag definition loader, whose requests take the mock's
  # expectations.
  @moduletag config: [secret_key: "phs_secret_key", enable_local_evaluation: false]

  import Mox

  alias PostHog.FeatureFlags

  setup :setup_supervisor
  setup :verify_on_exit!

  @path "/api/projects/@current/feature_flags/test-flag/remote_config"

  defp respond(status, body) do
    expect(PostHog.API.Mock, :request, fn _client, :get, _url, _opts ->
      {:ok, %{status: status, body: body}}
    end)
  end

  defp stub_notify do
    test_pid = self()

    stub(PostHog.API.Mock, :request, fn _client, _method, _url, _opts ->
      send(test_pid, :requested)
      {:ok, %{status: 200, body: %{}}}
    end)
  end

  test "returns a map body that a custom client already decoded", %{test: name} do
    respond(200, %{"foo" => ["bar", "baz"]})

    assert {:ok, %{"foo" => ["bar", "baz"]}} =
             FeatureFlags.get_remote_config_payload(name, "test-flag")
  end

  test "decodes a raw JSON object body", %{test: name} do
    respond(200, ~s({"foo":["bar","baz"]}))

    assert {:ok, %{"foo" => ["bar", "baz"]}} =
             FeatureFlags.get_remote_config_payload(name, "test-flag")
  end

  test "decodes a double-encoded string body", %{test: name} do
    respond(200, Jason.encode!(~s({ "foo":["bar","baz"]})))

    assert {:ok, %{"foo" => ["bar", "baz"]}} =
             FeatureFlags.get_remote_config_payload(name, "test-flag")
  end

  test "returns a string that is not JSON unchanged", %{test: name} do
    respond(200, Jason.encode!("not json {"))

    assert {:ok, "not json {"} = FeatureFlags.get_remote_config_payload(name, "test-flag")
  end

  test "returns an empty map when the payload is empty", %{test: name} do
    respond(200, "{}")

    assert {:ok, %{}} == FeatureFlags.get_remote_config_payload(name, "test-flag")
  end

  test "returns an error for a 200 response with a body that is not JSON", %{test: name} do
    respond(200, "<html>")

    assert {:error, %PostHog.UnexpectedResponseError{response: %{status: 200}}} =
             FeatureFlags.get_remote_config_payload(name, "test-flag")
  end

  for {label, body} <- [{"empty", ""}, {"whitespace only", " \n\t"}] do
    test "returns {:ok, nil} for a 200 response with a body that is #{label}", %{test: name} do
      respond(200, unquote(body))

      assert {:ok, nil} == FeatureFlags.get_remote_config_payload(name, "test-flag")
    end
  end

  test "returns an error for a 404 response with an empty body", %{test: name} do
    respond(404, "")

    assert {:error, %PostHog.UnexpectedResponseError{response: %{status: 404, body: ""}}} =
             FeatureFlags.get_remote_config_payload(name, "test-flag")
  end

  test "sends GET with path, token, and bearer header", %{test: name} do
    expect(PostHog.API.Mock, :request, fn _client, method, url, opts ->
      assert method == :get
      assert url == @path
      assert opts[:params] == %{token: "my_api_key"}
      assert {"authorization", "Bearer phs_secret_key"} in opts[:headers]
      assert opts[:retry] == false
      assert opts[:decode_body] == false
      {:ok, %{status: 200, body: "{}"}}
    end)

    assert {:ok, %{}} == FeatureFlags.get_remote_config_payload(name, "test-flag")
  end

  test "encodes reserved characters in the flag key as one path segment", %{test: name} do
    expect(PostHog.API.Mock, :request, fn _client, :get, url, _opts ->
      assert url == "/api/projects/@current/feature_flags/a%2Fb%3Fc%23d%20e/remote_config"
      {:ok, %{status: 200, body: %{}}}
    end)

    expect(PostHog.API.Mock, :request, fn _client, :get, url, _opts ->
      assert url == "/api/projects/@current/feature_flags/my-flag_1.v~2/remote_config"
      {:ok, %{status: 200, body: %{}}}
    end)

    assert {:ok, %{}} == FeatureFlags.get_remote_config_payload(name, "a/b?c#d e")
    assert {:ok, %{}} == FeatureFlags.get_remote_config_payload(name, "my-flag_1.v~2")
  end

  for key <- ["", ".", ".."] do
    test "returns an error without a request for the flag key #{inspect(key)}", %{test: name} do
      stub_notify()

      assert {:error, %PostHog.Error{}} =
               FeatureFlags.get_remote_config_payload(name, unquote(key))

      refute_received :requested
    end
  end

  @tag config: [secret_key: nil, enable_local_evaluation: false]
  test "returns an error without a request when secret_key is not set", %{test: name} do
    stub_notify()

    assert {:error, %PostHog.Error{}} = FeatureFlags.get_remote_config_payload(name, "test-flag")
    refute_received :requested
  end

  @tag config: [api_key: "", secret_key: "phs_secret_key", enable_local_evaluation: false]
  test "returns {:ok, nil} without a request when the instance is disabled", %{test: name} do
    stub_notify()

    assert {:ok, nil} = FeatureFlags.get_remote_config_payload(name, "test-flag")
    refute_received :requested
  end

  test "returns {:ok, nil} for an instance that is not running" do
    assert {:ok, nil} = FeatureFlags.get_remote_config_payload(:not_running_instance, "test-flag")
  end

  for status <- [401, 404, 500] do
    test "returns an error on status #{status}", %{test: name} do
      respond(unquote(status), %{"detail" => "x"})

      assert {:error,
              %PostHog.UnexpectedResponseError{
                response: %{status: unquote(status), body: %{"detail" => "x"}}
              } = error} = FeatureFlags.get_remote_config_payload(name, "test-flag")

      refute Exception.message(error) =~ "phs_secret_key"
    end
  end

  test "decodes a raw JSON error body", %{test: name} do
    respond(401, ~s({"detail":"x"}))

    assert {:error, %PostHog.UnexpectedResponseError{response: response}} =
             FeatureFlags.get_remote_config_payload(name, "test-flag")

    assert response == %{status: 401, body: %{"detail" => "x"}}
  end

  test "returns the client's transport error", %{test: name} do
    error = %Req.TransportError{reason: :econnrefused}
    expect(PostHog.API.Mock, :request, fn _client, :get, _url, _opts -> {:error, error} end)

    assert {:error, ^error} = FeatureFlags.get_remote_config_payload(name, "test-flag")
  end

  test "does not capture any event", %{test: name} do
    respond(200, "{}")

    assert {:ok, %{}} == FeatureFlags.get_remote_config_payload(name, "test-flag")
    assert all_captured(name) == []
  end

  @tag config: [
         supervisor_name: PostHog,
         secret_key: "phs_secret_key",
         enable_local_evaluation: false
       ]
  test "arity 1 uses the default instance" do
    expect(PostHog.API.Mock, :request, fn _client, :get, url, opts ->
      assert url == @path
      assert opts[:params] == %{token: "my_api_key"}
      assert {"authorization", "Bearer phs_secret_key"} in opts[:headers]
      {:ok, %{status: 200, body: "{}"}}
    end)

    assert {:ok, %{}} == FeatureFlags.get_remote_config_payload("test-flag")
  end

  test "makes exactly one client call per request", %{test: name} do
    expect(PostHog.API.Mock, :request, 1, fn _client, :get, _url, _opts ->
      {:ok, %{status: 503, body: "{}"}}
    end)

    assert {:error, %PostHog.UnexpectedResponseError{}} =
             FeatureFlags.get_remote_config_payload(name, "test-flag")
  end
end
