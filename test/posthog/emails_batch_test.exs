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
  @four_mib 4 * 1024 * 1024

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
    test "splits by 100 recipients and sends the requests in order", %{name: name} do
      answers([&all_queued/1, &all_queued/1, &all_queued/1])

      assert {:ok, %Emails.BatchResult{results: results}} = batch(name, recipients(250))

      assert Enum.map(batch_bodies(requested()), &length(&1["recipients"])) == [100, 100, 50]
      assert Enum.map(results, & &1.index) == Enum.to_list(0..249)
      assert Enum.map(results, & &1.message_id) == Enum.map(0..249, &"msg_key-#{&1}")
      assert Enum.all?(results, &(&1.status == "queued"))
    end

    test "splits by the 4 MiB body and fails only a recipient too large alone", %{name: name} do
      big = String.duplicate("x", div(@four_mib, 3))

      people =
        5
        |> recipients(%{template_data: %{note: big}})
        |> List.update_at(3, &%{&1 | template_data: %{note: String.duplicate("y", @four_mib)}})

      answers([&all_queued/1, &all_queued/1])

      assert {:ok, %Emails.BatchResult{results: results}} = batch(name, people)

      requests = requested()

      assert Enum.all?(requests, fn {_method, _url, opts} ->
               byte_size(opts[:body]) <= @four_mib
             end)

      assert Enum.map(batch_bodies(requests), fn body ->
               Enum.map(body["recipients"], & &1["idempotency_key"])
             end) == [["key-0", "key-1"], ["key-2", "key-4"]]

      assert statuses(results) == ["queued", "queued", "queued", "failed", "queued"]
      too_large = Enum.at(results, 3)
      assert %Error{code: "content_too_large", name: :validation_error} = too_large.error
      assert {too_large.message_id, too_large.idempotency_key} == {nil, "key-3"}
    end

    test "a request fills up to exactly 4 MiB", %{name: name} do
      base =
        byte_size(Jason.encode!(%{template_id: @template_id, message_data: %{}, recipients: []}))

      item =
        byte_size(
          Jason.encode!(%{to: "a@example.com", idempotency_key: "k1", message_data: %{n: ""}})
        )

      padding = @four_mib - base - 3 * item - 2
      third = div(padding, 3)

      people =
        for {key, size} <- [{"k1", third}, {"k2", third}, {"k3", padding - 2 * third}, {"k4", 0}],
            do: %{
              to: "a@example.com",
              idempotency_key: key,
              template_data: %{n: String.duplicate("a", size)}
            }

      answers([&all_queued/1, &all_queued/1])

      assert {:ok, _result} = batch(name, people)

      requests = requested()
      assert [{:post, @batch_url, opts} | _rest] = requests
      assert byte_size(opts[:body]) == @four_mib
      assert Enum.map(batch_bodies(requests), &length(&1["recipients"])) == [3, 1]
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
    test "a retry after a lost answer keeps a refused recipient unconfirmed", %{name: name} do
      answers([lost(), ok([queued("m0", true), refused("m1", "idempotency_key_reused")])])

      assert {:ok, %Emails.BatchResult{results: [first, second]}} = batch(name, recipients(2))

      assert [{:post, _, attempt}, {:post, _, retry}] = requested()
      assert attempt[:body] == retry[:body]
      assert {first.status, first.message_id, first.replayed} == {"queued", "m0", true}
      assert {second.status, second.message_id} == {"unconfirmed", "m1"}
      assert %Error{code: "delivery_unavailable", name: :service_unavailable} = second.error
      assert %Error{code: "idempotency_key_reused"} = second.later_error
    end

    test "a 503 and then a refusal also keeps the recipient unconfirmed", %{name: name} do
      answers([
        whole_call(503, "delivery_unavailable"),
        ok([refused("m0", "recipient_suppressed")])
      ])

      assert {:ok, %Emails.BatchResult{results: [result]}} = batch(name, recipients(1))

      assert result.status == "unconfirmed"
      assert %Error{code: "recipient_suppressed"} = result.later_error
    end

    test "a refusal without an earlier lost answer is failed", %{name: name} do
      answers([ok([refused("m0", "recipient_suppressed")])])

      assert {:ok, %Emails.BatchResult{results: [result]}} = batch(name, recipients(1))

      assert {result.status, result.later_error} == {"failed", nil}
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
    test "stops and returns every recipient's result", %{name: name} do
      answers([&all_queued/1, whole_call(429, "quota_limited")])

      assert {:error, %BatchError{} = error} = batch(name, recipients(250))

      assert {error.code, error.status_code, error.name} ==
               {"quota_limited", 429, :monthly_quota_exceeded}

      assert length(requested()) == 2

      assert statuses(error.results) ==
               List.duplicate("queued", 100) ++
                 List.duplicate("failed", 100) ++ List.duplicate("not_attempted", 50)

      assert %Error{code: "quota_limited", message: "Nope."} = Enum.at(error.results, 150).error
      assert %Error{code: "not_attempted"} = Enum.at(error.results, 200).error
      assert Enum.at(error.results, 249).idempotency_key == "key-249"
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

    for {status, code} <- [{429, "throttled"}, {409, "idempotency_key_in_flight"}] do
      test "#{code} after a lost answer keeps the first error and records the later one", %{
        name: name
      } do
        answers([lost(), whole_call(unquote(status), unquote(code))])

        assert {:error, %BatchError{code: unquote(code), results: [first, _second]}} =
                 batch(name, recipients(2), max_retries: 1)

        assert first.status == "unconfirmed"
        assert %Error{code: "delivery_unavailable"} = first.error
        assert %Error{code: unquote(code), status_code: unquote(status)} = first.later_error
      end
    end

    test "a lost retry keeps the last answer PostHog gave", %{name: name} do
      answers([lost(), whole_call(503, "service_unavailable"), lost()])

      assert {:error, %BatchError{results: [result]}} =
               batch(name, recipients(1), max_retries: 2)

      assert %Error{code: "delivery_unavailable"} = result.error
      assert %Error{code: "service_unavailable", status_code: 503} = result.later_error
    end

    test "an answer without a result per recipient after a lost answer is the later one", %{
      name: name
    } do
      answers([lost(), ok([])])

      assert {:error, %BatchError{code: "api_error", results: [result]}} =
               batch(name, recipients(1), max_retries: 1)

      assert %Error{code: "delivery_unavailable"} = result.error
      assert %Error{code: "api_error", status_code: 200} = result.later_error
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
      assert Enum.map(results, & &1.later_error) == [nil, nil]
      assert reads(requested()) == []
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

    test "a request in flight past its retries stays unconfirmed after a refusal", %{name: name} do
      answers([whole_call(409, "idempotency_key_in_flight"), whole_call(429, "throttled")])

      assert {:error, %BatchError{code: "throttled", results: results}} =
               batch(name, recipients(2), max_retries: 1)

      assert statuses(results) == ["unconfirmed", "unconfirmed"]
      assert Enum.map(results, & &1.later_error.code) == ["throttled", "throttled"]
      assert %Error{code: "idempotency_key_in_flight"} = hd(results).error
    end

    test "an exception in a later request keeps every result", %{name: name} do
      answers([&all_queued/1, &raises/1])

      capture_log(fn ->
        assert {:error, %BatchError{code: "unexpected_error", results: results}} =
                 batch(name, recipients(201))

        assert statuses(results) ==
                 List.duplicate("queued", 100) ++
                   List.duplicate("unconfirmed", 100) ++ ["not_attempted"]

        assert Enum.at(results, 150).idempotency_key == "key-150"
      end)

      assert reads(requested()) == []
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

    for {attr, field} <- [
          {"recipients__37__idempotency_key", "recipients__137__idempotency_key"},
          {"recipients__49", "recipients__149"},
          {"recipients__²__idempotency_key", "recipients__²__idempotency_key"},
          {"recipients__50__to", "recipients"},
          {"recipients__" <> String.duplicate("9", 5000) <> "__idempotency_key", "recipients"},
          {"template_id", "template_id"}
        ] do
      test "names the position in recipients of a refused field #{String.slice(attr, 0, 40)}",
           %{name: name} do
        answers([
          &all_queued/1,
          {:ok,
           %{
             status: 400,
             headers: %{},
             body: %{
               "type" => "validation_error",
               "code" => "max_length",
               "detail" => "Ensure this field has no more than 255 characters.",
               "attr" => unquote(attr)
             }
           }}
        ])

        assert {:error, %BatchError{field: unquote(field), results: results}} =
                 batch(name, recipients(150))

        assert statuses(results) == List.duplicate("queued", 100) ++ List.duplicate("failed", 50)
      end
    end
  end

  describe "batch/2 when the instance stops" do
    test "stops before the next request", %{name: name} do
      held(&all_queued/1)

      sending = Task.async(fn -> batch(name, recipients(150)) end)
      assert_receive {:requesting, worker}
      stop_supervised!(name)
      send(worker, :release)

      assert {:error, %BatchError{code: "client_closed", results: results} = error} =
               Task.await(sending)

      assert error.message =~ "the rest of the batch wasn't sent"
      assert length(requested()) == 1

      assert statuses(results) ==
               List.duplicate("queued", 100) ++ List.duplicate("not_attempted", 50)

      assert %Error{code: "client_closed"} = Enum.at(results, 100).error
    end

    test "sends nothing more through an instance restarted under its name", %{
      name: name,
      config: config
    } do
      held(&all_queued/1)

      sending = Task.async(fn -> batch(name, recipients(150)) end)
      assert_receive {:requesting, worker}
      stop_supervised!(name)
      start_link_supervised!({PostHog.Supervisor, config})
      send(worker, :release)

      assert {:error, %BatchError{code: "client_closed", results: results}} =
               Task.await(sending)

      assert length(requested()) == 1

      assert statuses(results) ==
               List.duplicate("queued", 100) ++ List.duplicate("not_attempted", 50)
    end

    @tag stop_instance_on_sleep: true
    test "sends no retry", %{name: name} do
      answers([whole_call(429, "throttled")])

      assert {:error, %BatchError{code: "client_closed", results: results}} =
               batch(name, recipients(150))

      assert length(requested()) == 1

      assert statuses(results) ==
               List.duplicate("failed", 100) ++ List.duplicate("not_attempted", 50)

      assert %Error{code: "client_closed"} = Enum.at(results, 0).error
    end

    @tag stop_instance_on_sleep: true
    test "sends no retry after an uncertain answer", %{name: name} do
      answers([whole_call(503, "delivery_unavailable")])

      assert {:error, %BatchError{code: "client_closed", results: results}} =
               batch(name, recipients(2))

      assert length(requested()) == 1
      assert statuses(results) == ["unconfirmed", "unconfirmed"]
    end
  end

  describe "batch/2 warnings" do
    test "reach the caller once and are logged once", %{name: name} do
      answers([&queued_with_warning/1, &queued_with_warning/1])

      log =
        capture_log(fn ->
          assert {:ok, %Emails.BatchResult{warnings: [warning]}} = batch(name, recipients(150))

          assert warning == %Emails.Warning{
                   code: "sandbox_sender",
                   message: "Sent from the test sender."
                 }
        end)

      assert length(String.split(log, "PostHog email warning sandbox_sender")) == 2
    end

    test "reach the caller when a later request fails", %{name: name} do
      answers([&queued_with_warning/1, whole_call(429, "quota_limited")])

      log =
        capture_log(fn ->
          assert {:error, %BatchError{warnings: [%Emails.Warning{code: "sandbox_sender"}]}} =
                   batch(name, recipients(150))
        end)

      assert length(String.split(log, "PostHog email warning sandbox_sender")) == 2
    end
  end
end
