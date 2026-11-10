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

defmodule PostHog.EmailsTest.HeaderedClient do
  @moduledoc false
  # The default client with Req.Test in place of the network, set up as an app might: its own
  # authorization and an extra header on every request it makes.
  @behaviour PostHog.API.Client

  alias PostHog.API.Client

  @impl true
  def client(api_key, api_host) do
    default = Client.client(api_key, api_host)

    client =
      Req.merge(default.client,
        plug: {Req.Test, PostHog.EmailsTest.ReqTestClient},
        headers: [{"authorization", "Bearer client-token"}, {"x-client", "app"}]
      )

    %{default | client: client}
  end

  @impl true
  defdelegate request(client, method, url, opts), to: Client
end

defmodule PostHog.EmailsTest.FakePostHog do
  @moduledoc false
  # PostHog's email routes and its file storage as they behave, behind the SDK's real requests.
  # The upload route signs an upload for each file PostHog doesn't have. The storage keeps a file
  # only when its upload matches what was signed, as S3 checks a presigned PUT: the signed URL,
  # the signed headers, no second credential or unsigned x-amz- header, and the bytes. The send
  # route accepts an email only when PostHog has every file it names and the email fits PostHog's
  # 40 MB estimate. Like PostHog, it can hold a project to a daily upload quota: the upload route
  # refuses to sign uploads beyond what is left of it, and every file the storage keeps counts
  # against it. A test reads back the stored files, the accepted emails and what the send route
  # received, and can make a route's next request fail, wait or hold.
  #
  # The routes are :uploads and :send on PostHog, and :storage. Uploads are signed for
  # https://files.example.com unless set_storage_url/2 names another host.

  @secret_key "phs_secret_key"
  @uploads_path "/api/projects/@current/messaging/attachments/uploads/"
  @send_path "/api/projects/@current/messaging/send/email/"
  @storage_url "https://files.example.com"
  @max_body 64_000_000
  @max_message_bytes 40_000_000
  @signature "X-Amz-Signature=signed-secret"
  @signed_headers ["content-length", "x-amz-checksum-sha256"]

  @doc "Starts a fake for the calling test and routes the test's PostHog and storage requests to it."
  def start! do
    state = %{
      test: self(),
      storage_url: @storage_url,
      files: %{},
      signed: %{},
      messages: [],
      upload_quota: nil,
      uploaded_bytes: 0,
      received: %{uploads: [], storage: [], send: []},
      next: %{uploads: [], storage: [], send: []}
    }

    fake =
      ExUnit.Callbacks.start_supervised!(%{
        id: __MODULE__,
        start: {Agent, :start_link, [fn -> state end]}
      })

    Req.Test.stub(PostHog.EmailsTest.ReqTestClient, &serve(&1, fake))
    Req.Test.stub(PostHog.EmailsTest.Storage, &serve(&1, fake))
    fake
  end

  @doc "Stores files, as an earlier email that uploaded them would have."
  def put_files(fake, files) do
    Agent.update(fake, fn state ->
      %{state | files: Map.merge(state.files, Map.new(files, &{sha256(&1), &1}))}
    end)
  end

  @doc "Deletes a stored file, as when it expires."
  def delete_file(fake, bytes),
    do: Agent.update(fake, &%{&1 | files: Map.delete(&1.files, sha256(bytes))})

  @doc "Holds the project to a daily upload quota of `bytes`, counting the files stored today."
  def set_upload_quota(fake, bytes), do: Agent.update(fake, &%{&1 | upload_quota: bytes})

  @doc "Signs later uploads for the storage at `url`."
  def set_storage_url(fake, url), do: Agent.update(fake, &%{&1 | storage_url: url})

  @doc """
  Answers the route's next request with `reply` instead: `{status, json}` on PostHog's routes,
  and `{status, s3_code, s3_message}` or a transport error's reason, such as `:econnrefused`, on
  the storage.
  """
  def fail_next(fake, route, reply), do: script(fake, route, {:reply, reply})

  @doc "Makes the route take `ms` longer to answer its next request."
  def delay_next(fake, route, ms), do: script(fake, route, {:delay, ms})

  @doc """
  Holds the route's next request before it answers: the test gets `{:held, route, pid}`, and the
  route answers once the test sends `:release` to `pid`.
  """
  def hold_next(fake, route), do: script(fake, route, :hold)

  @doc "The stored files, by their hex SHA-256."
  def files(fake), do: Agent.get(fake, & &1.files)

  @doc "The accepted emails as `{message_id, email}`, oldest first."
  def messages(fake), do: Agent.get(fake, &Enum.reverse(&1.messages))

  @doc """
  What the route received, oldest first: the JSON body on PostHog's routes, and the method,
  path, query, headers and body on the storage.
  """
  def received(fake, route), do: Agent.get(fake, &Enum.reverse(&1.received[route]))

  @doc "The answer PostHog gives for a file it doesn't have, signed for the default storage."
  def upload_slot(bytes), do: upload_slot(@storage_url, sha256(bytes), byte_size(bytes))

  defp upload_slot(storage_url, sha256, size) do
    %{
      "sha256" => sha256,
      "status" => "upload",
      "url" => "#{storage_url}/team/1/#{sha256}?#{@signature}",
      "method" => "PUT",
      "headers" => %{
        "Content-Length" => to_string(size),
        "x-amz-checksum-sha256" => checksum(sha256)
      },
      "url_expires_at" => "2026-11-09T10:15:00Z"
    }
  end

  @doc "Serves PostHog and the storage, as a function plug for a real socket."
  def serve(conn, fake) do
    case conn.request_path do
      @uploads_path -> posthog(conn, :uploads, fake)
      @send_path -> posthog(conn, :send, fake)
      "/api/" <> _other -> json(conn, 404, refusal("not_found", "Not found.", nil))
      _storage -> storage(conn, fake)
    end
  end

  defp script(fake, route, step),
    do: Agent.update(fake, &update_in(&1.next[route], fn steps -> steps ++ [step] end))

  # Records what the route received and takes its next scripted step, if any.
  defp receive_request(fake, route, request) do
    Agent.get_and_update(fake, fn state ->
      {step, steps} =
        case state.next[route] do
          [step | steps] -> {step, steps}
          [] -> {:answer, []}
        end

      state = update_in(state.received[route], &[request | &1])
      {{step, state.test}, put_in(state.next[route], steps)}
    end)
  end

  defp run_step({:delay, ms}, _route, _test), do: Process.sleep(ms)

  defp run_step(:hold, route, test) do
    send(test, {:held, route, self()})

    receive do
      :release -> :ok
    end
  end

  defp run_step(:answer, _route, _test), do: :ok

  # PostHog

  defp posthog(conn, route, fake) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, length: @max_body)
    request = Jason.decode!(body)

    case receive_request(fake, route, request) do
      {{:reply, {status, reply}}, _test} ->
        json(conn, status, reply)

      {step, test} ->
        run_step(step, route, test)
        answer(conn, route, request, fake)
    end
  end

  defp answer(conn, route, request, fake) do
    cond do
      Plug.Conn.get_req_header(conn, "authorization") != ["Bearer #{@secret_key}"] ->
        json(conn, 401, refusal("authentication_failed", "Invalid secret API key.", nil))

      route == :uploads ->
        sign_uploads(conn, request, fake)

      true ->
        accept(conn, request, fake)
    end
  end

  defp sign_uploads(conn, %{"files" => files}, fake) when is_list(files) do
    case Agent.get_and_update(fake, &sign_within_quota(files, &1)) do
      {:ok, answers} ->
        json(conn, 200, %{"files" => answers})

      :quota_exceeded ->
        json(
          conn,
          429,
          refusal(
            "upload_quota_exceeded",
            "This project uploaded as many file bytes as it can today.",
            nil
          )
        )
    end
  end

  defp sign_uploads(conn, _request, _fake),
    do: json(conn, 400, refusal("required", "This field is required.", "files"))

  # Each file to upload counts in full, before any is signed.
  defp sign_within_quota(files, state) do
    to_upload =
      for %{"size" => size, "sha256" => sha256} <- files, not stored?(state, sha256), do: size

    if state.upload_quota && state.uploaded_bytes + Enum.sum(to_upload) > state.upload_quota do
      {:quota_exceeded, state}
    else
      {answers, state} = Enum.map_reduce(files, state, &sign/2)
      {{:ok, answers}, state}
    end
  end

  defp stored?(state, sha256), do: Map.has_key?(state.files, sha256)

  defp sign(%{"sha256" => sha256, "size" => size}, state) do
    if stored?(state, sha256) do
      {%{"sha256" => sha256, "status" => "present", "expires_at" => "2026-12-16T09:00:00Z"},
       state}
    else
      slot = upload_slot(state.storage_url, sha256, size)
      %URI{path: path, query: query} = URI.parse(slot["url"])
      {slot, put_in(state.signed[path], %{sha256: sha256, size: size, query: query})}
    end
  end

  defp accept(conn, email, fake) do
    files = files(fake)

    missing =
      email
      |> Map.get("attachments", [])
      |> Enum.find_index(&(not Map.has_key?(files, &1["sha256"])))

    if missing do
      json(
        conn,
        400,
        refusal(
          "attachment_not_uploaded",
          "A file this email names isn't uploaded, so PostHog didn't send the email.",
          "attachments__#{missing}__sha256"
        )
      )
    else
      if message_bytes(email, files) > @max_message_bytes do
        json(conn, 400, %{
          "type" => "invalid_request",
          "code" => "message_too_large",
          "detail" => "This email is too large to send, so PostHog didn't send it.",
          "attr" => nil
        })
      else
        json(conn, 202, %{"message_id" => record_message(fake, email)})
      end
    end
  end

  # PostHog's estimate of the sent message: each file and body as folded Base64, 64 KiB for
  # headers and MIME boundaries, and the subject as 75 bytes per 42 started. Without a text body,
  # PostHog derives one from the HTML, here by dropping its tags, and counts it too.
  defp message_bytes(email, files) do
    html = email["html"] || ""

    text =
      if email["text"] in [nil, ""],
        do: String.replace(html, ~r/<[^>]*>/, ""),
        else: email["text"]

    bodies = [byte_size(html), byte_size(text)]
    sizes = for %{"sha256" => sha256} <- email["attachments"] || [], do: byte_size(files[sha256])
    subject = byte_size(email["subject"] || "")

    Enum.reduce(bodies ++ sizes, 64 * 1024 + div(subject + 41, 42) * 75, fn size, total ->
      total + div(div(size + 2, 3) * 4 * 78 + 75, 76)
    end)
  end

  defp record_message(fake, email) do
    Agent.get_and_update(fake, fn state ->
      number = state.messages |> length() |> Kernel.+(1) |> Integer.to_string()
      id = "01a18356-c56c-0001-e494-" <> String.pad_leading(number, 12, "0")
      {id, %{state | messages: [{id, email} | state.messages]}}
    end)
  end

  defp refusal(code, detail, attr),
    do: %{"type" => "validation_error", "code" => code, "detail" => detail, "attr" => attr}

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  # Storage

  defp storage(conn, fake) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, length: @max_body)
    headers = for {name, value} <- conn.req_headers, do: {String.downcase(name), value}

    request = %{
      method: conn.method,
      path: conn.request_path,
      query: conn.query_string,
      headers: headers,
      body: body
    }

    case receive_request(fake, :storage, request) do
      {{:reply, {status, code, message}}, _test} ->
        s3_error(conn, status, code, message)

      {{:reply, reason}, _test} ->
        Req.Test.transport_error(conn, reason)

      {step, test} ->
        run_step(step, :storage, test)
        store(conn, request, fake)
    end
  end

  defp store(conn, request, fake) do
    signed = Agent.get(fake, & &1.signed[request.path])

    cond do
      request.method != "PUT" or signed == nil ->
        s3_error(conn, 403, "AccessDenied", "Access Denied.")

      List.keymember?(request.headers, "authorization", 0) ->
        s3_error(conn, 400, "InvalidArgument", "Only one auth mechanism allowed.")

      unsigned_amz_header?(request) ->
        s3_error(
          conn,
          403,
          "AccessDenied",
          "There were headers present in the request which were not signed."
        )

      not signature_matches?(request, signed) ->
        s3_error(conn, 403, "SignatureDoesNotMatch", "The request signature does not match.")

      Base.encode64(:crypto.hash(:sha256, request.body)) != checksum(signed.sha256) ->
        s3_error(conn, 400, "BadDigest", "The SHA256 you specified did not match.")

      true ->
        Agent.update(fake, fn state ->
          %{
            state
            | files: Map.put(state.files, signed.sha256, request.body),
              uploaded_bytes: state.uploaded_bytes + byte_size(request.body)
          }
        end)

        Plug.Conn.send_resp(conn, 200, "")
    end
  end

  # S3 ignores ordinary headers it wasn't asked to sign, but refuses an unsigned x-amz- one.
  defp unsigned_amz_header?(request) do
    Enum.any?(request.headers, fn {name, _value} ->
      String.starts_with?(name, "x-amz-") and name not in @signed_headers
    end)
  end

  defp signature_matches?(request, signed) do
    request.query == signed.query and
      header(request, "x-amz-checksum-sha256") == checksum(signed.sha256) and
      header(request, "content-length") == to_string(signed.size)
  end

  defp header(request, name) do
    case List.keyfind(request.headers, name, 0) do
      {^name, value} -> value
      nil -> nil
    end
  end

  defp s3_error(conn, status, code, message) do
    conn
    |> Plug.Conn.put_resp_content_type("application/xml")
    |> Plug.Conn.send_resp(
      status,
      ~s(<?xml version="1.0" encoding="UTF-8"?>\n<Error><Code>#{code}</Code><Message>#{message}</Message><Resource>/team/1/file</Resource></Error>)
    )
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp checksum(sha256), do: sha256 |> Base.decode16!(case: :lower) |> Base.encode64()
end

defmodule PostHog.EmailsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Mox

  alias PostHog.API
  alias PostHog.Emails
  alias PostHog.Emails.Error
  alias PostHog.EmailsTest.FakePostHog

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
      |> Map.put(
        :email_upload_adapter,
        context[:upload_adapter] || {Req.Plug, plug: {Req.Test, PostHog.EmailsTest.Storage}}
      )

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
      assert {:error,
              %Error{code: "invalid_form", field: "subject", name: :validation_error} = error} =
               Emails.send(name, to: "user@example.com", template_id: @template_id, subject: "Hi")

      assert error.fix =~ "template_key"
      assert error.why =~ "template made in PostHog"
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

  # What a refused send leaves behind at PostHog: no email and no file.
  defp nothing_sent?(fake),
    do: FakePostHog.messages(fake) == [] and FakePostHog.files(fake) == %{}

  describe "send/2 with cc and bcc" do
    @describetag config: [api_client_module: PostHog.EmailsTest.ReqTestClient]
    @code_send [to: "user@example.com", template_key: "receipt", subject: "Hi", html: "<p/>"]

    setup do
      %{fake: FakePostHog.start!()}
    end

    test "PostHog gets the copies, a string as a one-item list", %{name: name, fake: fake} do
      assert {:ok, %Emails.SendResult{id: id}} =
               Emails.send(
                 name,
                 @code_send ++
                   [cc: "finance@example.com", bcc: ["audit@example.com", "archive@example.com"]]
               )

      assert [{^id, email}] = FakePostHog.messages(fake)
      assert email["cc"] == ["finance@example.com"]
      assert email["bcc"] == ["audit@example.com", "archive@example.com"]
    end

    test "leaves out empty lists", %{name: name, fake: fake} do
      assert {:ok, _} =
               Emails.send(
                 name,
                 @code_send ++ [reply_to: [], cc: [], bcc: nil, attachments: []]
               )

      assert [{_id, email}] = FakePostHog.messages(fake)
      refute Enum.any?(["reply_to", "cc", "bcc", "attachments"], &Map.has_key?(email, &1))
    end

    test "a template send refuses them and attachments, and sends nothing", %{
      name: name,
      fake: fake
    } do
      for {field, value} <- [
            cc: "finance@example.com",
            bcc: "audit@example.com",
            attachments: [%{filename: "a.txt", content: "a"}]
          ] do
        assert {:error, %Error{code: "invalid_form", field: field_name} = error} =
                 Emails.send(name, [
                   {field, value},
                   to: "user@example.com",
                   template_id: @template_id
                 ])

        assert field_name == to_string(field)
        assert error.why =~ "sets its own sender, copies, subject, content and attachments"
        assert error.fix =~ "template_key"
      end

      assert nothing_sent?(fake)
    end

    test "refuses cc and bcc that are not addresses", %{name: name, fake: fake} do
      for {field, value} <- [cc: [:nope], bcc: " ", cc: %{a: 1}] do
        assert {:error, %Error{code: "invalid_form", field: field_name}} =
                 Emails.send(name, @code_send ++ [{field, value}])

        assert field_name == to_string(field)
      end

      assert nothing_sent?(fake)
    end
  end

  describe "send/2 with attachments" do
    @describetag config: [api_client_module: PostHog.EmailsTest.ReqTestClient]
    @code_send [to: "user@example.com", template_key: "receipt", subject: "Hi", html: "<p/>"]
    @pdf <<37, 80, 68, 70, 45, 0, 255, 10>>
    @logo "png bytes"

    setup do
      %{fake: FakePostHog.start!()}
    end

    defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    defp with_files(attachments), do: @code_send ++ [attachments: attachments]

    test "uploads the files PostHog asks for, then sends their references", %{
      name: name,
      fake: fake
    } do
      FakePostHog.put_files(fake, [@logo])

      assert {:ok, %Emails.SendResult{id: id}} =
               Emails.send(
                 name,
                 with_files([
                   %{filename: "invoice.pdf", content: @pdf, content_type: "application/pdf"},
                   %{filename: "logo.png", content: @logo, content_id: "logo"}
                 ])
               )

      assert FakePostHog.files(fake) == %{sha256(@pdf) => @pdf, sha256(@logo) => @logo}
      assert [{^id, email}] = FakePostHog.messages(fake)

      assert email["attachments"] == [
               %{
                 "sha256" => sha256(@pdf),
                 "filename" => "invoice.pdf",
                 "content_type" => "application/pdf"
               },
               %{"sha256" => sha256(@logo), "filename" => "logo.png", "content_id" => "logo"}
             ]
    end

    # The storage refuses a second credential, such as the client's authorization.
    @tag config: [api_client_module: PostHog.EmailsTest.HeaderedClient]
    test "uploads with only the headers PostHog signed, not the client's", %{
      name: name,
      fake: fake
    } do
      assert {:ok, %Emails.SendResult{id: id}} =
               Emails.send(name, with_files([%{filename: "a.pdf", content: @pdf}]))

      assert FakePostHog.files(fake) == %{sha256(@pdf) => @pdf}
      assert [{^id, %{"attachments" => [%{"sha256" => sha}]}}] = FakePostHog.messages(fake)
      assert sha == sha256(@pdf)
    end

    # The installed Req's default adapter, over a real socket, as in production. The local storage
    # is plain HTTP, which an app on a plain-HTTP PostHog may upload to.
    @tag upload_adapter: :none
    @tag config: [
           api_client_module: PostHog.EmailsTest.ReqTestClient,
           app_host: "http://localhost:8010"
         ]
    test "uploads over HTTP with Req's default adapter", %{name: name, fake: fake} do
      {:ok, server} =
        start_supervised({Bandit, plug: {&FakePostHog.serve/2, fake}, ip: :loopback, port: 0})

      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
      FakePostHog.set_storage_url(fake, "http://127.0.0.1:#{port}")

      assert {:ok, %Emails.SendResult{id: id}} =
               Emails.send(name, with_files([%{filename: "a.pdf", content: @pdf}]))

      assert FakePostHog.files(fake) == %{sha256(@pdf) => @pdf}
      assert [{^id, _email}] = FakePostHog.messages(fake)
    end

    # With no upload quota left, any upload would be refused.
    test "uploads nothing when PostHog has every file", %{name: name, fake: fake} do
      FakePostHog.put_files(fake, [@pdf])
      FakePostHog.set_upload_quota(fake, 0)

      assert {:ok, _} = Emails.send(name, with_files([%{filename: "a.pdf", content: @pdf}]))

      assert FakePostHog.files(fake) == %{sha256(@pdf) => @pdf}
      assert [{_id, %{"attachments" => [%{"sha256" => sha}]}}] = FakePostHog.messages(fake)
      assert sha == sha256(@pdf)
    end

    # The quota leaves room for one upload of each file.
    test "uploads a file attached twice once, and sends both references", %{
      name: name,
      fake: fake
    } do
      FakePostHog.set_upload_quota(fake, byte_size(@pdf) + byte_size(@logo))

      assert {:ok, _} =
               Emails.send(
                 name,
                 with_files([
                   %{filename: "a.pdf", content: @pdf},
                   %{filename: "copy.pdf", content: @pdf}
                 ])
               )

      assert FakePostHog.files(fake) == %{sha256(@pdf) => @pdf}
      assert [{_id, email}] = FakePostHog.messages(fake)

      assert [
               %{"sha256" => sha, "filename" => "a.pdf"},
               %{"sha256" => sha, "filename" => "copy.pdf"}
             ] =
               email["attachments"]

      assert sha == sha256(@pdf)

      assert {:ok, _} = Emails.send(name, with_files([%{filename: "logo.png", content: @logo}]))
      assert FakePostHog.files(fake) == %{sha256(@pdf) => @pdf, sha256(@logo) => @logo}
    end

    test "sends nothing after a failed upload, and returns the storage's answer", %{
      name: name,
      fake: fake
    } do
      FakePostHog.put_files(fake, [@logo])

      FakePostHog.fail_next(
        fake,
        :storage,
        {400, "BadDigest", "The SHA256 you specified did not match the calculated checksum."}
      )

      assert {:error, %Error{} = error} =
               Emails.send(
                 name,
                 with_files([
                   %{filename: "logo.png", content: @logo},
                   %{filename: "invoice.pdf", content: @pdf}
                 ])
               )

      assert %Error{
               code: "attachment_upload_failed",
               name: :application_error,
               status_code: 400,
               field: "attachments__1"
             } = error

      assert error.message =~ "invoice.pdf"
      assert error.message =~ "files.example.com"
      assert error.message =~ "BadDigest"
      assert error.message =~ "did not match the calculated checksum."
      refute error.message =~ ".."
      assert error.why =~ "no email was sent"
      refute inspect(error) =~ "signed-secret"
      refute inspect(error) =~ @pdf

      assert FakePostHog.files(fake) == %{sha256(@logo) => @logo}
      assert FakePostHog.messages(fake) == []
    end

    @tag config: [
           api_client_module: PostHog.EmailsTest.ReqTestClient,
           email_request_max_retries: 4
         ]
    test "retries an upload the storage couldn't take, then sends", %{name: name, fake: fake} do
      FakePostHog.fail_next(fake, :storage, {503, "SlowDown", "Please reduce your request rate."})
      FakePostHog.fail_next(fake, :storage, {429, "TooManyRequests", "Please slow down."})

      FakePostHog.fail_next(
        fake,
        :storage,
        {500, "InternalError", "We encountered an internal error."}
      )

      FakePostHog.fail_next(fake, :storage, :closed)

      assert {:ok, %Emails.SendResult{id: id}} =
               Emails.send(name, with_files([%{filename: "a.pdf", content: @pdf}]))

      assert FakePostHog.files(fake) == %{sha256(@pdf) => @pdf}
      assert [{^id, _email}] = FakePostHog.messages(fake)
    end

    @tag config: [
           api_client_module: PostHog.EmailsTest.ReqTestClient,
           email_request_timeout_ms: 50
         ]
    test "gives an upload ten seconds per MB on top of the request timeout", %{
      name: name,
      fake: fake
    } do
      file = :binary.copy(<<1>>, 100_000)
      # 100 KB at ten seconds per MB is 1 s on top of the 50 ms request timeout.
      FakePostHog.delay_next(fake, :storage, 950)

      assert {:ok, _} =
               Emails.send(
                 name,
                 with_files([%{filename: "a.bin", content: file}]) ++ [max_retries: 0]
               )

      assert FakePostHog.files(fake) == %{sha256(file) => file}
    end

    # The refusal is the storage's next answer only, so a retry would succeed.
    test "doesn't retry an upload the storage refused", %{name: name, fake: fake} do
      FakePostHog.fail_next(fake, :storage, {403, "AccessDenied", "Request has expired."})

      assert {:error,
              %Error{
                code: "attachment_upload_failed",
                name: :application_error,
                status_code: 403
              }} = Emails.send(name, with_files([%{filename: "a.pdf", content: @pdf}]))

      assert nothing_sent?(fake)
    end

    test "a storage 401 doesn't blame the PostHog key", %{name: name, fake: fake} do
      FakePostHog.fail_next(fake, :storage, {401, "Unauthorized", "Proxy needs a login."})

      assert {:error, %Error{code: "attachment_upload_failed", name: :application_error}} =
               Emails.send(name, with_files([%{filename: "a.pdf", content: @pdf}]))
    end

    test "an upload that keeps failing at the network sends nothing", %{name: name, fake: fake} do
      FakePostHog.fail_next(fake, :storage, :econnrefused)

      assert {:error, %Error{code: "attachment_upload_failed", status_code: nil} = error} =
               Emails.send(
                 name,
                 with_files([%{filename: "a.pdf", content: @pdf}]) ++ [max_retries: 0]
               )

      assert error.message =~ "files.example.com"
      assert error.fix =~ "reach files.example.com directly"
      assert error.field == "attachments__0"
      refute inspect(error) =~ "signed-secret"
      assert nothing_sent?(fake)
    end

    test "a send whose instance stops between its steps sends nothing more", %{
      name: name,
      fake: fake
    } do
      FakePostHog.hold_next(fake, :uploads)

      sending =
        Task.async(fn -> Emails.send(name, with_files([%{filename: "a.pdf", content: @pdf}])) end)

      assert_receive {:held, :uploads, request}
      stop_supervised!(name)
      send(request, :release)

      assert {:error, %Error{code: "client_closed"} = error} = Task.await(sending)
      assert error.message =~ "no email was sent"
      assert nothing_sent?(fake)
    end

    test "a template send takes empty lists as left out", %{name: name, fake: fake} do
      assert {:ok, _} =
               Emails.send(name,
                 to: "user@example.com",
                 template_id: @template_id,
                 reply_to: [],
                 cc: [],
                 bcc: [],
                 attachments: []
               )

      assert [{_id, email}] = FakePostHog.messages(fake)
      refute Enum.any?(["reply_to", "cc", "bcc", "attachments"], &Map.has_key?(email, &1))
    end

    # The quota leaves room for one upload of each file.
    test "a send retry doesn't upload again", %{name: name, fake: fake} do
      FakePostHog.set_upload_quota(fake, byte_size(@pdf) + byte_size(@logo))
      FakePostHog.fail_next(fake, :send, {503, %{"code" => "service_unavailable"}})

      assert {:ok, %Emails.SendResult{id: id}} =
               Emails.send(name, with_files([%{filename: "a.pdf", content: @pdf}]))

      assert [{^id, _email}] = FakePostHog.messages(fake)

      assert {:ok, _} = Emails.send(name, with_files([%{filename: "logo.png", content: @logo}]))
      assert FakePostHog.files(fake) == %{sha256(@pdf) => @pdf, sha256(@logo) => @logo}
    end

    test "returns PostHog's refusal of the uploads, naming the attachment", %{
      name: name,
      fake: fake
    } do
      FakePostHog.fail_next(
        fake,
        :uploads,
        {400,
         %{
           "type" => "invalid_request",
           "code" => "message_too_large",
           "detail" =>
             "These files are too large for one email, so PostHog didn't prepare the uploads.",
           "attr" => "files__1__size",
           "why" => "An email can be at most 40 MB after Base64 encoding, about 29 MB of files.",
           "fix" => "Send fewer or smaller files."
         }}
      )

      assert {:error,
              %Error{
                code: "message_too_large",
                status_code: 400,
                field: "attachments__2__content",
                why: "An email can be at most 40 MB" <> _
              }} =
               Emails.send(
                 name,
                 with_files([
                   %{filename: "a.png", content: @logo},
                   %{filename: "b.png", content: @logo},
                   %{filename: "c.pdf", content: @pdf}
                 ])
               )

      FakePostHog.fail_next(
        fake,
        :uploads,
        {400, %{"code" => "field_not_accepted", "attr" => "files", "detail" => "Not yet."}}
      )

      assert {:error, %Error{code: "field_not_accepted", field: "attachments"}} =
               Emails.send(name, with_files([%{filename: "a.pdf", content: @pdf}]))

      FakePostHog.fail_next(
        fake,
        :uploads,
        {401, %{"code" => "authentication_failed", "detail" => "Bad key."}}
      )

      assert {:error, %Error{code: "authentication_failed", field: nil}} =
               Emails.send(name, with_files([%{filename: "a.pdf", content: @pdf}]))

      assert nothing_sent?(fake)
    end

    test "a PostHog without the upload route sends nothing", %{name: name, fake: fake} do
      FakePostHog.fail_next(
        fake,
        :uploads,
        {404, %{"type" => "invalid_request", "code" => "not_found", "detail" => "Not found."}}
      )

      assert {:error, %Error{code: "not_found", status_code: 404, field: "attachments"}} =
               Emails.send(name, with_files([%{filename: "a.pdf", content: @pdf}]))

      assert nothing_sent?(fake)
    end

    # Each refusal is the upload route's next answer only, so a retry succeeds.
    test "doesn't retry the daily upload quota, and retries unavailable storage", %{
      name: name,
      fake: fake
    } do
      FakePostHog.fail_next(
        fake,
        :uploads,
        {429, %{"code" => "upload_quota_exceeded", "detail" => "Enough today."}}
      )

      assert {:error, %Error{code: "upload_quota_exceeded", status_code: 429, field: nil}} =
               Emails.send(name, with_files([%{filename: "a.pdf", content: @pdf}]))

      assert nothing_sent?(fake)

      FakePostHog.fail_next(fake, :uploads, {503, %{"code" => "delivery_unavailable"}})

      assert {:ok, %Emails.SendResult{id: id}} =
               Emails.send(name, with_files([%{filename: "a.pdf", content: @pdf}]))

      assert [{^id, _email}] = FakePostHog.messages(fake)
      assert FakePostHog.files(fake) == %{sha256(@pdf) => @pdf}
    end

    test "an answer the SDK can't use sends nothing", %{name: name, fake: fake} do
      slot = FakePostHog.upload_slot(@pdf)

      for answer <- [
            [],
            [%{"sha256" => sha256(@logo), "status" => "present"}],
            [%{"sha256" => sha256(@pdf), "status" => "copied"}],
            [Map.delete(slot, "url")],
            [Map.put(slot, "url", "ftp://files.example.com/a")],
            [Map.put(slot, "method", "POST")],
            [Map.put(slot, "headers", %{"Content-Length" => 8})]
          ] do
        FakePostHog.fail_next(fake, :uploads, {200, %{"files" => answer}})

        assert {:error, %Error{code: "api_error", status_code: 200}} =
                 Emails.send(name, with_files([%{filename: "a.pdf", content: @pdf}]))
      end

      assert nothing_sent?(fake)
    end

    test "refuses more than 10 files, and sends nothing", %{name: name, fake: fake} do
      files = for i <- 1..11, do: %{filename: "#{i}.txt", content: "file #{i}"}

      assert {:error,
              %Error{
                code: "too_many_attachments",
                name: :validation_error,
                field: "attachments"
              } = error} = Emails.send(name, with_files(files))

      assert error.fix =~ "10"
      assert nothing_sent?(fake)
    end

    test "refuses an email over 40 MB after Base64 encoding, and sends nothing", %{
      name: name,
      fake: fake
    } do
      largest_that_fits = 29_182_821
      file = :binary.copy(<<0>>, largest_that_fits)

      for options <- [
            [html: "", attachments: [%{filename: "a", content: file <> <<0>>}]],
            [html: "<p>", attachments: [%{filename: "a", content: file}]],
            [html: "", text: "x", attachments: [%{filename: "a", content: file}]]
          ] do
        assert {:error,
                %Error{code: "message_too_large", name: :validation_error, field: "attachments"} =
                  error} = Emails.send(name, @code_send ++ options)

        assert error.why =~ "40 MB"
        assert error.fix =~ "29 MB"
      end

      assert nothing_sent?(fake)

      FakePostHog.put_files(fake, [file])

      assert {:ok, _} =
               Emails.send(
                 name,
                 @code_send ++ [html: "", attachments: [%{filename: "a", content: file}]]
               )

      assert [{_id, _email}] = FakePostHog.messages(fake)
    end

    # PostHog derives the text from the HTML and counts it too, never longer than the HTML.
    test "counts the HTML twice without a text body", %{name: name, fake: fake} do
      html = :binary.copy("a", 1_000_000)
      files = [%{filename: "a.bin", content: :binary.copy(<<1>>, 28_000_000)}]
      html_only = Keyword.put(with_files(files), :html, html)

      assert {:error, %Error{code: "message_too_large", field: "attachments"} = error} =
               Emails.send(name, html_only)

      assert error.fix =~ ":text"
      assert nothing_sent?(fake)

      with_text = html_only ++ [text: "Thanks"]
      larger_files = [%{filename: "a.bin", content: :binary.copy(<<1>>, 29_500_000)}]

      assert {:error, %Error{code: "message_too_large"} = error} =
               Emails.send(name, Keyword.put(with_text, :attachments, larger_files))

      refute error.fix =~ ":text"

      assert {:ok, %Emails.SendResult{}} = Emails.send(name, with_text)
    end

    test "uploads nothing to a plain-HTTP storage URL", %{name: name, fake: fake} do
      FakePostHog.set_storage_url(fake, "http://files.example.com")

      assert {:error, %Error{code: "api_error", field: "attachments__0"} = error} =
               Emails.send(
                 name,
                 with_files([
                   %{filename: "a.pdf", content: @pdf},
                   %{filename: "logo.png", content: @logo}
                 ])
               )

      assert error.message =~ "a.pdf"
      assert error.fix =~ "https"
      refute inspect(error) =~ "files.example.com"
      assert nothing_sent?(fake)
    end

    @tag config: [
           api_client_module: PostHog.EmailsTest.ReqTestClient,
           app_host: "http://localhost:8010"
         ]
    test "uploads over plain HTTP when the app talks to PostHog over plain HTTP", %{
      name: name,
      fake: fake
    } do
      FakePostHog.set_storage_url(fake, "http://localhost:9000")

      assert {:ok, %Emails.SendResult{id: id}} =
               Emails.send(name, with_files([%{filename: "a.pdf", content: @pdf}]))

      assert FakePostHog.files(fake) == %{sha256(@pdf) => @pdf}
      assert [{^id, _email}] = FakePostHog.messages(fake)
    end

    test "leaves the size of an email without files to PostHog", %{test: test, fake: fake} do
      {:ok, server} =
        start_supervised({Bandit, plug: {&FakePostHog.serve/2, fake}, ip: :loopback, port: 0})

      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
      host = "http://127.0.0.1:#{port}"
      name = Module.concat(test, RealClient)

      config =
        PostHog.Config.validate!(
          api_host: host,
          app_host: host,
          api_key: "phc_project_key",
          secret_key: "phs_secret_key",
          supervisor_name: name,
          enable_local_evaluation: false
        )

      start_link_supervised!(Supervisor.child_spec({PostHog.Supervisor, config}, id: name))
      html = :binary.copy("a", 40_000_000)

      assert {:error, %Error{code: "message_too_large", status_code: 400}} =
               Emails.send(name, Keyword.put(@code_send, :html, html))

      assert [%{"html" => ^html, "subject" => "Hi"}] = FakePostHog.received(fake, :send)
      assert FakePostHog.messages(fake) == []
    end

    # With no subject and an empty body, these sizes leave 3, 73, 77, 147 and 151 bytes of the
    # 40 MB estimate free, and 29_182_876 none: PostHog counts a subject as 75 bytes per 42
    # started.
    for {label, subject, fits, refused} <- [
          {"of 42 ASCII bytes counts 75", String.duplicate("a", 42), 29_182_821, 29_182_824},
          {"of 43 bytes counts 150", String.duplicate("a", 43), 29_182_767, 29_182_770},
          {"of 21 two-byte characters counts 75", String.duplicate("é", 21), 29_182_821,
           29_182_824},
          {"that is empty counts nothing", "", 29_182_875, 29_182_876}
        ] do
      test "a subject #{label} toward the 40 MB estimate", %{name: name, fake: fake} do
        send_file = fn size ->
          Emails.send(
            name,
            Keyword.merge(@code_send,
              subject: unquote(subject),
              html: "",
              attachments: [%{filename: "a", content: :binary.copy(<<0>>, size)}]
            )
          )
        end

        assert {:error, %Error{code: "message_too_large"}} = send_file.(unquote(refused))
        assert nothing_sent?(fake)

        FakePostHog.put_files(fake, [:binary.copy(<<0>>, unquote(fits))])

        assert {:ok, _} = send_file.(unquote(fits))
        assert [{_id, _email}] = FakePostHog.messages(fake)
      end
    end

    test "refuses an attachment it can't send, naming the field", %{name: name, fake: fake} do
      for {attachments, field} <- [
            {%{filename: "a.txt", content: "a"}, "attachments"},
            {"invoice.pdf", "attachments"},
            {[[filename: "a.txt", content: "a"]], "attachments__0"},
            {[%{filename: "a.txt", content: "a"}, "b.txt"], "attachments__1"},
            {[%{filename: "a.txt", path: "/tmp/a.txt"}], "attachments__0__path"},
            {[%{filename: "a.txt", content: "a", cid: "logo"}], "attachments__0__cid"},
            {[%{"filename" => "a.txt", "content" => "a"}], "attachments__0__content"},
            {[%{filename: "a.txt"}], "attachments__0__content"},
            {[%{filename: "a.txt", content: ""}], "attachments__0__content"},
            {[%{filename: "a.txt", content: [97]}], "attachments__0__content"},
            {[%{filename: "a.txt", content: <<1::3>>}], "attachments__0__content"},
            {[%{content: "a"}], "attachments__0__filename"},
            {[%{filename: "", content: "a"}], "attachments__0__filename"},
            {[%{filename: " ", content: "a"}], "attachments__0__filename"},
            {[%{filename: :a, content: "a"}], "attachments__0__filename"},
            {[%{filename: "a.txt", content: "a", content_type: :pdf}],
             "attachments__0__content_type"},
            {[%{filename: "a.txt", content: "a", content_id: 1}], "attachments__0__content_id"}
          ] do
        assert {:error,
                %Error{code: "invalid_attachment", name: :validation_error, field: ^field}} =
                 Emails.send(name, with_files(attachments))
      end

      assert nothing_sent?(fake)
    end

    test "asks for atom keys when an attachment has string keys", %{name: name, fake: fake} do
      assert {:error,
              %Error{code: "invalid_attachment", field: "attachments__0__content"} = error} =
               Emails.send(name, with_files([%{"filename" => "a.txt", "content" => "a"}]))

      assert error.message =~ ~s(:content, not "content")

      assert {:error, %Error{field: "attachments__0__content"}} =
               Emails.send(
                 name,
                 with_files([%{"filename" => "a.txt", "content" => "a", "cid" => "logo"}])
               )

      assert nothing_sent?(fake)
    end

    test "refuses an attachment key that has no string form", %{name: name, fake: fake} do
      attachment = %{{:extra, :field} => true, filename: "a.txt", content: "a"}

      assert {:error, %Error{code: "invalid_attachment", field: "attachments__0"} = error} =
               Emails.send(name, with_files([attachment]))

      assert error.message =~ "{:extra, :field}"
      assert nothing_sent?(fake)
    end

    test "a path points to reading the file", %{name: name} do
      assert {:error, %Error{message: message}} =
               Emails.send(name, with_files([%{filename: "a.pdf", path: "/srv/a.pdf"}]))

      assert message =~ "File.read"
    end

    test "never repeats the file's content in an error", %{name: name} do
      assert {:error, %Error{} = error} =
               Emails.send(name, with_files([%{filename: 1, content: "SECRET-FILE-BYTES"}]))

      refute inspect(error) =~ "SECRET-FILE-BYTES"
    end

    test "returns a send's refusal of a file that expired after its upload request", %{
      name: name,
      fake: fake
    } do
      FakePostHog.put_files(fake, [@pdf])
      FakePostHog.hold_next(fake, :send)

      sending =
        Task.async(fn -> Emails.send(name, with_files([%{filename: "a.pdf", content: @pdf}])) end)

      assert_receive {:held, :send, request}
      FakePostHog.delete_file(fake, @pdf)
      send(request, :release)

      assert {:error,
              %Error{
                code: "attachment_not_uploaded",
                field: "attachments__0__sha256",
                status_code: 400
              }} = Task.await(sending)

      assert FakePostHog.messages(fake) == []
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
      assert {:error,
              %Error{
                code: "invalid_form",
                field: "headers",
                fix: "Remove headers and send again."
              }} =
               Emails.send(name,
                 to: "user@example.com",
                 template_id: @template_id,
                 headers: %{"X-Campaign" => "welcome"}
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

    test "does not retry a monthly quota, a conflict or a suppressed recipient", %{name: name} do
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

defmodule PostHog.EmailsReqDefaultsTest do
  # Req.default_options is app-wide, so this runs alone, after the async tests.
  use ExUnit.Case, async: false

  alias PostHog.Emails
  alias PostHog.EmailsTest.FakePostHog

  setup {Req.Test, :verify_on_exit!}

  setup context do
    previous = Application.fetch_env(:req, :default_options)

    # Defaults an app might set for its own requests. The storage refuses either on an upload, as
    # S3 does on a presigned PUT: a query that isn't the signed one, and gzipped bytes that no
    # longer match the signed checksum.
    Application.put_env(:req, :default_options, params: [app: "1"], compress_body: true)

    on_exit(fn ->
      case previous do
        {:ok, options} -> Application.put_env(:req, :default_options, options)
        :error -> Application.delete_env(:req, :default_options)
      end
    end)

    config =
      [
        api_host: "https://us.i.posthog.com",
        api_key: "phc_project_key",
        secret_key: "phs_secret_key",
        # The local storage is plain HTTP, which an app on a plain-HTTP PostHog may upload to.
        app_host: "http://localhost:8010",
        api_client_module: PostHog.EmailsTest.ReqTestClient,
        supervisor_name: context.test,
        enable_local_evaluation: false
      ]
      |> PostHog.Config.validate!()
      # The installed Req's default adapter over a real socket: Req.Test's plug would unzip a body.
      |> Map.put(:email_upload_adapter, :none)

    start_link_supervised!({PostHog.Supervisor, config})
    %{name: context.test, fake: FakePostHog.start!()}
  end

  test "an upload ignores the app's Req defaults", %{name: name, fake: fake} do
    {:ok, server} =
      start_supervised({Bandit, plug: {&FakePostHog.serve/2, fake}, ip: :loopback, port: 0})

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    FakePostHog.set_storage_url(fake, "http://127.0.0.1:#{port}")
    file = "file bytes"

    assert {:ok, %Emails.SendResult{id: id}} =
             Emails.send(name,
               to: "user@example.com",
               template_key: "receipt",
               subject: "Hi",
               html: "<p/>",
               attachments: [%{filename: "a.txt", content: file}]
             )

    sha256 = :crypto.hash(:sha256, file) |> Base.encode16(case: :lower)
    assert FakePostHog.files(fake) == %{sha256 => file}
    assert [{^id, %{"attachments" => [%{"sha256" => ^sha256}]}}] = FakePostHog.messages(fake)
  end
end
