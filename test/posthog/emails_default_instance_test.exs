defmodule PostHog.EmailsDefaultInstanceTest do
  # Other modules start the default PostHog instance too, so this one runs in their group.
  use PostHog.Case,
    async: Version.match?(System.version(), ">= 1.18.0"),
    group: PostHog

  @moduletag config: [supervisor_name: PostHog, secret_key: "phs_secret_key"]

  import Mox

  alias PostHog.Emails

  setup :setup_supervisor
  setup :verify_on_exit!

  @message_id "01a18356-c56c-0001-e494-7666bc915188"

  test "send/1 and get/1 use the PostHog instance" do
    expect(PostHog.API.Mock, :request, fn _client, :post, url, opts ->
      assert url == "https://us.posthog.com/api/projects/@current/messaging/send/email/"
      assert {"authorization", "Bearer phs_secret_key"} in opts[:headers]
      {:ok, %{status: 202, headers: %{}, body: %{"message_id" => @message_id}}}
    end)

    expect(PostHog.API.Mock, :request, fn _client, :get, url, _opts ->
      assert url ==
               "https://us.posthog.com/api/projects/@current/messaging/emails/#{@message_id}/"

      {:ok,
       %{
         status: 200,
         headers: %{},
         body: %{
           "id" => @message_id,
           "status" => "queued",
           "created_at" => "2026-11-02T10:00:00Z",
           "status_at" => "2026-11-02T10:00:00Z",
           "reason" => nil
         }
       }}
    end)

    assert {:ok, %Emails.SendResult{id: @message_id}} =
             Emails.send(
               to: "user@example.com",
               template_key: "receipt",
               subject: "Hi",
               text: "Hi"
             )

    assert {:ok, %Emails.Status{id: @message_id, status: "queued"}} = Emails.get(@message_id)
  end
end
