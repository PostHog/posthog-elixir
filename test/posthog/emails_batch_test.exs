defmodule PostHog.EmailsBatchTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Mox

  alias PostHog.API
  alias PostHog.Emails
  alias PostHog.Emails.BatchError
  alias PostHog.Emails.Error

  setup :verify_on_exit!

  @batch_url "https://us.posthog.com/api/messaging/send/email_batch/"
  @template_id "0190f6d2-7c1e-7b3a-9f5e-1c2d3e4f5a6b"

  setup context do
    Mox.stub_with(API.Mock, API.Stub)
    test_pid = self()

    stub(API.Mock, :request, fn client, method, url, opts ->
      send(test_pid, {:request, method, url, opts})
      API.Stub.request(client, method, url, opts)
    end)

    config =
      [
        api_host: "https://us.i.posthog.com",
        api_key: "phc_project_key",
        secret_key: "phs_secret_key",
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
    %{name: context.test, config: config}
  end

  defp answers(replies) do
    test_pid = self()

    for reply <- replies do
      expect(API.Mock, :request, fn _client, method, url, opts ->
        send(test_pid, {:request, method, url, opts})
        reply_to(reply, opts)
      end)
    end
  end

  defp reply_to(reply, opts) when is_function(reply, 1), do: reply.(opts)
  defp reply_to(reply, _opts), do: reply

  defp requested do
    receive do
      {:request, method, url, opts} -> [{method, url, opts} | requested()]
    after
      0 -> []
    end
  end

  defp batch_bodies(requests),
    do: for({:post, @batch_url, opts} <- requests, do: Jason.decode!(opts[:body]))

  defp reads(requests), do: for({:get, url, _opts} <- requests, do: url)

  defp assert_resend_with_same_key(results) do
    for %{status: "unconfirmed", error: error} <- results do
      assert error.fix =~
               "unchanged, with the same idempotency_key within 24 hours of the key's first use"
    end
  end

  defp queued(message_id, replayed \\ false),
    do: %{"message_id" => message_id, "status" => "queued", "replayed" => replayed}

  defp refused(message_id, code, status \\ 422, retryable \\ false) do
    %{
      "message_id" => message_id,
      "error" => %{
        "code" => code,
        "detail" => "Refused: #{code}.",
        "status" => status,
        "retryable" => retryable
      }
    }
  end

  defp ok(slots, fields \\ %{}),
    do: {:ok, %{status: 200, headers: %{}, body: Map.put(fields, "results", slots)}}

  defp all_queued(opts) do
    opts[:body]
    |> Jason.decode!()
    |> Map.fetch!("recipients")
    |> Enum.map(&queued("msg_" <> &1["idempotency_key"]))
    |> ok()
  end

  defp queued_with_warning(opts) do
    {:ok, reply} = all_queued(opts)
    warning = %{"code" => "sandbox_sender", "detail" => "Sent from the test sender."}
    {:ok, put_in(reply.body["warnings"], [warning, warning])}
  end

  defp whole_call(status, code, headers \\ %{}) do
    body = if code, do: %{"type" => "invalid_request", "code" => code, "detail" => "Nope."}
    {:ok, %{status: status, headers: headers, body: body}}
  end

  defp lost, do: {:error, %Req.TransportError{reason: :econnreset}}

  defp raises(_opts), do: raise("The client failed.")

  defp held(reply) do
    test_pid = self()

    expect(API.Mock, :request, fn _client, method, url, opts ->
      send(test_pid, {:request, method, url, opts})
      send(test_pid, {:requesting, self()})

      receive do
        :release -> reply_to(reply, opts)
      end
    end)
  end

  defp recipients(count, extra \\ %{}) do
    for index <- 0..(count - 1) do
      Map.merge(%{to: "user#{index}@example.com", idempotency_key: "key-#{index}"}, extra)
    end
  end

  defp batch(name, people, overrides \\ []),
    do:
      Emails.batch(
        name,
        Keyword.merge([recipients: people, template_id: @template_id], overrides)
      )

  defp statuses(results), do: Enum.map(results, & &1.status)

  describe "batch/2 forms" do
    test "a template batch posts one request with a result per recipient", %{name: name} do
      answers([
        ok([queued("m0"), queued("m1", true), refused("m2", "recipient_suppressed")])
      ])

      assert {:ok, %Emails.BatchResult{results: results, warnings: []}} =
               batch(
                 name,
                 [
                   %{to: "a@example.com", idempotency_key: "welcome:a", distinct_id: "a"},
                   %{to: "b@example.com", template_data: %{name: "Bea"}},
                   %{to: "c@example.com", idempotency_key: "welcome:c"}
                 ],
                 template_id: String.upcase(@template_id),
                 template_data: %{name: "friend", plan: "pro"}
               )

      assert [{:post, @batch_url, opts}] = requested()

      assert List.keyfind(opts[:headers], "authorization", 0) ==
               {"authorization", "Bearer phs_secret_key"}

      assert List.keyfind(opts[:headers], "content-type", 0) ==
               {"content-type", "application/json"}

      assert List.keyfind(opts[:headers], "idempotency-key", 0) == nil

      body = Jason.decode!(opts[:body])
      generated = get_in(body, ["recipients", Access.at(1), "idempotency_key"])

      assert body == %{
               "template_id" => @template_id,
               "message_data" => %{"name" => "friend", "plan" => "pro"},
               "recipients" => [
                 %{
                   "to" => "a@example.com",
                   "idempotency_key" => "welcome:a",
                   "distinct_id" => "a"
                 },
                 %{
                   "to" => "b@example.com",
                   "idempotency_key" => generated,
                   "message_data" => %{"name" => "Bea"}
                 },
                 %{"to" => "c@example.com", "idempotency_key" => "welcome:c"}
               ]
             }

      assert generated =~
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

      assert Enum.map(results, & &1.index) == [0, 1, 2]
      assert Enum.map(results, & &1.idempotency_key) == ["welcome:a", generated, "welcome:c"]

      assert Enum.map(results, &{&1.status, &1.message_id, &1.replayed}) == [
               {"queued", "m0", false},
               {"queued", "m1", true},
               {"failed", "m2", false}
             ]

      assert %Error{code: "recipient_suppressed", status_code: 422, message_id: "m2"} =
               Enum.at(results, 2).error

      assert Enum.at(results, 2).to == "c@example.com"
    end

    test "a code batch sends the same content to every recipient", %{name: name} do
      answers([&all_queued/1])

      assert {:ok, %Emails.BatchResult{results: results}} =
               Emails.batch(name,
                 recipients: recipients(2),
                 template_key: "launch-news",
                 subject: "We launched",
                 html: "<p>Hi</p>",
                 from: "Acme <news@example.com>",
                 tracking: false
               )

      assert batch_bodies(requested()) == [
               %{
                 "template_key" => "launch-news",
                 "subject" => "We launched",
                 "html" => "<p>Hi</p>",
                 "from" => "Acme <news@example.com>",
                 "tracking" => false,
                 "recipients" => [
                   %{"to" => "user0@example.com", "idempotency_key" => "key-0"},
                   %{"to" => "user1@example.com", "idempotency_key" => "key-1"}
                 ]
               }
             ]

      assert statuses(results) == ["queued", "queued"]
    end

    test "takes its options and each recipient as a map or a keyword list", %{name: name} do
      answers([&all_queued/1])

      assert {:ok, %Emails.BatchResult{results: [_first, _second]}} =
               Emails.batch(name, %{
                 template_id: @template_id,
                 recipients: [
                   [to: "a@example.com", idempotency_key: "key-a", distinct_id: nil],
                   %{to: "b@example.com", idempotency_key: "key-b"}
                 ]
               })

      assert [%{"recipients" => [first, _second]}] = batch_bodies(requested())
      assert first == %{"to" => "a@example.com", "idempotency_key" => "key-a"}
    end
  end

  describe "batch/2 argument checks" do
    @code_form [template_key: "k", subject: "s", html: "h"]

    test "refuses an improper list of recipients as not a list", %{name: name} do
      assert {:error, %Error{code: "invalid_recipients", field: "recipients"} = error} =
               batch(name, [%{to: "a@example.com"} | :bad_tail])

      assert error.message =~ "must be a list"
      assert requested() == []
    end

    test "says to give each recipient its own key for a top-level idempotency_key", %{name: name} do
      assert {:error, %Error{field: "idempotency_key"} = error} =
               batch(name, recipients(2), idempotency_key: "shared")

      assert error.fix =~ "its own idempotency_key"
      refute error.fix =~ "Move"
      assert requested() == []
    end

    for {label, overrides, code, field} <- [
          {"scheduled_at", [scheduled_at: "2026-12-01T09:00:00Z"], "invalid_form",
           "scheduled_at"},
          {"cc", [cc: "x@example.com"], "invalid_form", "cc"},
          {"bcc", [bcc: "x@example.com"], "invalid_form", "bcc"},
          {"attachments", [attachments: [%{filename: "a.txt", content: "a"}]], "invalid_form",
           "attachments"},
          {"a top-level to", [to: "x@example.com"], "invalid_form", "to"},
          {"no recipients", [recipients: []], "invalid_recipients", "recipients"},
          {"missing recipients", [recipients: nil], "invalid_recipients", "recipients"},
          {"recipients not a list", [recipients: "a@example.com"], "invalid_recipients",
           "recipients"},
          {"a recipient not a map", [recipients: ["a@example.com"]], "invalid_recipient",
           "recipients__0"},
          {"a recipient without to", [recipients: [%{distinct_id: "a"}]], "invalid_recipient",
           "recipients__0__to"},
          {"a recipient with a blank to", [recipients: [%{to: " "}]], "invalid_recipient",
           "recipients__0__to"},
          {"a recipient with a field that is not a name",
           [recipients: [%{{:a, 1} => 1, to: "a@example.com"}]], "invalid_form",
           "recipients__0__{:a, 1}"},
          {"a recipient with an unknown field",
           [recipients: [%{to: "a@example.com", cc: "b@example.com"}]], "invalid_form",
           "recipients__0__cc"},
          {"a recipient with a bad key",
           [recipients: [%{to: "a@example.com", idempotency_key: "has space"}]],
           "invalid_idempotency_key", "recipients__0__idempotency_key"},
          {"a recipient's template_data not a map",
           [recipients: [%{to: "a@example.com", template_data: [1]}]], "invalid_template_data",
           "recipients__0__template_data"},
          {"a recipient's template_data that is not JSON",
           [recipients: [%{to: "a@example.com", template_data: %{at: {1, 2}}}]],
           "invalid_template_data", "recipients__0__template_data"},
          {"both forms", [template_key: "k", subject: "s", html: "h"], "invalid_form", nil}
        ] do
      test "refuses #{label} before any request", %{name: name} do
        assert {:error, %Error{code: unquote(code), field: unquote(field)} = error} =
                 batch(name, recipients(1), unquote(Macro.escape(overrides)))

        assert error.name == :validation_error
        assert requested() == []
      end
    end

    for {label, overrides, field} <- [
          {"cc", [cc: "x@example.com"], "cc"},
          {"bcc", [bcc: "x@example.com"], "bcc"},
          {"attachments", [attachments: [%{filename: "a.txt", content: "a"}]], "attachments"},
          {"scheduled_at", [scheduled_at: "2026-12-01T09:00:00Z"], "scheduled_at"}
        ] do
      test "refuses #{label} in a code batch", %{name: name} do
        assert {:error, %Error{code: "invalid_form", field: unquote(field)} = error} =
                 Emails.batch(
                   name,
                   [recipients: recipients(1)] ++ @code_form ++ unquote(Macro.escape(overrides))
                 )

        assert error.why =~ "A batch takes no scheduled_at, cc, bcc or attachments"
        assert requested() == []
      end
    end

    test "refuses a code field in a template batch for what it is", %{name: name} do
      assert {:error, %Error{code: "invalid_form", field: "subject"} = error} =
               batch(name, recipients(1), subject: "Hi")

      assert error.why =~ "A template made in PostHog sets its own"
      refute error.why =~ "scheduled_at"
      assert requested() == []
    end

    test "refuses template_data on a recipient of a code batch", %{name: name} do
      assert {:error, %Error{code: "invalid_form", field: "recipients__0__template_data"} = error} =
               Emails.batch(
                 name,
                 [recipients: [%{to: "a@example.com", template_data: %{a: 1}}]] ++ @code_form
               )

      assert error.message =~ "template_id batch"
      assert requested() == []
    end

    test "refuses a code batch without content", %{name: name} do
      assert {:error, %Error{code: "invalid_form", field: "html"}} =
               Emails.batch(name,
                 recipients: recipients(1),
                 template_key: "digest",
                 subject: "Hi"
               )

      assert requested() == []
    end

    test "names both positions of a repeated idempotency key", %{name: name} do
      people = List.update_at(recipients(3), 2, &%{&1 | idempotency_key: "key-0"})

      assert {:error,
              %Error{code: "invalid_idempotency_key", field: "recipients__2__idempotency_key"} =
                error} = batch(name, people)

      assert error.message =~ ~r/recipients\[2\].*recipients\[0\]/
      assert requested() == []
    end

    test "names the position of a bad recipient", %{name: name} do
      people = List.update_at(recipients(3), 1, &%{&1 | to: ""})

      assert {:error, %Error{code: "invalid_recipient", field: "recipients__1__to"} = error} =
               batch(name, people)

      assert error.message =~ "recipients[1]"
    end

    test "a client that is not running sends nothing" do
      assert {:error, %Error{code: "client_disabled"}} = batch(:not_started, recipients(1))
      assert requested() == []
    end

    @tag config: [api_host: "https://proxy.example.com"]
    test "a client off PostHog Cloud without an app host sends nothing", %{name: name} do
      assert {:error, %Error{code: "missing_app_host"}} = batch(name, recipients(1))
      assert requested() == []
    end
  end

  describe "batch/2 requests" do
    for {label, extra} <- [
          {"", quote(do: %{})},
          {" of more than 4 MiB",
           quote(do: %{template_data: %{"note" => String.duplicate("a", 45_000)}})}
        ] do
      test "sends 100 recipients#{label} in one request", %{name: name} do
        answers([&all_queued/1])

        assert {:ok, %Emails.BatchResult{results: results}} =
                 batch(name, recipients(100, unquote(extra)))

        assert [{:post, @batch_url, opts}] = requested()
        assert byte_size(opts[:body]) > byte_size(Jason.encode!(unquote(extra))) * 100
        assert length(Jason.decode!(opts[:body])["recipients"]) == 100
        assert Enum.map(results, & &1.message_id) == Enum.map(0..99, &"msg_key-#{&1}")
      end
    end

    test "refuses more than 100 recipients before any request", %{name: name} do
      assert {:error, %Error{code: "invalid_recipients", field: "recipients"} = error} =
               batch(name, recipients(101))

      assert error.name == :validation_error
      assert error.fix =~ "batches of 100 or fewer"
      assert requested() == []
    end

    for {label, body, fix} <- [
          {"with PostHog's fix",
           %{
             "type" => "invalid_request",
             "code" => "content_too_large",
             "detail" => "The batch is larger than PostHog can send at once.",
             "fix" => "Split the recipients into smaller batches."
           }, "Split the recipients into smaller batches."},
          {"without a body", nil,
           "Split the recipients into smaller batches, and keep each email and its idempotency_key unchanged."},
          {"with a code and fix that aren't text", %{"code" => 13, "fix" => false},
           "Split the recipients into smaller batches, and keep each email and its idempotency_key unchanged."},
          {"with an empty code and fix", %{"code" => "", "fix" => ""},
           "Split the recipients into smaller batches, and keep each email and its idempotency_key unchanged."}
        ] do
      test "a 413 #{label} comes back as the error, with a fix to split the batch", %{name: name} do
        answers([{:ok, %{status: 413, headers: %{}, body: unquote(Macro.escape(body))}}])

        assert {:error,
                %BatchError{code: "content_too_large", status_code: 413, results: results} = error} =
                 batch(name, recipients(2))

        assert error.fix == unquote(fix)
        assert length(requested()) == 1
        assert statuses(results) == ["failed", "failed"]
      end
    end

    for {label, body} <- [
          {"without a body", nil},
          {"with PostHog's split fix",
           %{
             "type" => "invalid_request",
             "code" => "content_too_large",
             "detail" => "The batch is larger than PostHog can send at once.",
             "fix" => "Split the recipients into smaller batches."
           }}
        ] do
      test "a 413 #{label} for one recipient says to make the email smaller", %{name: name} do
        answers([{:ok, %{status: 413, headers: %{}, body: unquote(Macro.escape(body))}}])

        assert {:error, %BatchError{code: "content_too_large", results: [result]} = error} =
                 batch(name, recipients(1))

        for fix <- [error.fix, result.error.fix] do
          assert fix =~ "Make the email smaller"
          refute fix =~ "Split"
        end
      end
    end

    test "after a lost answer, a 413 for one recipient says only to resend unchanged", %{
      name: name
    } do
      answers([lost(), {:ok, %{status: 413, headers: %{}, body: nil}}])

      assert {:error, %BatchError{code: "content_too_large", results: [result]} = error} =
               batch(name, recipients(1), max_retries: 1)

      assert result.status == "unconfirmed"

      for fix <- [error.fix, result.error.fix] do
        assert fix =~ "unchanged, with the same idempotency_key"
        refute fix =~ "smaller"
        refute fix =~ "If PostHog refuses it again"
      end
    end

    test "after a lost answer, a 400 content_too_large keeps PostHog's words", %{name: name} do
      detail = "The content shared by every recipient can be at most 256 KiB."

      answers([
        lost(),
        {:ok,
         %{
           status: 400,
           headers: %{},
           body: %{"type" => "invalid_request", "code" => "content_too_large", "detail" => detail}
         }}
      ])

      assert {:error, %BatchError{code: "content_too_large", results: [first, _second]} = error} =
               batch(name, recipients(2), max_retries: 1)

      assert error.message =~ detail
      assert first.error.message =~ detail
      assert first.status == "unconfirmed"
    end

    test "a 400 content_too_large for shared content keeps PostHog's words and no split advice",
         %{name: name} do
      detail =
        "The content or `message_data` that a batch sends to every recipient can be at most 256 KiB. Send larger emails one at a time."

      body = %{"type" => "invalid_request", "code" => "content_too_large", "detail" => detail}
      answers([{:ok, %{status: 400, headers: %{}, body: body}}])

      assert {:error,
              %BatchError{code: "content_too_large", status_code: 400, results: results} = error} =
               batch(name, recipients(2))

      assert error.message == detail
      refute (error.fix || "") =~ "Split"
      assert length(requested()) == 1
      assert statuses(results) == ["failed", "failed"]
    end

    @tag config: [email_request_timeout_ms: 50]
    test "waits for a slow answer whatever the client's timeout", %{name: name} do
      expect(API.Mock, :request, fn _client, :post, @batch_url, opts ->
        Process.sleep(200)
        all_queued(opts)
      end)

      assert {:ok, %Emails.BatchResult{results: [%{status: "queued"}]}} =
               batch(name, recipients(1))
    end

    test "gives each request at least 45 seconds", %{name: name} do
      answers([&all_queued/1])

      assert {:ok, _result} = batch(name, recipients(1))
      assert [{:post, @batch_url, opts}] = requested()
      assert opts[:receive_timeout] == 45_000
    end

    @tag config: [email_request_timeout_ms: 60_000]
    test "a longer client timeout applies to a batch too", %{name: name} do
      answers([&all_queued/1])

      assert {:ok, _result} = batch(name, recipients(1))
      assert [{:post, @batch_url, opts}] = requested()
      assert opts[:receive_timeout] == 60_000
    end
  end

  describe "batch/2 recipient results" do
    for {label, earlier} <- [
          {"a lost answer", quote(do: lost())},
          {"a 503", quote(do: whole_call(503, "delivery_unavailable"))}
        ] do
      test "a refusal of the retry after #{label} leaves the email unconfirmed", %{name: name} do
        answers([
          unquote(earlier),
          ok([queued("m0", true), refused("m1", "recipient_suppressed")])
        ])

        assert {:ok, %Emails.BatchResult{results: [first, second] = results}} =
                 batch(name, recipients(2))

        assert [{:post, _, attempt}, {:post, _, retry}] = requested()
        assert attempt[:body] == retry[:body]
        assert {first.status, first.message_id, first.replayed} == {"queued", "m0", true}
        assert {second.status, second.message_id} == {"unconfirmed", "m1"}
        assert %Error{code: "recipient_suppressed"} = second.error
        assert second.error.message =~ "may still go out"
        assert_resend_with_same_key(results)
      end
    end

    test "a refusal without an earlier lost answer is failed", %{name: name} do
      answers([ok([refused("m0", "recipient_suppressed")])])

      assert {:ok, %Emails.BatchResult{results: [result]}} = batch(name, recipients(1))

      assert result.status == "failed"
      assert %Error{code: "recipient_suppressed"} = result.error
    end

    test "a batch that succeeds leaves an unconfirmed email to resend with its key", %{name: name} do
      in_flight = refused(nil, "idempotency_key_in_flight", 409, true)

      answers([ok([queued("m0"), in_flight, in_flight])])

      assert {:ok, %Emails.BatchResult{results: results}} = batch(name, recipients(3))

      assert reads(requested()) == []
      assert statuses(results) == ["queued", "unconfirmed", "unconfirmed"]
      assert Enum.map(results, & &1.message_id) == ["m0", nil, nil]
      assert Enum.map(results, & &1.idempotency_key) == ["key-0", "key-1", "key-2"]
      assert_resend_with_same_key(results)
    end

    for {code, status} <- [{"delivery_unavailable", 503}, {"idempotency_key_in_flight", 409}] do
      test "a recipient answered #{code} is unconfirmed", %{name: name} do
        answers([ok([refused("m0", unquote(code), unquote(status), true)])])

        assert {:ok, %Emails.BatchResult{results: [result]}} = batch(name, recipients(1))

        assert {result.status, result.message_id} == {"unconfirmed", "m0"}
        assert %Error{code: unquote(code), status_code: unquote(status)} = result.error
      end
    end

    test "a recipient answered without a readable result is unconfirmed", %{name: name} do
      answers([ok(["not a result"])])

      assert {:ok, %Emails.BatchResult{results: [result]}} = batch(name, recipients(1))

      assert result.status == "unconfirmed"
      assert %Error{code: "api_error"} = result.error
    end
  end

  describe "batch/2 when a request fails as a whole" do
    test "returns every recipient's result", %{name: name} do
      answers([whole_call(429, "quota_limited")])

      assert {:error, %BatchError{} = error} = batch(name, recipients(3))

      assert {error.code, error.status_code, error.name} ==
               {"quota_limited", 429, :monthly_quota_exceeded}

      assert length(requested()) == 1
      assert statuses(error.results) == ["failed", "failed", "failed"]
      assert %Error{code: "quota_limited", message: "Nope."} = Enum.at(error.results, 1).error
      assert Enum.at(error.results, 2).idempotency_key == "key-2"
      assert Exception.message(error) == "Nope."
    end

    test "after a lost answer leaves each email to resend with its key", %{name: name} do
      answers([lost(), lost(), lost()])

      assert {:error, %BatchError{code: "network_error", results: [first, second] = results}} =
               batch(name, recipients(2))

      assert reads(requested()) == []
      assert {first.status, first.message_id} == {"unconfirmed", nil}
      assert {second.status, second.message_id} == {"unconfirmed", nil}
      assert %Error{code: "delivery_unavailable"} = first.error
      assert_resend_with_same_key(results)
    end

    test "a 503 past its retries leaves the request unconfirmed", %{name: name} do
      answers(List.duplicate(whole_call(503, "delivery_unavailable"), 3))

      assert {:error, %BatchError{code: "delivery_unavailable", results: results}} =
               batch(name, recipients(3), max_retries: 2)

      assert length(requested()) == 3
      assert statuses(results) == List.duplicate("unconfirmed", 3)
      assert_resend_with_same_key(results)
    end

    for {label, status, code, earlier, then_fix} <- [
          {"a 429", 429, "throttled", [:lost], nil},
          {"a 409 in flight", 409, "idempotency_key_in_flight", [:lost], nil},
          {"a 400", 400, "invalid_form", [:lost], nil},
          {"a 413 without a body", 413, nil, [:lost], "Split the recipients"},
          {"a 404 without a body", 404, nil, [:lost], "PostHog.Emails.send/2"},
          {"a 409 batch_unavailable", 409, "batch_unavailable", [:lost], "PostHog.Emails.send/2"},
          {"a 429 after a 503", 429, "throttled", [:lost, 503], nil}
        ] do
      test "#{label} to a retry after a lost answer leaves the recipients unconfirmed",
           %{name: name} do
        earlier =
          Enum.map(unquote(earlier), fn
            :lost -> lost()
            503 -> whole_call(503, "delivery_unavailable")
          end)

        answers(earlier ++ [whole_call(unquote(status), unquote(code))])

        assert {:error, %BatchError{results: [first, _second] = results} = error} =
                 batch(name, recipients(2), max_retries: length(earlier))

        code = unquote(code) || %{413 => "content_too_large", 404 => "not_found"}[unquote(status)]
        assert {error.code, error.status_code} == {code, unquote(status)}
        assert statuses(results) == ["unconfirmed", "unconfirmed"]
        assert %Error{code: ^code, status_code: unquote(status)} = first.error

        for message <- [error.message, first.error.message],
            code != "idempotency_key_in_flight" do
          assert message =~ "PostHog refused a retry: "

          assert message =~
                   "PostHog didn't confirm an earlier try, so the email may still go out."

          refute message =~ "was lost"
          refute message =~ "no email was sent"
        end

        if code != "idempotency_key_in_flight", do: assert(error.fix == first.error.fix)

        for fragment <- List.wrap(unquote(then_fix)) do
          assert error.fix =~ "If PostHog refuses it again: "
          assert error.fix =~ fragment
        end

        refute (error.fix || "") =~ "content smaller"

        assert_resend_with_same_key(results)
      end
    end

    for {label, code} <- [{"without a body", nil}, {"coded api_error", "api_error"}] do
      test "a 429 #{label} fails the request and reads nothing", %{name: name} do
        answers([whole_call(429, unquote(code))])

        assert {:error, %BatchError{status_code: 429, results: results}} =
                 batch(name, recipients(2), max_retries: 0)

        assert statuses(results) == ["failed", "failed"]
        assert reads(requested()) == []
      end
    end

    test "keeps every result when the retries outlast the backoff's growth", %{name: name} do
      expect(API.Mock, :request, 1_101, fn _client, _method, _url, _opts ->
        whole_call(503, "delivery_unavailable")
      end)

      assert {:error, %BatchError{code: "delivery_unavailable", results: results}} =
               batch(name, recipients(2), max_retries: 1_100)

      assert statuses(results) == ["unconfirmed", "unconfirmed"]
    end

    test "an answer without a result per recipient leaves the request unconfirmed", %{name: name} do
      answers([ok([queued("m0")])])

      assert {:error, %BatchError{code: "api_error", status_code: 200, results: results}} =
               batch(name, recipients(2), max_retries: 0)

      assert statuses(results) == ["unconfirmed", "unconfirmed"]
      assert %Error{code: "api_error", status_code: 200} = hd(results).error
      assert_resend_with_same_key(results)
    end

    for {status, code} <- [{409, "idempotency_key_in_flight"}, {400, "api_error"}] do
      test "a request answered #{code} as a whole leaves it unconfirmed", %{name: name} do
        answers([whole_call(unquote(status), unquote(code))])

        assert {:error, %BatchError{code: unquote(code), results: results}} =
                 batch(name, recipients(2), max_retries: 0)

        assert statuses(results) == ["unconfirmed", "unconfirmed"]
        assert reads(requested()) == []
        assert_resend_with_same_key(results)
      end
    end

    test "an exception in the request leaves every recipient unconfirmed", %{name: name} do
      answers([&raises/1])

      capture_log(fn ->
        assert {:error, %BatchError{code: "unexpected_error", results: results}} =
                 batch(name, recipients(2))

        assert statuses(results) == ["unconfirmed", "unconfirmed"]
        assert Enum.at(results, 1).idempotency_key == "key-1"
      end)
    end

    test "batch_unavailable is not retried and says to send each email alone", %{name: name} do
      answers([whole_call(409, "batch_unavailable")])

      assert {:error, %BatchError{code: "batch_unavailable", results: results} = error} =
               batch(name, recipients(2))

      assert length(requested()) == 1

      assert error.fix ==
               "Until batch sends are on for the project, send each email the batch didn't queue with PostHog.Emails.send/2 and its recipient's idempotency_key."

      assert statuses(results) == ["failed", "failed"]
    end

    for body <- [
          nil,
          %{"type" => "invalid_request", "code" => "not_found", "detail" => "Not found."}
        ] do
      test "a 404 says batch sends are unavailable, answered #{inspect(body)}", %{name: name} do
        answers([{:ok, %{status: 404, headers: %{}, body: unquote(Macro.escape(body))}}])

        assert {:error, %BatchError{code: "not_found", name: :not_found} = error} =
                 batch(name, recipients(1))

        assert error.why =~ "batch sends"

        assert error.fix ==
                 "Check template_id, or send each email the batch didn't queue with PostHog.Emails.send/2 and its recipient's idempotency_key."
      end
    end

    test "names the recipient field PostHog refused", %{name: name} do
      answers([
        {:ok,
         %{
           status: 400,
           headers: %{},
           body: %{
             "type" => "validation_error",
             "code" => "max_length",
             "detail" => "Ensure this field has no more than 255 characters.",
             "attr" => "recipients__37__idempotency_key"
           }
         }}
      ])

      assert {:error, %BatchError{field: "recipients__37__idempotency_key", results: results}} =
               batch(name, recipients(50))

      assert statuses(results) == List.duplicate("failed", 50)
    end
  end

  describe "batch/2 when the instance stops" do
    test "sends nothing more through an instance restarted under its name", %{
      name: name,
      config: config
    } do
      held(whole_call(503, "delivery_unavailable"))

      sending = Task.async(fn -> batch(name, recipients(2)) end)
      assert_receive {:requesting, worker}
      stop_supervised!(name)
      start_link_supervised!({PostHog.Supervisor, config})
      send(worker, :release)

      assert {:error, %BatchError{code: "client_closed", results: results} = error} =
               Task.await(sending)

      assert error.message =~ "sent no further request"
      refute error.message =~ "wasn't sent"
      assert length(requested()) == 1
      assert statuses(results) == ["unconfirmed", "unconfirmed"]
    end

    @tag stop_instance_on_sleep: true
    test "sends no retry", %{name: name} do
      answers([whole_call(429, "throttled")])

      assert {:error, %BatchError{code: "client_closed", results: results} = error} =
               batch(name, recipients(2))

      assert error.message =~ "the batch wasn't sent"
      assert length(requested()) == 1
      assert statuses(results) == ["failed", "failed"]
      assert %Error{code: "throttled"} = hd(results).error
    end

    for {label, answer} <- [
          {"a lost answer", quote(do: lost())},
          {"an uncertain answer", quote(do: whole_call(503, "delivery_unavailable"))}
        ] do
      @tag stop_instance_on_sleep: true
      test "sends no retry after #{label} and says emails may have gone out", %{name: name} do
        answers([unquote(answer)])

        assert {:error, %BatchError{code: "client_closed", results: results} = error} =
                 batch(name, recipients(2))

        assert error.message =~ "sent no further request"
        refute error.message =~ "wasn't sent"
        assert length(requested()) == 1
        assert statuses(results) == ["unconfirmed", "unconfirmed"]
      end
    end
  end

  describe "batch/2 warnings" do
    test "reach the caller once and are logged once", %{name: name} do
      answers([&queued_with_warning/1])

      log =
        capture_log(fn ->
          assert {:ok, %Emails.BatchResult{warnings: [warning]}} = batch(name, recipients(2))

          assert warning == %Emails.Warning{
                   code: "sandbox_sender",
                   message: "Sent from the test sender."
                 }
        end)

      assert length(String.split(log, "PostHog email warning sandbox_sender")) == 2
    end
  end
end
