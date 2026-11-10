defmodule PostHog.EmailsTest.ReqTestClient do
  @moduledoc false
  # The default client, with Req.Test in place of the network.
  @behaviour PostHog.API.Client

  alias PostHog.API.Client

  @impl true
  def client(api_key, api_host) do
    default = Client.client(api_key, api_host)
    %{default | client: Req.merge(default.client, plug: {Req.Test, __MODULE__})}
  end

  @impl true
  defdelegate request(client, method, url, opts), to: Client
end

defmodule PostHog.EmailsTest.FakeSendEndpoint do
  @moduledoc false
  import Plug.Conn

  @code_keys ~w(to distinct_id template_key subject html text from reply_to capture_engagement category)
  @category_keys ~w(key type name description)
  @message_id "01a18356-c56c-0001-e494-7666bc915188"

  def start(req_test_name) do
    {:ok, store} = Agent.start_link(fn -> %{categories: %{}, sends: 0} end)
    Req.Test.stub(req_test_name, &serve(&1, store))
    store
  end

  def categories(store), do: Agent.get(store, & &1.categories)

  def sends(store), do: Agent.get(store, & &1.sends)

  defp serve(conn, store) do
    {:ok, raw, conn} = read_body(conn)
    Agent.update(store, &%{&1 | sends: &1.sends + 1})
    {status, reply} = answer(Jason.decode!(raw), store)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(reply))
  end

  defp answer(body, store) do
    category = body["category"]

    cond do
      Map.keys(body) -- @code_keys != [] -> refuse("invalid_input", nil)
      category in [nil, "transactional"] -> accept()
      not well_formed?(category) -> refuse("invalid_input", "category")
      true -> upsert(store, category)
    end
  end

  defp well_formed?(%{"key" => key, "type" => type, "name" => name} = category)
       when is_binary(key) and type in ["marketing", "transactional"] and is_binary(name),
       do:
         Map.keys(category) -- @category_keys == [] and
           is_binary(Map.get(category, "description", ""))

  defp well_formed?(_category), do: false

  defp upsert(store, %{"key" => key, "type" => type} = category) do
    Agent.get_and_update(store, fn %{categories: categories} = state ->
      case categories[key] do
        %{"type" => stored} when stored != type ->
          {refuse("category_mismatch", "category"), state}

        stored ->
          fields = Map.merge(stored || %{"description" => nil}, Map.delete(category, "key"))
          {accept(), %{state | categories: Map.put(categories, key, fields)}}
      end
    end)
  end

  defp accept, do: {202, %{"message_id" => @message_id}}

  defp refuse(code, attr),
    do: {400, %{"type" => "validation_error", "code" => code, "detail" => code, "attr" => attr}}
end

defmodule PostHog.EmailsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Mox

  alias PostHog.API
  alias PostHog.Emails
  alias PostHog.Emails.Error
  alias PostHog.Emails.MessageCategory
  alias PostHog.EmailsTest.FakeSendEndpoint

  setup :verify_on_exit!

  @send_url "https://us.posthog.com/api/projects/@current/messaging/send/email/"
  @template_id "0190F6D2-7C1E-7B3A-9F5E-1C2D3E4F5A6B"
  @message_id "01a18356-c56c-0001-e494-7666bc915188"

  setup context do
    Mox.stub_with(API.Mock, API.Stub)
    test_pid = self()

    config =
      [
        api_host: "https://us.i.posthog.com",
        api_key: "phc_project_key",
        secret_key: "  phs_secret_key  ",
        api_client_module: API.Mock,
        supervisor_name: context.test,
        enable_local_evaluation: false
      ]
      |> Keyword.merge(context[:config] || [])
      |> PostHog.Config.validate!()
      |> Map.put(:email_sleep, fn ms ->
        send(test_pid, {:slept, ms})
        if context[:stop_instance_on_sleep], do: stop_supervised!(context.test)
      end)

    start_link_supervised!({PostHog.Supervisor, config})
    %{name: context.test}
  end

  defp expect_reply(times \\ 1, reply) do
    test_pid = self()

    expect(API.Mock, :request, times, fn _client, method, url, opts ->
      send(test_pid, {:request, method, url, opts})
      reply
    end)
  end

  defp accepted(body \\ %{"message_id" => @message_id}),
    do: {:ok, %{status: 202, headers: %{}, body: body}}

  defp refused(status, body, headers \\ %{}),
    do: {:ok, %{status: status, headers: headers, body: body}}

  defp sent_body do
    assert_received {:request, :post, @send_url, opts}
    Jason.decode!(opts[:body])
  end

  defp send_with_category(name, category, content \\ [text: "Thanks"]) do
    Emails.send(
      name,
      [to: "user@example.com", template_key: "receipt", subject: "Hi", category: category] ++
        content
    )
  end

  defp header(opts, name) do
    Enum.find_value(opts[:headers], fn {key, value} -> if key == name, do: value end)
  end

  defp refute_requested, do: refute_received({:request, _, _, _})

  describe "send/2 with a template made in PostHog" do
    test "posts the flat template body to the app host", %{name: name} do
      expect_reply(accepted())

      assert {:ok, %Emails.SendResult{id: @message_id, replayed: false, warnings: []}} =
               Emails.send(name,
                 to: "user@example.com",
                 template_id: @template_id,
                 template_data: %{name: "Ada"},
                 distinct_id: "user_123"
               )

      assert sent_body() == %{
               "template_id" => "0190f6d2-7c1e-7b3a-9f5e-1c2d3e4f5a6b",
               "to" => "user@example.com",
               "message_data" => %{"name" => "Ada"},
               "distinct_id" => "user_123"
             }
    end

    test "sends empty message data and no distinct ID when left out", %{name: name} do
      expect_reply(accepted())

      assert {:ok, _} = Emails.send(name, to: "user@example.com", template_id: @template_id)

      assert sent_body() == %{
               "template_id" => "0190f6d2-7c1e-7b3a-9f5e-1c2d3e4f5a6b",
               "to" => "user@example.com",
               "message_data" => %{}
             }
    end

    test "never takes the distinct ID from the process context", %{name: name} do
      PostHog.set_context(name, %{distinct_id: "context_user"})
      expect_reply(accepted())

      assert {:ok, _} = Emails.send(name, to: "user@example.com", template_id: @template_id)
      refute Map.has_key?(sent_body(), "distinct_id")
    end

    test "refuses a code form field", %{name: name} do
      for {field, value} <- [subject: "Hi", category: Emails.transactional_category()] do
        expected_field = to_string(field)

        assert {:error,
                %Error{code: "invalid_form", field: ^expected_field, name: :validation_error} =
                  error} =
                 Emails.send(
                   name,
                   [to: "user@example.com", template_id: @template_id] ++ [{field, value}]
                 )

        assert error.fix =~ "template_key"
        assert error.why =~ "template made in PostHog"
      end

      refute_requested()
    end

    test "refuses a template ID that is not a UUID", %{name: name} do
      assert {:error, %Error{code: "invalid_template_id", field: "template_id"}} =
               Emails.send(name, to: "user@example.com", template_id: "welcome")

      refute_requested()
    end

    test "refuses template data that is not a map", %{name: name} do
      assert {:error, %Error{code: "invalid_template_data"}} =
               Emails.send(name,
                 to: "user@example.com",
                 template_id: @template_id,
                 template_data: [name: "Ada"]
               )

      refute_requested()
    end

    test "refuses template data that can't be encoded as JSON", %{name: name} do
      assert {:error, %Error{code: "invalid_template_data"}} =
               Emails.send(name,
                 to: "user@example.com",
                 template_id: @template_id,
                 template_data: %{pid: self()}
               )

      refute_requested()
    end
  end

  describe "send/2 with content from code" do
    test "posts the rendered content with engagement capture on by default", %{name: name} do
      expect_reply(accepted())

      assert {:ok, %Emails.SendResult{id: @message_id}} =
               Emails.send(name,
                 to: "user@example.com",
                 distinct_id: "user_123",
                 template_key: "password-reset",
                 subject: "Reset your password",
                 html: "<p>Reset</p>",
                 text: "Reset",
                 from: "Acme <security@example.com>",
                 reply_to: "support@example.com"
               )

      assert sent_body() == %{
               "to" => "user@example.com",
               "distinct_id" => "user_123",
               "template_key" => "password-reset",
               "subject" => "Reset your password",
               "html" => "<p>Reset</p>",
               "text" => "Reset",
               "from" => "Acme <security@example.com>",
               "reply_to" => ["support@example.com"],
               "capture_engagement" => true
             }
    end

    test "sends only the fields given, and capture_engagement false", %{name: name} do
      expect_reply(accepted())

      assert {:ok, _} =
               Emails.send(name,
                 to: "user@example.com",
                 template_key: "receipt",
                 subject: "Your receipt",
                 text: "Thanks",
                 reply_to: ["a@example.com", "b@example.com"],
                 capture_engagement: false,
                 html: nil
               )

      assert sent_body() == %{
               "to" => "user@example.com",
               "template_key" => "receipt",
               "subject" => "Your receipt",
               "text" => "Thanks",
               "reply_to" => ["a@example.com", "b@example.com"],
               "capture_engagement" => false
             }
    end

    test "needs html, text or both", %{name: name} do
      assert {:error, %Error{code: "invalid_form", field: "html"}} =
               Emails.send(name, to: "user@example.com", template_key: "receipt", subject: "Hi")

      refute_requested()
    end

    test "needs a subject", %{name: name} do
      assert {:error, %Error{code: "invalid_form", field: "subject"}} =
               Emails.send(name, to: "user@example.com", template_key: "receipt", html: "<p/>")

      refute_requested()
    end

    test "refuses template data on the code form", %{name: name} do
      assert {:error, %Error{code: "invalid_form", field: "template_data"} = error} =
               Emails.send(name,
                 to: "user@example.com",
                 template_key: "receipt",
                 subject: "Hi",
                 html: "<p/>",
                 template_data: %{a: 1}
               )

      assert error.fix =~ "template_id"
      refute_requested()
    end

    test "refuses a template key with other characters", %{name: name} do
      assert {:error, %Error{code: "invalid_template_key", name: :validation_error}} =
               Emails.send(name,
                 to: "user@example.com",
                 template_key: "password reset",
                 subject: "Hi",
                 html: "<p/>"
               )

      refute_requested()
    end

    test "refuses a reply_to that is not addresses", %{name: name} do
      assert {:error, %Error{code: "invalid_form", field: "reply_to"}} =
               Emails.send(name,
                 to: "user@example.com",
                 template_key: "receipt",
                 subject: "Hi",
                 html: "<p/>",
                 reply_to: [:nope]
               )

      refute_requested()
    end

    test "refuses a category that is neither the shorthand nor a MessageCategory", %{name: name} do
      category = %MessageCategory{key: "newsletter", type: :marketing, name: "Newsletter"}

      for invalid <- [
            "newsletter",
            :transactional,
            %{key: "newsletter", type: :marketing, name: "Newsletter"},
            %{category | type: "marketing"},
            %{category | type: :bulk},
            %{category | key: nil},
            %{category | name: :newsletter},
            %{category | description: 1}
          ] do
        assert {:error, %Error{code: "invalid_form", field: "category"}} =
                 Emails.send(name,
                   to: "user@example.com",
                   template_key: "receipt",
                   subject: "Hi",
                   html: "<p/>",
                   category: invalid
                 )
      end

      refute_requested()
    end

    test "refuses a capture_engagement that is not a boolean", %{name: name} do
      assert {:error, %Error{code: "invalid_form", field: "capture_engagement"}} =
               Emails.send(name,
                 to: "user@example.com",
                 template_key: "receipt",
                 subject: "Hi",
                 html: "<p/>",
                 capture_engagement: "yes"
               )

      refute_requested()
    end
  end

  describe "send/2 argument checks" do
    test "needs exactly one form", %{name: name} do
      assert {:error, %Error{code: "invalid_form"}} = Emails.send(name, to: "user@example.com")

      assert {:error, %Error{code: "invalid_form"}} =
               Emails.send(name,
                 to: "user@example.com",
                 template_id: @template_id,
                 template_key: "receipt"
               )

      refute_requested()
    end

    test "refuses an option neither form takes", %{name: name} do
      assert {:error, %Error{code: "invalid_form", field: "cc", fix: "Remove cc and send again."}} =
               Emails.send(name,
                 to: "user@example.com",
                 template_id: @template_id,
                 cc: "x@example.com"
               )

      refute_requested()
    end

    test "refuses options that are not a keyword list or map", %{name: name} do
      assert {:error, %Error{code: "invalid_form"}} = Emails.send(name, ["user@example.com"])
      refute_requested()
    end

    test "takes a map of options", %{name: name} do
      expect_reply(accepted())

      assert {:ok, _} = Emails.send(name, %{to: "user@example.com", template_id: @template_id})
    end

    test "checks to, distinct_id, idempotency_key and max_retries", %{name: name} do
      base = [to: "user@example.com", template_id: @template_id]

      for {opts, code} <- [
            {[to: " "], "invalid_recipient"},
            {[to: ["a@example.com"]], "invalid_recipient"},
            {[distinct_id: ""], "invalid_distinct_id"},
            {[idempotency_key: "has space"], "invalid_idempotency_key"},
            {[idempotency_key: String.duplicate("a", 256)], "invalid_idempotency_key"},
            {[max_retries: -1], "invalid_max_retries"},
            {[max_retries: 1.0], "invalid_max_retries"}
          ] do
        assert {:error, %Error{code: ^code, name: :validation_error}} =
                 Emails.send(name, Keyword.merge(base, opts))
      end

      refute_requested()
    end
  end

  describe "send/2 headers and hosts" do
    test "authenticates with the trimmed secret key and sends the SDK headers", %{name: name} do
      expect_reply(accepted())

      assert {:ok, _} =
               Emails.send(name,
                 to: "user@example.com",
                 template_id: @template_id,
                 idempotency_key: "welcome:user_123"
               )

      assert_received {:request, :post, @send_url, opts}
      assert header(opts, "authorization") == "Bearer phs_secret_key"
      assert header(opts, "content-type") == "application/json"
      assert header(opts, "accept") == "application/json"
      assert header(opts, "idempotency-key") == "welcome:user_123"
      assert header(opts, "user-agent") == API.Client.user_agent()
      assert header(opts, "x-posthog-migrated-from") == nil
      assert opts[:retry] == false
      assert opts[:redirect] == false
      assert opts[:compress_body] == false
      assert opts[:receive_timeout] == 15_000
      refute Keyword.has_key?(opts, :json)
    end

    @tag config: [migrated_from: "resend", email_request_timeout_ms: 5_000]
    test "sends the migration source and the request timeout", %{name: name} do
      expect_reply(accepted())

      assert {:ok, _} = Emails.send(name, to: "user@example.com", template_id: @template_id)

      assert_received {:request, :post, @send_url, opts}
      assert header(opts, "x-posthog-migrated-from") == "resend"
      assert opts[:receive_timeout] == 5_000
    end

    @tag config: [api_host: "https://eu.i.posthog.com"]
    test "maps an EU ingestion host to the EU app host", %{name: name} do
      expect_reply(accepted())

      assert {:ok, _} = Emails.send(name, to: "user@example.com", template_id: @template_id)

      assert_received {:request, :post,
                       "https://eu.posthog.com/api/projects/@current/messaging/send/email/", _}
    end

    @tag config: [api_host: "https://proxy.example.com"]
    test "refuses a custom host without an app host", %{name: name} do
      assert {:error, %Error{code: "missing_app_host", name: :application_error}} =
               Emails.send(name, to: "user@example.com", template_id: @template_id)

      refute_requested()
    end

    @tag config: [
           api_host: "https://proxy.example.com",
           app_host: " https://posthog.example.com/ "
         ]
    test "sends to the app host the client sets", %{name: name} do
      expect_reply(accepted())

      assert {:ok, _} = Emails.send(name, to: "user@example.com", template_id: @template_id)

      assert_received {:request, :post,
                       "https://posthog.example.com/api/projects/@current/messaging/send/email/",
                       _}
    end

    @tag config: [app_host: "https://eu.i.posthog.com"]
    test "maps a cloud ingestion host set as the app host", %{name: name} do
      expect_reply(accepted())

      assert {:ok, _} = Emails.send(name, to: "user@example.com", template_id: @template_id)

      assert_received {:request, :post,
                       "https://eu.posthog.com/api/projects/@current/messaging/send/email/", _}
    end

    @tag config: [secret_key: nil]
    test "refuses to send without a secret key", %{name: name} do
      assert {:error, %Error{code: "missing_secret_key", name: :missing_api_key} = error} =
               Emails.send(name, to: "user@example.com", template_id: @template_id)

      assert error.message =~ "transactional_email:write scope"
      refute_requested()
    end

    test "a client that is not running sends nothing" do
      assert {:error, %Error{code: "client_disabled", name: :application_error}} =
               Emails.send(:not_started, to: "user@example.com", template_id: @template_id)

      refute_requested()
    end

    test "never puts the secret key or the body in an error", %{name: name} do
      expect_reply(refused(400, %{"code" => "invalid_request", "detail" => "Bad field."}))

      assert {:error, error} =
               Emails.send(name,
                 to: "user@example.com",
                 template_key: "k",
                 subject: "s",
                 html: "secret-html"
               )

      rendered = inspect(error) <> Exception.message(error)
      refute rendered =~ "phs_secret_key"
      refute rendered =~ "secret-html"
    end
  end

  describe "send/2 idempotency and retries" do
    test "every attempt sends the same generated UUID v4 key", %{name: name} do
      expect_reply(refused(503, %{"code" => "service_unavailable"}))
      expect_reply(accepted())

      assert {:ok, _} = Emails.send(name, to: "user@example.com", template_id: @template_id)

      assert_received {:request, :post, _, first}
      assert_received {:request, :post, _, second}
      key = header(first, "idempotency-key")
      assert key == header(second, "idempotency-key")
      assert key =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
    end

    test "makes 3 attempts by default and waits about 1 and then 2 seconds", %{name: name} do
      expect_reply(3, refused(503, nil))

      assert {:error, %Error{code: "api_error", status_code: 503, name: :service_unavailable}} =
               Emails.send(name, to: "user@example.com", template_id: @template_id)

      assert_received {:slept, first}
      assert_received {:slept, second}
      refute_received {:slept, _}
      assert first in 800..1200
      assert second in 1600..2400
    end

    test "a per-send max_retries of 0 makes one attempt", %{name: name} do
      expect_reply(refused(503, %{"code" => "service_unavailable"}))

      assert {:error, %Error{code: "service_unavailable"}} =
               Emails.send(name,
                 to: "user@example.com",
                 template_id: @template_id,
                 max_retries: 0
               )

      refute_received {:slept, _}
    end

    @tag config: [email_request_max_retries: 0]
    test "the client's email_request_max_retries sets the default", %{name: name} do
      expect_reply(refused(503, nil))

      assert {:error, %Error{status_code: 503}} =
               Emails.send(name, to: "user@example.com", template_id: @template_id)
    end

    test "retries network errors, throttling and an in-flight key", %{name: name} do
      expect_reply({:error, %Req.TransportError{reason: :econnrefused}})
      expect_reply(refused(429, %{"code" => "throttled"}))
      expect_reply(accepted())

      assert {:ok, _} =
               Emails.send(name,
                 to: "user@example.com",
                 template_id: @template_id,
                 max_retries: 3
               )

      expect_reply(refused(409, %{"code" => "idempotency_key_in_flight"}))
      expect_reply(accepted())

      assert {:ok, _} = Emails.send(name, to: "user@example.com", template_id: @template_id)
    end

    test "a network error on the last attempt is service_unavailable", %{name: name} do
      expect_reply({:error, %Req.TransportError{reason: :timeout}})

      assert {:error, %Error{code: "network_error", name: :service_unavailable, status_code: nil}} =
               Emails.send(name,
                 to: "user@example.com",
                 template_id: @template_id,
                 max_retries: 0
               )
    end

    test "does not retry a monthly quota, a conflict or a suppressed recipient", %{
      name: name
    } do
      for {status, code, error_name} <- [
            {429, "quota_limited", :monthly_quota_exceeded},
            {409, "template_outdated", :validation_error},
            {422, "recipient_suppressed", :validation_error},
            {422, "idempotency_key_reused", :invalid_idempotent_request},
            {400, "invalid_recipient", :validation_error},
            {401, "authentication_failed", :missing_api_key},
            {403, "permission_denied", :invalid_permission},
            {404, "not_found", :not_found},
            {500, "server_error", :application_error}
          ] do
        expect_reply(refused(status, %{"code" => code}))

        assert {:error, %Error{code: ^code, name: ^error_name, status_code: ^status}} =
                 Emails.send(name, to: "user@example.com", template_id: @template_id)
      end

      refute_received {:slept, _}
    end

    test "an in-flight key that stays in flight is concurrent_idempotent_requests", %{name: name} do
      expect_reply(refused(409, %{"code" => "idempotency_key_in_flight"}))

      assert {:error, %Error{name: :concurrent_idempotent_requests}} =
               Emails.send(name,
                 to: "user@example.com",
                 template_id: @template_id,
                 max_retries: 0
               )
    end

    test "waits for a Retry-After longer than the backoff", %{name: name} do
      expect_reply(refused(429, %{"code" => "throttled"}, %{"retry-after" => ["7"]}))
      expect_reply(accepted())

      assert {:ok, _} = Emails.send(name, to: "user@example.com", template_id: @template_id)
      assert_received {:slept, 7_000}
    end

    test "reads a Retry-After date", %{name: name} do
      later =
        DateTime.utc_now()
        |> DateTime.add(20)
        |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")

      expect_reply(refused(503, %{"code" => "service_unavailable"}, [{"retry-after", later}]))

      assert {:error, %Error{retry_after_ms: wait}} =
               Emails.send(name,
                 to: "user@example.com",
                 template_id: @template_id,
                 max_retries: 0
               )

      assert wait in 18_000..20_000
    end

    test "fails at once on a Retry-After over 30 seconds", %{name: name} do
      expect_reply(refused(429, %{"code" => "throttled"}, %{"retry-after" => ["60"]}))

      assert {:error,
              %Error{code: "throttled", retry_after_ms: 60_000, name: :rate_limit_exceeded}} =
               Emails.send(name, to: "user@example.com", template_id: @template_id)

      refute_received {:slept, _}
    end

    test "an acceptance without a message ID is api_error and not retried", %{name: name} do
      expect_reply(refused(202, %{}))

      assert {:error, %Error{code: "api_error", status_code: 202}} =
               Emails.send(name, to: "user@example.com", template_id: @template_id)

      refute_received {:slept, _}
    end

    test "retries a connection pool checkout timeout as a network error", %{name: name} do
      expect(API.Mock, :request, 2, fn _client, _method, _url, _opts ->
        raise "Finch was unable to provide a connection within the timeout due to excess queuing"
      end)

      expect_reply(accepted())

      assert {:ok, %Emails.SendResult{id: @message_id}} =
               Emails.send(name, to: "user@example.com", template_id: @template_id)

      assert_received {:slept, _}
      assert_received {:slept, _}
    end

    @tag stop_instance_on_sleep: true
    test "sends no retry after the instance stops", %{name: name} do
      expect_reply(refused(503, %{"code" => "service_unavailable"}))

      assert {:error, %Error{code: "client_closed"}} =
               Emails.send(name, to: "user@example.com", template_id: @template_id)

      assert_received {:slept, _}
    end

    @tag capture_log: true
    test "a client module that raises is unexpected_error", %{name: name} do
      expect(API.Mock, :request, fn _client, _method, _url, _opts -> raise "boom" end)

      assert {:error, %Error{code: "unexpected_error", name: :application_error}} =
               Emails.send(name, to: "user@example.com", template_id: @template_id)
    end
  end

  describe "send/2 in a caller that traps exits" do
    @tag config: [email_request_timeout_ms: 50]
    test "leaves the caller's mailbox clean after a reply and after a timeout", %{name: name} do
      expect_reply(accepted())

      expect(API.Mock, :request, fn _client, _method, _url, _opts ->
        Process.sleep(1_000)
        accepted()
      end)

      task =
        Task.async(fn ->
          Process.flag(:trap_exit, true)
          sent = Emails.send(name, to: "user@example.com", template_id: @template_id)

          timed_out =
            Emails.send(name, to: "user@example.com", template_id: @template_id, max_retries: 0)

          # Give any late exit or reply message time to arrive.
          Process.sleep(100)
          {sent, timed_out, Process.info(self(), :messages)}
        end)

      assert {{:ok, _}, {:error, %Error{code: "network_error"}}, {:messages, []}} =
               Task.await(task)
    end
  end

  describe "send/2 when its caller dies" do
    @tag config: [email_request_timeout_ms: 5_000]
    test "the request stops with the caller", %{name: name} do
      test_pid = self()

      expect(API.Mock, :request, fn _client, _method, _url, _opts ->
        send(test_pid, {:requesting, self()})
        Process.sleep(500)
        send(test_pid, :request_finished)
        accepted()
      end)

      caller =
        spawn(fn ->
          Process.put(:"$callers", [test_pid])
          Emails.send(name, to: "user@example.com", template_id: @template_id)
        end)

      assert_receive {:requesting, worker}
      worker_ref = Process.monitor(worker)
      Process.exit(caller, :kill)

      assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}
      refute_receive :request_finished, 700
    end
  end

  describe "send/2 when its request worker dies" do
    test "returns network_error and leaves the caller running", %{name: name} do
      expect(API.Mock, :request, fn _client, _method, _url, _opts ->
        Process.exit(self(), :kill)
      end)

      task =
        Task.async(fn ->
          result =
            Emails.send(name, to: "user@example.com", template_id: @template_id, max_retries: 0)

          Process.sleep(50)
          {result, Process.info(self(), :messages)}
        end)

      assert {{:error, %Error{code: "network_error"}}, {:messages, []}} = Task.await(task)
    end

    test "retries a client exit, such as a restarting pool, as a network error", %{name: name} do
      expect(API.Mock, :request, fn _client, _method, _url, _opts ->
        exit({:noproc, {GenServer, :call, [:pool, :checkout, 5_000]}})
      end)

      expect_reply(accepted())

      assert {:ok, %Emails.SendResult{id: @message_id}} =
               Emails.send(name, to: "user@example.com", template_id: @template_id)

      assert_received {:slept, _ms}
    end

    test "returns a client exit on a status read as network_error", %{name: name} do
      expect(API.Mock, :request, 3, fn _client, :get, _url, _opts -> exit(:normal) end)

      assert {:error, %Error{code: "network_error"}} = Emails.get(name, @message_id)
    end

    test "returns a client throw as unexpected_error without crashing the caller", %{name: name} do
      expect(API.Mock, :request, fn _client, _method, _url, _opts -> throw(:boom) end)

      assert {:error, %Error{code: "unexpected_error"}} =
               Emails.send(name, to: "user@example.com", template_id: @template_id)
    end
  end

  describe "send/2 replies" do
    test "keeps every field of a refusal", %{name: name} do
      expect_reply(
        refused(422, %{
          "type" => "validation_error",
          "code" => "recipient_suppressed",
          "detail" => "Nope.",
          "attr" => "to",
          "why" => "The address bounced.",
          "fix" => "Send to another address.",
          "docs_url" => "https://posthog.com/docs"
        })
      )

      assert {:error, error} =
               Emails.send(name, to: "user@example.com", template_id: @template_id)

      assert %Error{
               name: :validation_error,
               code: "recipient_suppressed",
               message: "Nope.",
               status_code: 422,
               field: "to",
               why: "The address bounced.",
               fix: "Send to another address.",
               docs_url: "https://posthog.com/docs"
             } = error
    end

    test "reads a JSON body the client module did not decode", %{name: name} do
      expect_reply(refused(404, ~s({"code": "not_found", "detail": "No template."})))

      assert {:error, %Error{code: "not_found", message: "No template."}} =
               Emails.send(name, to: "user@example.com", template_id: @template_id)
    end

    test "returns a replay and logs each warning", %{name: name} do
      expect_reply(
        accepted(%{
          "message_id" => @message_id,
          "replayed" => true,
          "warnings" => [
            %{"code" => "no_text", "detail" => "No text part.", "fix" => "Add text."}
          ]
        })
      )

      log =
        capture_log(fn ->
          assert {:ok, %Emails.SendResult{replayed: true, warnings: [warning]}} =
                   Emails.send(name, to: "user@example.com", template_id: @template_id)

          assert warning == %Emails.Warning{
                   code: "no_text",
                   message: "No text part.",
                   fix: "Add text."
                 }
        end)

      assert log =~ "PostHog email warning no_text: No text part."
    end
  end

  describe "get/2" do
    test "reads the status of a sent email", %{name: name} do
      expect_reply(
        {:ok,
         %{
           status: 200,
           headers: %{},
           body: %{
             "id" => @message_id,
             "status" => "bounced",
             "created_at" => "2026-10-28T16:27:44.364000Z",
             "status_at" => "2026-10-28T16:30:02.100000Z",
             "reason" => "hard"
           }
         }}
      )

      assert {:ok, %Emails.Status{} = status} = Emails.get(name, String.upcase(@message_id))

      assert status.id == @message_id
      assert status.status == "bounced"
      assert status.reason == "hard"
      assert status.created_at == ~U[2026-10-28 16:27:44.364000Z]
      assert status.status_at == ~U[2026-10-28 16:30:02.100000Z]

      assert_received {:request, :get,
                       "https://us.posthog.com/api/projects/@current/messaging/emails/01a18356-c56c-0001-e494-7666bc915188/",
                       opts}

      assert header(opts, "authorization") == "Bearer phs_secret_key"
      assert header(opts, "idempotency-key") == nil
      refute Keyword.has_key?(opts, :body)
    end

    test "passes an unknown status through", %{name: name} do
      expect_reply(
        {:ok,
         %{
           status: 200,
           body: %{
             "id" => @message_id,
             "status" => "archived",
             "created_at" => "2026-10-28T16:27:44Z",
             "status_at" => "2026-10-28T16:27:44Z"
           }
         }}
      )

      assert {:ok, %Emails.Status{status: "archived", reason: nil}} =
               Emails.get(name, @message_id)
    end

    test "a record without its times is api_error", %{name: name} do
      expect_reply({:ok, %{status: 200, body: %{"id" => @message_id, "status" => "sent"}}})

      assert {:error, %Error{code: "api_error", status_code: 200}} = Emails.get(name, @message_id)
    end

    test "does not retry an unknown ID", %{name: name} do
      expect_reply(refused(404, %{"code" => "not_found"}))

      assert {:error, %Error{code: "not_found", name: :not_found}} = Emails.get(name, @message_id)
      refute_received {:slept, _}
    end

    test "refuses an ID that is not a UUID", %{name: name} do
      assert {:error, %Error{code: "invalid_message_id", name: :validation_error}} =
               Emails.get(name, "msg_1")

      refute_requested()
    end
  end

  describe "config" do
    test "validates migrated_from as a header token" do
      assert {:error, %NimbleOptions.ValidationError{}} =
               PostHog.Config.validate(api_key: "phc", migrated_from: "re send")
    end

    test "refuses an app_host that is not an absolute HTTP(S) URL" do
      for app_host <- ["posthog.example.com", "/", "ftp://posthog.example.com", "https://"] do
        assert {:error, %NimbleOptions.ValidationError{key: :app_host}} =
                 PostHog.Config.validate(api_key: "phc", app_host: app_host)
      end

      assert {:ok, %{app_host: "http://localhost:8010"}} =
               PostHog.Config.validate(api_key: "phc", app_host: " http://localhost:8010 ")
    end
  end

  describe "through the default Req client" do
    @describetag config: [api_client_module: PostHog.EmailsTest.ReqTestClient]

    test "a category defined in code is created on its first send", %{name: name} do
      store = FakeSendEndpoint.start(__MODULE__.ReqTestClient)

      newsletter = %MessageCategory{
        key: "newsletter",
        type: :marketing,
        name: "Newsletter",
        description: "Monthly product news"
      }

      assert {:ok, _} = send_with_category(name, newsletter, html: "<p>{{ unsubscribe_url }}</p>")

      assert FakeSendEndpoint.categories(store) == %{
               "newsletter" => %{
                 "type" => "marketing",
                 "name" => "Newsletter",
                 "description" => "Monthly product news"
               }
             }
    end

    test "an unset description keeps the stored one, and an empty one clears it", %{name: name} do
      store = FakeSendEndpoint.start(__MODULE__.ReqTestClient)
      receipts = %MessageCategory{key: "receipts", type: :transactional, name: "Receipts"}

      for {description, stored} <- [
            {"Order receipts", "Order receipts"},
            {nil, "Order receipts"},
            {"", ""}
          ] do
        assert {:ok, _} = send_with_category(name, %{receipts | description: description})
        assert FakeSendEndpoint.categories(store)["receipts"]["description"] == stored
      end
    end

    test "a category the server refuses comes back as a validation_error, not retried", %{
      name: name
    } do
      store = FakeSendEndpoint.start(__MODULE__.ReqTestClient)
      receipts = %MessageCategory{key: "receipts", type: :transactional, name: "Receipts"}

      assert {:ok, _} = send_with_category(name, receipts)

      assert {:error,
              %Error{
                name: :validation_error,
                code: "category_mismatch",
                status_code: 400,
                field: "category"
              }} =
               send_with_category(name, %{receipts | type: :marketing},
                 html: "<p>{{ unsubscribe_url }}</p>"
               )

      assert FakeSendEndpoint.sends(store) == 2
      assert FakeSendEndpoint.categories(store)["receipts"]["type"] == "transactional"
    end

    test "the transactional shorthand sends without defining a category", %{name: name} do
      store = FakeSendEndpoint.start(__MODULE__.ReqTestClient)

      assert {:ok, _} = send_with_category(name, Emails.transactional_category())
      assert FakeSendEndpoint.categories(store) == %{}
    end

    test "an acceptance with malformed JSON is api_error with its status, not retried", %{
      name: name
    } do
      Req.Test.expect(__MODULE__.ReqTestClient, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(202, "{not json")
      end)

      assert {:error, %Error{code: "api_error", status_code: 202}} =
               Emails.send(name, to: "user@example.com", template_id: @template_id)

      refute_received {:slept, _}
    end

    test "sends the body as is, without the project API key", %{name: name} do
      test_pid = self()

      Req.Test.expect(__MODULE__.ReqTestClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:raw, conn.method, conn.host, conn.request_path, conn.req_headers, body})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(202, ~s({"message_id": "#{@message_id}"}))
      end)

      assert {:ok, %Emails.SendResult{id: @message_id}} =
               Emails.send(name, to: "user@example.com", template_id: @template_id)

      assert_received {:raw, "POST", "us.posthog.com",
                       "/api/projects/@current/messaging/send/email/", headers, body}

      refute Map.has_key?(Jason.decode!(body), "api_key")
      assert {"content-encoding", "gzip"} not in headers

      assert Enum.count(headers, fn {name, _value} -> name == "user-agent" end) == 1
    end

    @tag config: [
           api_client_module: PostHog.EmailsTest.ReqTestClient,
           email_request_timeout_ms: 50
         ]
    test "a request that outlasts the timeout is a network error at the deadline", %{name: name} do
      Req.Test.expect(__MODULE__.ReqTestClient, fn conn ->
        Process.sleep(2_000)
        Plug.Conn.send_resp(conn, 202, "{}")
      end)

      started = System.monotonic_time(:millisecond)

      assert {:error, %Error{code: "network_error", name: :service_unavailable}} =
               Emails.send(name,
                 to: "user@example.com",
                 template_id: @template_id,
                 max_retries: 0
               )

      assert System.monotonic_time(:millisecond) - started < 1_000
    end
  end
end
