defmodule PostHog.Emails do
  @moduledoc """
  Send transactional email, such as a password reset or a receipt, and read its status.

  An email goes out in one of two forms:

  - **A template made in PostHog**, sent by its ID with `:template_id` and `:template_data`.
  - **Content your code rendered**, named by `:template_key`, with `:subject` and `:html`,
    `:text` or both. To send a React email, render it to HTML in your app, for example with
    `@react-email/render`, and pass the result as `:html`. The SDK adds no rendering.

  ## Setup

  1. In PostHog, open the email template under Workflows, make it transactional, and copy its
     ID. `:template_id` is that UUID. The code form needs no template.
  2. Create a project secret API key (`phs_...`) with the "Send transactional email" preset
     (`transactional_email:write`) in your project settings. Add `transactional_email:read` too
     if you read email statuses with a key that can't send. Keys made with `hog_flow:write`
     still work. The project API key (`phc_...`) captures events but cannot send email.
  3. Set it as `:secret_key` in your PostHog config:

         config :posthog,
           api_host: "https://eu.i.posthog.com",
           api_key: "phc_...",
           secret_key: "phs_..."

  ## Examples

  Send a template made in PostHog:

      {:ok, %PostHog.Emails.SendResult{id: message_id}} =
        PostHog.Emails.send(
          to: "user@example.com",
          template_id: "0190f6d2-7c1e-7b3a-9f5e-1c2d3e4f5a6b",
          template_data: %{name: "Ada"},
          distinct_id: "user_123",
          idempotency_key: "welcome:user_123"
        )

  Send content your code rendered:

      PostHog.Emails.send(
        to: "user@example.com",
        template_key: "password-reset",
        subject: "Reset your password",
        html: rendered_html,
        distinct_id: "user_123",
        idempotency_key: "password-reset:\#{reset.id}"
      )

  Copy finance and attach the receipt:

      PostHog.Emails.send(
        to: "user@example.com",
        cc: "finance@example.com",
        template_key: "receipt",
        subject: "Your receipt",
        html: rendered_html,
        attachments: [
          %{filename: "receipt.pdf", content: File.read!(pdf_path), content_type: "application/pdf"}
        ],
        distinct_id: "user_123"
      )

  Read what happened to it:

      {:ok, %PostHog.Emails.Status{status: status}} = PostHog.Emails.get(message_id)

  Always pass `:distinct_id`. Without it, the email's events go to a person whose distinct ID
  is the email address, not to your user. The SDK never takes it from `PostHog.set_context/2`.

  ## What a result means

  `{:ok, result}` means PostHog queued or scheduled the email, and its `:status` says which.
  Delivery happens later: read it with `get/2`, or in the template's workflow in PostHog.

  ## Scheduling

  Pass `:scheduled_at` to send the email later, at most 7 days ahead, from either form:

      PostHog.Emails.send(
        to: "user@example.com",
        template_id: "0190f6d2-7c1e-7b3a-9f5e-1c2d3e4f5a6b",
        distinct_id: "user_123",
        scheduled_at: DateTime.add(DateTime.utc_now(), 1, :day)
      )

  `:scheduled_at` is a `DateTime`, or an ISO 8601 string in the form PostHog takes:
  `YYYY-MM-DDThh:mm`, optional seconds and their fraction, and a UTC offset, such as
  `"2026-12-01T09:00:00+02:00"` or `"2026-12-01T07:00Z"`. A `NaiveDateTime`, a string without an
  offset, or any other form returns `invalid_scheduled_at` before any request, because the email
  could go out at the wrong time.
  The SDK rounds a time finer than a millisecond up to the next millisecond, so rounding never
  moves the email earlier, and sends that time on every retry.

  The result's `:status` is `"scheduled"` and its `:scheduled_at` is the time PostHog
  confirmed. A time that has already passed sends the email now: the result's `:status` is
  `"queued"` and its `:scheduled_at` is `nil`. When PostHog accepts the email without confirming
  the time, the send returns `schedule_not_confirmed` with the email's `:message_id`. That
  includes an answer that sends the email now while the time was more than 60 seconds ahead of
  this machine's clock at the send's first attempt, retries included. The 60 seconds only
  decide when the SDK takes such an answer as success. The SDK reads the answer after PostHog took
  the email, so `schedule_not_confirmed` can come back for an email that already went out early,
  and a clock that runs behind can return it for an email that went out as asked. Read its status with `get/2` before you send it again. `get/2` reads `"scheduled"` until the email goes
  out, and works for 30 days after the send, not after the scheduled time.

  Only PostHog Cloud schedules emails. A send with `:scheduled_at` to any other app host, such
  as a reverse proxy, a custom domain or a self-hosted PostHog, returns
  `scheduling_requires_cloud` before any request: a PostHog that doesn't schedule emails would
  send it at once.

  Compute the time once and pass the same time on your own retries: the idempotency key covers
  it, so the same key with another time returns `idempotency_key_reused`. To stop scheduled emails
  before they go out, disable the email's workflow in PostHog until they reach a final status.
  That refuses every new send of it meanwhile.

  ## Batches

  `batch/2` sends the same template or content to many recipients, one email each, with
  `:template_data` per recipient for a template. A batch takes at most 100 recipients and goes out
  in one request, and the SDK waits at least 45 seconds for its answer. Each recipient has its
  own `:idempotency_key`, given or made by the SDK, that every retry reuses. Check each result's
  `:status`:

  - `"queued"`: PostHog accepted the email.
  - `"failed"`: PostHog refused it, and `:error` says why, such as a suppressed address.
  - `"unconfirmed"`: the SDK can't tell whether PostHog accepted it, such as after a lost
    answer, so it may still go out. Send it again, unchanged, with the same `:idempotency_key`
    within 24 hours of the key's first use, so it goes out once.

  A batch that PostHog refuses as a whole, such as a rate limit past its retries, returns
  `{:error, %PostHog.Emails.BatchError{}}`, whose `:results` hold every recipient. After a 5xx
  or any 409 but `batch_unavailable`, the recipients are `"unconfirmed"`. Once an answer is lost,
  a retry PostHog refuses can't show that the first try didn't queue the emails, so those
  recipients stay `"unconfirmed"` too: the error says some emails may have gone out, and its
  `:fix` says to send each recipient again with the same `:idempotency_key`. PostHog answers
  `content_too_large` in two cases. A 413 means the request is too large: split the recipients
  into smaller batches, or make the email smaller when the batch has one recipient. A 400 means the content or `:template_data` shared by every recipient is
  too large, which splitting doesn't help: send those emails one at a time with `send/2`. The code `batch_unavailable` (409) means the project can't send batches yet,
  and a 404 that names no field that the template ID is wrong or batch sends aren't available for
  the project: send each email the batch didn't queue with `send/2` and its recipient's
  `:idempotency_key`. A batch takes
  no `:cc`, `:bcc`, `:attachments` or `:scheduled_at`.

      {:ok, %PostHog.Emails.BatchResult{results: results}} =
        PostHog.Emails.batch(
          template_id: "0190f6d2-7c1e-7b3a-9f5e-1c2d3e4f5a6b",
          recipients: [
            %{to: "ada@example.com", template_data: %{name: "Ada"}},
            %{to: "alan@example.com", template_data: %{name: "Alan"}}
          ]
        )

      retry = Enum.filter(results, &(&1.status == "unconfirmed"))

  ## Where requests go

  A client on PostHog Cloud sends to its region's app host, `https://us.posthog.com` or
  `https://eu.posthog.com`. For any other `:api_host`, such as a reverse proxy, set `:app_host`
  in the config, because email requests must not send the secret key to the proxy. Without it,
  a send returns the error `missing_app_host`.

  `:secret_key` also turns on local feature flag evaluation, which fetches flag definitions
  from `:api_host` with that key. When `:api_host` is a proxy that must not see the key, set
  `enable_local_evaluation: false` as well.

  ## Attachments

  An email carries at most 10 files and 40 MB after Base64 encoding, about 29 MB of files. The
  SDK checks both before any request of a send with files, counting each file and body as Base64
  and the subject as 75 bytes per 42 started, as PostHog does. Without `:text`, PostHog derives
  the text from `:html` and counts it too, so the SDK counts the HTML twice.

  A send with files takes three steps:

  1. The SDK hashes each file with SHA-256 and asks PostHog which files it doesn't have yet.
  2. It uploads each of those straight to PostHog's file storage with a plain `Req` request,
     carrying only the headers PostHog gave. The upload doesn't go through
     `:api_client_module`, so no secret key or header of your client reaches the storage. A
     file PostHog already has, such as the same terms PDF sent to every customer, uploads
     nothing again.
  3. Once every upload succeeded, it sends the email, which names each file by its hash.

  Uploads go only over https, so a file and its signed URL never travel unencrypted. When
  PostHog names a plain-HTTP upload URL, the SDK uploads nothing, sends nothing, and returns
  `api_error` on the attachment. An `:app_host` on plain HTTP, as in local development, allows
  plain-HTTP uploads too. An upload never follows a redirect, which would carry the file to
  another URL: the storage's redirect fails the upload with `attachment_upload_failed`.

  Your app must be able to reach the storage host that PostHog's answer names directly: an
  upload doesn't go through a proxy, and it ignores your app's `Req.default_options`, which are
  meant for other requests. If an upload fails, the SDK sends nothing and returns
  `attachment_upload_failed` with what the storage answered. An upload gets the request timeout
  plus ten seconds per MB of the file. It retries network errors and storage answers of HTTP 429,
  500, 502, 503 and 504, as a send retries, honouring `Retry-After`.

  ## Timeouts, retries and idempotency

  Each request times out after `:email_request_timeout_ms` (15 seconds by default). A send
  retries network errors, rate limits, an idempotency key still in flight and an unavailable
  service `:email_request_max_retries` times (2 by default), waiting about 1 and then 2 seconds,
  or the server's `Retry-After` when it is longer. A `Retry-After` over 30 seconds fails at once
  with `:retry_after_ms` set. A monthly quota and the day's upload quota are never retried.
  A send's retries stop an hour after its first attempt, whatever `:max_retries` says, timed on
  both the monotonic and the system clock so a host suspension counts too. So a retry falls
  inside the 24 hours in which PostHog keeps an idempotency key unless the call
  starts in the last hour of them. To rerun with a stored key that close to its 24 hours, pass
  `max_retries: 0`.
  The upload steps of a send with files and status reads retry the same way, without the hour
  limit, since they send no email.

  Every attempt sends the same idempotency key, so a retry never sends twice. Without
  `:idempotency_key`, the SDK makes a UUID for the call. When a job runner such as Oban
  already retries the send, pass `max_retries: 0` and an `:idempotency_key` that names the
  email, such as `"welcome:user_123"`. A generated key doesn't survive a job retry.

  Sends and status reads block the calling process until they finish. The SDK keeps no email
  queue.

  ## Errors

  Every failure returns `{:error, %PostHog.Emails.Error{}}`. Branch on `:code`. The ones a
  setup usually hits:

  - `missing_secret_key`: the config has no `:secret_key`.
  - `missing_app_host`: the `:api_host` is not PostHog Cloud. Set `:app_host`.
  - `scheduling_requires_cloud`: a send with `:scheduled_at` to a host that is not PostHog Cloud.
  - `schedule_not_confirmed`: PostHog accepted a send with `:scheduled_at` without confirming its
    time, or sent it now while the time was more than 60 seconds ahead. The error's
    `:message_id` names the email.
  - `authentication_failed` (401) or `permission_denied` (403): the key is wrong, or it lacks
    `transactional_email:write`.
  - `not_found` (404): the template ID is wrong, or transactional email is not enabled for the
    project.
  - `client_disabled`: the PostHog instance is not running or has no `:api_key`, so it sends
    nothing.
  - `client_closed`: the PostHog instance stopped during a call, so the call made no further
    request. A send sent no email, unless PostHog didn't confirm an earlier try: then the
    message says the email may still go out, and the fix names the `:idempotency_key` to send it
    again with.
  - `batch_unavailable` (409): the project can't send batches yet. Send each email with
    `send/2`.

  A send with files can also return:

  - `too_many_attachments` or `message_too_large`: over 10 files, or over 40 MB after Base64
    encoding. The SDK checks both before any request, and PostHog checks them again.
  - `attachment_upload_failed`: an upload to PostHog's file storage failed, so no email was
    sent. The message has the storage's answer.
  - `attachment_not_uploaded`: PostHog has no uploaded file with a hash the send names.
  - `upload_quota_exceeded` (429): the project uploaded as many file bytes as it can today.
    Files PostHog already has don't count.
  - `field_not_accepted`: the project can't send files yet.

  An option the SDK refuses returns an error with an `invalid_*` code, such as
  `invalid_template_id`, and the name `:validation_error`, before any request.

  ## Testing

  Requests to PostHog go through the configured `:api_client_module`, so a `Mox` mock of
  `PostHog.API.Client` sees them without network calls. Attachment uploads go to the storage
  host instead, so test a send with files against an answer that marks every file `present`.
  """

  import Kernel, except: [send: 2]

  require Logger

  alias PostHog.Emails.Attachments
  alias PostHog.Emails.Batch
  alias PostHog.Emails.BatchError
  alias PostHog.Emails.BatchResult
  alias PostHog.Emails.Error
  alias PostHog.Emails.SendResult
  alias PostHog.Emails.Status
  alias PostHog.Emails.Warning

  @send_path "/api/messaging/send/email/"
  @uploads_path "/api/messaging/attachments/uploads/"
  @status_path "/api/messaging/emails/"
  @us_app_host "https://us.posthog.com"
  @eu_app_host "https://eu.posthog.com"
  @cloud_app_hosts %{
    "https://us.i.posthog.com" => @us_app_host,
    "https://us.posthog.com" => @us_app_host,
    "https://app.posthog.com" => @us_app_host,
    "https://eu.i.posthog.com" => @eu_app_host,
    "https://eu.posthog.com" => @eu_app_host
  }
  @max_retry_delay_ms 30_000
  @max_retry_doublings 6
  @max_retry_window_ms 3_600_000
  @year_one_us -62_135_596_800_000_000
  # Enough of the storage's answer for an S3 error, whose XML is well under 1 KB.
  @max_storage_answer_bytes 16_384
  @log_metadata [posthog_skip_capture: true]

  @shared_fields [:to, :distinct_id, :idempotency_key, :max_retries, :scheduled_at]
  @sent_now_tolerance_us 60_000_000
  @host_shape ~r/\A(?:[A-Za-z0-9._-]+|\[[0-9A-Fa-f:.]+\])(?::\d+)?\z/
  @scheduled_at_shape ~r/\A(?<minute>(?!0000)\d{4}-\d{2}-\d{2}T\d{2}:\d{2})(?<seconds>:\d{2}(?<fraction>\.\d+)?)?(?<offset>Z|[+-]\d{2}:[0-5]\d)\z/
  @template_fields @shared_fields ++ [:template_id, :template_data]
  @code_fields @shared_fields ++
                 [
                   :template_key,
                   :subject,
                   :html,
                   :text,
                   :from,
                   :reply_to,
                   :cc,
                   :bcc,
                   :attachments,
                   :sensitive,
                   :tracking,
                   :capture_engagement
                 ]
  @address_fields [:reply_to, :cc, :bcc]

  @typedoc """
  Options for `send/2`. Pass `:template_id` or `:template_key`, never both.

  Every send takes:

  - `:to` - one recipient email address. Required.
  - `:distinct_id` - the recipient's distinct ID in your product. The email's events go to
    this person.
  - `:idempotency_key` - 1 to 255 visible ASCII characters. A send with a key PostHog already
    accepted queues nothing and returns the first send's result. Template sends and code sends
    share one set of keys: a key already used for another email returns
    `idempotency_key_reused`.
  - `:max_retries` - overrides the config's `:email_request_max_retries` for this send. `0`
    turns retries off.
  - `:scheduled_at` - when to send the email, at most 7 days ahead, on PostHog Cloud only: a
    `DateTime` or an ISO 8601 string with a UTC offset. See "Scheduling" in `PostHog.Emails`.

  A template made in PostHog takes:

  - `:template_id` - the UUID of a template made transactional in PostHog.
  - `:template_data` - a map of values for the template's `{{ variables.* }}` placeholders.

  Content your code rendered takes:

  - `:template_key` - names the email, such as `"password-reset"`, so its metrics, logs and
    status group under it in PostHog. Letters, digits, `-` and `_`, at most 400.
  - `:subject` - the subject line. Required.
  - `:html` and `:text` - the bodies. Give one or both. Without `:text`, PostHog derives it from
    `:html`.
  - `:from` - a verified sender, such as `"Acme <security@example.com>"`. Without it, the
    project's default sender.
  - `:reply_to` - one address or a list of addresses.
  - `:cc` and `:bcc` - one address or a list of at most 10 bare addresses, such as
    `"finance@example.com"`, that get a visible or a hidden copy.
  - `:attachments` - a list of files: at most 10 files and 40 MB per email after Base64
    encoding, about 29 MB of files. Each is a map with `:filename`, `:content` (the file's
    bytes, such as `File.read!/1` returns), and optionally `:content_type`, such as
    `"application/pdf"`, and `:content_id`, which shows the file inline: reference it in
    `:html` as `<img src="cid:logo">` with `content_id: "logo"`. Pass raw bytes, not Base64.
    PostHog can't fetch a file from a path or URL. A file the SDK can't send returns the error
    code `invalid_attachment`. See "Attachments" in `PostHog.Emails` for how files travel.
  - `:sensitive` - `true` when the email carries login links, reset tokens or codes. A sensitive
    email keeps its links unchanged unless `:tracking` turns clicks on, leaves its subject off
    engagement events, and keeps its content out of logs. Left out, the email takes the setting of
    the template made in PostHog whose key matches `:template_key`, and is sensitive when no
    template matches. Sent only when you set it, and needs a PostHog version that takes it.
  - `:tracking` - what PostHog tracks for the email. Left out, PostHog counts opens and captures
    engagement events, and tracks clicks only when the email isn't sensitive. `true` turns on
    opens, clicks and engagement events, even for a sensitive email. `false` turns them all off:
    the email has no open pixel and no rewritten links, and PostHog captures no engagement events
    for it. A map such as `%{clicks: true}` sets `:opens` (default `true`), `:clicks` (default: on
    unless the email is sensitive) and `:engagement` (default `true`) one by one. Turn clicks on
    for a sensitive email only when its links are safe to rewrite. Click tracking needs open
    tracking. A project whose admin turned engagement capture off captures nothing, whatever the
    send says. Sent only when you set it, and needs a PostHog version that takes it.
  - `:capture_engagement` - deprecated: use `tracking: %{engagement: false}` instead. Whether
    PostHog captures the email's engagement events. It still works, but a send can't set both.
    Sent only when you set it.

  An option set to `nil` counts as left out, and so does an empty `:reply_to`, `:cc`, `:bcc` or
  `:attachments` list. A PostHog version that doesn't take a field yet, such as `:attachments`,
  refuses the send with an error whose `:field` names it, and never drops the field to send the
  rest.
  """
  @type send_option() ::
          {:to, String.t()}
          | {:distinct_id, String.t() | nil}
          | {:idempotency_key, String.t() | nil}
          | {:max_retries, non_neg_integer() | nil}
          | {:scheduled_at, DateTime.t() | String.t() | nil}
          | {:template_id, String.t()}
          | {:template_data, map() | nil}
          | {:template_key, String.t()}
          | {:subject, String.t()}
          | {:html, String.t() | nil}
          | {:text, String.t() | nil}
          | {:from, String.t() | nil}
          | {:reply_to, String.t() | [String.t()] | nil}
          | {:cc, String.t() | [String.t()] | nil}
          | {:bcc, String.t() | [String.t()] | nil}
          | {:attachments, [attachment()] | nil}
          | {:sensitive, boolean() | nil}
          | {:tracking, tracking() | nil}
          | {:capture_engagement, boolean() | nil}

  @typedoc """
  Options for `batch/2`. Pass `:template_id` or `:template_key`, never both.

  Every batch takes:

  - `:recipients` - 1 to 100 recipients, each a `t:batch_recipient/0`. Required.
  - `:max_retries` - overrides the config's `:email_request_max_retries` for the batch. `0`
    turns retries off.

  A template made in PostHog takes `:template_id` and `:template_data`, values shared by every
  recipient. Content your code rendered takes `:template_key`, `:subject`, `:html`, `:text`,
  `:from`, `:reply_to`, `:sensitive`, `:tracking` and `:capture_engagement`, as `t:send_option/0`
  describes them, the same for every recipient. A batch takes no `:cc`, `:bcc`, `:attachments` or
  `:scheduled_at`.
  """
  @type batch_option() ::
          {:recipients, [batch_recipient()]}
          | {:max_retries, non_neg_integer() | nil}
          | {:template_id, String.t()}
          | {:template_data, map() | nil}
          | {:template_key, String.t()}
          | {:subject, String.t()}
          | {:html, String.t() | nil}
          | {:text, String.t() | nil}
          | {:from, String.t() | nil}
          | {:reply_to, String.t() | [String.t()] | nil}
          | {:sensitive, boolean() | nil}
          | {:tracking, tracking() | nil}
          | {:capture_engagement, boolean() | nil}

  @typedoc """
  One recipient of `batch/2`, a map or a keyword list. Each gets its own email.

  - `:to` - the recipient's email address. Required.
  - `:distinct_id` - the recipient's distinct ID in your product.
  - `:idempotency_key` - 1 to 255 visible ASCII characters, a different one for each recipient
    of the batch. Without it, the SDK makes one that covers its own retries but not a second
    call, so pass keys you store when a batch may be cut off and run again: a rerun within 24
    hours replays the emails that went out instead of sending them twice. A single send and a
    batch recipient with the same key and the same email replay each other. Never reuse a key
    for another email: PostHog refuses it with `idempotency_key_reused`, though two different
    emails sent at the same moment with one key can both come back `"queued"` while only one
    goes out.
  - `:template_data` - only with `:template_id`: values for this recipient, merged over the
    batch's `:template_data`. A top-level key set here replaces the same key there.
  """
  @type batch_recipient() ::
          %{
            required(:to) => String.t(),
            optional(:distinct_id) => String.t() | nil,
            optional(:idempotency_key) => String.t() | nil,
            optional(:template_data) => map() | nil
          }
          | keyword()

  @typedoc """
  A file sent with the email. `:content` is the file's raw bytes, such as `File.read!/1`
  returns. Don't pass content that is already Base64: the recipient would get the Base64 text.
  """
  @type attachment() :: %{
          required(:filename) => String.t(),
          required(:content) => binary(),
          optional(:content_type) => String.t() | nil,
          optional(:content_id) => String.t() | nil
        }

  @typedoc """
  What PostHog tracks for an email sent with `:template_key`. See `:tracking` in
  `t:send_option/0`.
  """
  @type tracking() ::
          boolean()
          | %{
              optional(:opens) => boolean() | nil,
              optional(:clicks) => boolean() | nil,
              optional(:engagement) => boolean() | nil
            }

  @doc """
  Queues or schedules one email, from a template made in PostHog or from content your code
  rendered.

  Returns `{:ok, %PostHog.Emails.SendResult{}}` once PostHog accepted the email, or
  `{:error, %PostHog.Emails.Error{}}`. See `t:send_option/0` for the options. `name` is the
  PostHog instance to send through, `PostHog` by default.

  ## Examples

      PostHog.Emails.send(
        to: "user@example.com",
        template_id: "0190f6d2-7c1e-7b3a-9f5e-1c2d3e4f5a6b",
        distinct_id: "user_123"
      )

      PostHog.Emails.send(MyPostHog,
        to: "user@example.com",
        template_key: "receipt",
        subject: "Your receipt",
        html: html,
        distinct_id: "user_123"
      )
  """
  @spec send(PostHog.supervisor_name(), [send_option()] | map()) ::
          {:ok, SendResult.t()} | {:error, Error.t()}
  def send(name \\ PostHog, options) do
    with {:ok, prepared} <- prepare_send(options),
         {:ok, connection} <- connect(name, :send),
         :ok <- check_schedulable(connection, prepared),
         :ok <- upload(connection, prepared),
         {:ok, result} <- deliver(connection, prepared) do
      log_warnings(result)
      {:ok, result}
    end
  rescue
    exception -> {:error, unexpected(exception, "Sending the email failed unexpectedly.")}
  end

  @doc """
  Reads the status of an email that `send/2` queued, for 30 days after the send.

  Returns `{:ok, %PostHog.Emails.Status{}}` or `{:error, %PostHog.Emails.Error{}}`. The error
  code is `not_found` when no email of this project has the ID, when the email is older than 30
  days, or for a few seconds after the send. A key with only `transactional_email:read` can read
  statuses but not send. Network errors, rate limits and an unavailable service are retried.

  ## Examples

      {:ok, %PostHog.Emails.Status{status: "bounced", reason: reason}} =
        PostHog.Emails.get(message_id)
  """
  @spec get(PostHog.supervisor_name(), String.t()) :: {:ok, Status.t()} | {:error, Error.t()}
  def get(name \\ PostHog, message_id) do
    with {:ok, message_id} <- check_message_id(message_id),
         {:ok, connection} <- connect(name, :get) do
      path = @status_path <> message_id <> "/"

      with_retries(connection, connection.max_retries, fn ->
        connection
        |> request(:get, path, headers(connection), nil)
        |> parse_status_reply()
      end)
    end
  rescue
    exception -> {:error, unexpected(exception, "Reading the email status failed unexpectedly.")}
  end

  @doc """
  Queues the same email for many recipients, one email each, from a template made in PostHog or
  from content your code rendered.

  The SDK sends up to 100 recipients in one request. Each recipient has an `:idempotency_key`,
  given or made by the SDK, that every retry reuses, so a retry never queues an email twice.

  Returns `{:ok, %PostHog.Emails.BatchResult{}}` with a result per recipient, in the order of
  `:recipients`. Check each result's `:status`: `"queued"`, `"failed"` or `"unconfirmed"`. An
  `"unconfirmed"` email may still go out: send it again, unchanged, with the same
  `:idempotency_key` within 24 hours of the key's first use, so it goes out once. Its error's
  `:fix` says the same.

  A batch that PostHog refuses as a whole returns `{:error, %PostHog.Emails.BatchError{}}`, whose
  `:results` hold every recipient. Its `:code` is `batch_unavailable` when the project can't send
  batches yet: send each email the batch didn't queue with `send/2` and its recipient's
  `:idempotency_key`. It is `content_too_large` with status 413 when the request is too large for
  PostHog: split the recipients into smaller batches, or, for a batch of one, make the email
  smaller. With status 400, the shared content is too large: send those emails one at a time. That
  advice is for `"failed"` recipients. For a 413 the error's `:fix` says which applies, and for a
  400 its `:message` gives PostHog's advice. An `"unconfirmed"` recipient may still go out, so
  follow its result's `:fix`: send it again unchanged with the same key. `client_closed` means the
  PostHog instance stopped during the batch, so the SDK sent no further request, such as a retry
  after a lost answer. A request already in flight when it stops, with no retry left, returns its
  own outcome, such as `network_error` with its recipients `"unconfirmed"`.

  Only a failure before the batch is sent returns `{:error, %PostHog.Emails.Error{}}`: an option
  the SDK refuses, such as more than 100 recipients or two with the same `:idempotency_key`, or a
  client that can't send. Every later failure, an instance that stops or an unexpected exception
  from the HTTP client too, returns `{:error, %PostHog.Emails.BatchError{}}` with every
  recipient's result.

  See `t:batch_option/0` for the options and "Batches" in `PostHog.Emails` for the limits. `name`
  is the PostHog instance to send through, `PostHog` by default.

  ## Examples

      {:ok, %PostHog.Emails.BatchResult{results: results}} =
        PostHog.Emails.batch(
          template_id: "0190f6d2-7c1e-7b3a-9f5e-1c2d3e4f5a6b",
          recipients: [
            %{to: "ada@example.com", distinct_id: "user_1", template_data: %{name: "Ada"}},
            %{to: "alan@example.com", distinct_id: "user_2", template_data: %{name: "Alan"}}
          ]
        )

      not_queued = Enum.reject(results, &(&1.status == "queued"))
  """
  @spec batch(PostHog.supervisor_name(), [batch_option()] | map()) ::
          {:ok, BatchResult.t()} | {:error, BatchError.t() | Error.t()}
  def batch(name \\ PostHog, options), do: Batch.batch(name, options)

  defp deliver(connection, prepared) do
    headers = [
      {"content-type", "application/json"},
      {"idempotency-key", prepared.idempotency_key}
      | headers(connection)
    ]

    attempt_once = fn state, _attempt ->
      {sent_at, unconfirmed?} = state || {connection.now.(), false}

      case connection
           |> request(:post, @send_path, headers, prepared.body)
           |> parse_send_reply(prepared.scheduled_at, sent_at) do
        {:error, %Error{status_code: 429} = error} ->
          {:error, error, {sent_at, unconfirmed?}}

        {:error, %Error{code: "client_closed"} = error} ->
          {:error, error, {sent_at, unconfirmed?}}

        {:error, error} ->
          {:error, error, {sent_at, true}}

        {:ok, result} ->
          {:ok, result}
      end
    end

    case with_retries(
           connection,
           prepared.max_retries || connection.max_retries,
           nil,
           attempt_once
         ) do
      {:error, error, state} ->
        {:error, closed_after_try(error, state, connection, prepared.idempotency_key)}

      {:ok, result} ->
        {:ok, result}
    end
  end

  defp closed_after_try(%Error{code: "client_closed"} = error, {_sent_at, true}, connection, key) do
    %{
      error
      | message:
          "The PostHog instance #{inspect(connection.name)} stopped during the call, so the SDK sent no further request. PostHog didn't confirm an earlier try, so the email may still go out.",
        fix:
          "Send this email again, unchanged, with idempotency_key #{inspect(key)} within 24 hours of the key's first use, so it goes out once."
    }
  end

  defp closed_after_try(error, _state, _connection, _key), do: error

  defp upload(_connection, %{files: []}), do: :ok

  defp upload(connection, prepared) do
    max_retries = prepared.max_retries || connection.max_retries

    with {:ok, uploads} <- ask_where_to_upload(connection, prepared.files, max_retries),
         :ok <- Attachments.check_https(uploads, plain_http?(connection)) do
      put_files(connection, uploads, max_retries)
    end
  end

  # An app that talks to PostHog over plain HTTP, as in local development, may upload over it.
  defp plain_http?(connection), do: URI.parse(connection.app_host).scheme == "http"

  defp put_files(_connection, [], _max_retries), do: :ok

  defp put_files(connection, [{file, upload} | uploads], max_retries) do
    with :ok <- put_file(connection, file, upload, max_retries) do
      put_files(connection, uploads, max_retries)
    end
  end

  defp ask_where_to_upload(connection, files, max_retries) do
    headers = [{"content-type", "application/json"} | headers(connection)]
    body = Jason.encode!(Attachments.upload_request(files))

    with_retries(connection, max_retries, fn ->
      connection
      |> request(:post, @uploads_path, headers, body)
      |> parse_uploads_reply(files)
    end)
  end

  # Ten seconds per MB: a file that fits still uploads over a link of about 1 Mbit/s.
  defp upload_timeout_ms(connection, file),
    do: connection.timeout_ms + div(file.size, 100)

  defp put_file(connection, file, upload, max_retries) do
    timeout_ms = upload_timeout_ms(connection, file)

    connection
    |> with_retries(max_retries, fn ->
      case send_upload(connection, upload, file.content, timeout_ms) do
        {:ok, status, _body, _retry_after_ms} when status in 200..299 ->
          {:ok, :uploaded}

        {:ok, status, body, retry_after_ms} ->
          {:error,
           %{
             Attachments.upload_failed(file, upload.url, status, body)
             | retry_after_ms: retry_after_ms
           }}

        {:error, error} ->
          {:error, error}
      end
    end)
    |> case do
      {:ok, :uploaded} ->
        :ok

      {:error, %Error{code: "network_error"}} ->
        {:error, Attachments.upload_failed(file, upload.url, nil, nil)}

      {:error, error} ->
        {:error, error}
    end
  end

  # Options

  defp prepare_send(options) when is_list(options) or is_map(options) do
    if is_map(options) or Keyword.keyword?(options) do
      options |> Enum.reject(&left_out?/1) |> Map.new() |> prepare()
    else
      invalid_options()
    end
  end

  defp prepare_send(_options), do: invalid_options()

  # Options are often built generically, so an empty list counts as left out on both forms.
  @doc false
  def left_out?({key, []}) when key in [:attachments | @address_fields], do: true
  def left_out?({_key, value}), do: is_nil(value)

  defp invalid_options,
    do: {:error, Error.new("invalid_form", "send takes a keyword list or a map of options.")}

  defp prepare(options) do
    with :ok <- check_recipient(options),
         {:ok, content} <- content(options),
         {:ok, files} <- attachments(options),
         {:ok, idempotency_key} <- idempotency_key(options),
         {:ok, max_retries} <- max_retries(options),
         {:ok, scheduled_at} <- scheduled_at(options),
         {:ok, body} <-
           content
           |> put_if_any(:attachments, Enum.map(files, & &1.reference))
           |> put_scheduled_at(scheduled_at)
           |> encode(options) do
      {:ok,
       %{
         body: body,
         files: files,
         idempotency_key: idempotency_key,
         max_retries: max_retries,
         scheduled_at: scheduled_at
       }}
    end
  end

  @doc false
  def check_recipient(options) do
    cond do
      not nonblank?(options[:to]) ->
        invalid("invalid_recipient", "to must be one email address as a nonempty string.", "to")

      Map.has_key?(options, :distinct_id) and not nonempty?(options.distinct_id) ->
        invalid("invalid_distinct_id", "distinct_id must be a nonempty string.", "distinct_id")

      true ->
        :ok
    end
  end

  @doc false
  def content(%{template_id: _, template_key: _}), do: invalid_form()
  def content(%{template_id: _} = options), do: template_content(options)
  def content(%{template_key: _} = options), do: code_content(options)
  def content(_options), do: invalid_form()

  defp invalid_form,
    do:
      {:error,
       Error.new(
         "invalid_form",
         "Send either template_id, or template_key with subject and html or text."
       )}

  defp template_content(%{template_id: template_id} = options) do
    template_data = Map.get(options, :template_data, %{})

    cond do
      not uuid?(template_id) ->
        invalid("invalid_template_id", "template_id must be the template's UUID.", "template_id")

      not is_map(template_data) ->
        invalid("invalid_template_data", "template_data must be a map.", "template_data")

      true ->
        with :ok <- refuse_fields_outside(options, :template) do
          {:ok,
           options
           |> Map.take([:to, :distinct_id])
           |> Map.merge(%{template_id: String.downcase(template_id), message_data: template_data})}
        end
    end
  end

  defp code_content(%{template_key: template_key} = options) do
    with :ok <- check_template_key(template_key),
         :ok <- refuse_fields_outside(options, :code),
         :ok <- check_code_fields(options) do
      {:ok,
       options
       |> Map.take([
         :to,
         :distinct_id,
         :template_key,
         :subject,
         :html,
         :text,
         :from,
         :capture_engagement,
         :sensitive
       ])
       |> put_tracking(options)
       |> put_addresses(options)}
    end
  end

  defp attachments(options) do
    Attachments.prepare(Map.get(options, :attachments, []), options)
  end

  defp check_template_key(template_key) do
    if is_binary(template_key) and template_key =~ ~r/\A[a-zA-Z0-9_-]{1,400}\z/ do
      :ok
    else
      invalid(
        "invalid_template_key",
        "template_key can only have letters, digits, hyphens (-) and underscores (_), at most 400.",
        "template_key"
      )
    end
  end

  defp check_code_fields(options) do
    with :ok <- check_content(options) do
      check_sender(options)
    end
  end

  defp check_content(options) do
    cond do
      not is_binary(options[:subject]) ->
        invalid("invalid_form", "A send with template_key needs a subject.", "subject")

      field = Enum.find([:html, :text], &not_string?(options, &1)) ->
        invalid("invalid_form", "#{field} must be a string.", to_string(field))

      not Map.has_key?(options, :html) and not Map.has_key?(options, :text) ->
        invalid("invalid_form", "A send with template_key needs html, text or both.", "html")

      true ->
        :ok
    end
  end

  defp check_sender(options) do
    cond do
      not_string?(options, :from) ->
        invalid("invalid_form", "from must be a string.", "from")

      field =
          Enum.find(@address_fields, &(Map.has_key?(options, &1) and not addresses?(options[&1]))) ->
        invalid(
          "invalid_form",
          "#{field} must be one address or a list of addresses.",
          to_string(field)
        )

      not is_boolean(Map.get(options, :capture_engagement, true)) ->
        invalid("invalid_form", "capture_engagement must be true or false.", "capture_engagement")

      not is_boolean(Map.get(options, :sensitive, true)) ->
        invalid("invalid_form", "sensitive must be true or false.", "sensitive")

      not tracking?(Map.get(options, :tracking, true)) ->
        invalid(
          "invalid_form",
          "tracking must be true, false or a map such as %{clicks: true}.",
          "tracking"
        )

      true ->
        :ok
    end
  end

  defp not_string?(options, field),
    do: Map.has_key?(options, field) and not is_binary(Map.fetch!(options, field))

  defp put_addresses(content, options) do
    Enum.reduce(@address_fields, content, fn field, content ->
      put_if_any(content, field, List.wrap(Map.get(options, field)))
    end)
  end

  defp put_tracking(content, %{tracking: tracking}) when is_map(tracking),
    do: Map.put(content, :tracking, Map.reject(tracking, &is_nil(elem(&1, 1))))

  defp put_tracking(content, %{tracking: tracking}), do: Map.put(content, :tracking, tracking)
  defp put_tracking(content, _options), do: content

  defp tracking?(tracking) when is_boolean(tracking), do: true

  defp tracking?(tracking) when is_map(tracking),
    do: Enum.all?(tracking, fn {_kind, on} -> is_nil(on) or is_boolean(on) end)

  defp tracking?(_tracking), do: false

  defp put_if_any(content, _field, []), do: content
  defp put_if_any(content, field, list), do: Map.put(content, field, list)

  defp addresses?(address) when is_binary(address), do: nonblank?(address)
  defp addresses?(addresses) when is_list(addresses), do: Enum.all?(addresses, &nonblank?/1)
  defp addresses?(_addresses), do: false

  defp refuse_fields_outside(options, form) do
    {fields, other_fields} =
      case form do
        :template -> {@template_fields, @code_fields}
        :code -> {@code_fields, @template_fields}
      end

    case Enum.find(Map.keys(options), &(&1 not in fields)) do
      nil ->
        :ok

      field ->
        {:error, field_outside_error(form, field, field in other_fields)}
    end
  end

  defp field_outside_error(form, field, other_form_takes_it?) do
    form_field = if form == :template, do: "template_id", else: "template_key"
    message = "A send with #{form_field} doesn't take #{field}, so no email was sent."

    if other_form_takes_it? do
      {why, how} =
        case form do
          :template ->
            {"A template made in PostHog sets its own sender, copies, subject, content, attachments, tracking and sensitive setting, and follows the project's engagement setting.",
             "send content from your code with template_key"}

          :code ->
            {"A send with template_key takes its content from your code.",
             "send a template made in PostHog with template_id"}
        end

      Error.new("invalid_form", message,
        field: to_string(field),
        why: why,
        fix: "Remove #{field}, or #{how}."
      )
    else
      Error.new("invalid_form", message,
        field: to_string(field),
        fix: "Remove #{field} and send again."
      )
    end
  end

  @doc false
  def idempotency_key(%{idempotency_key: key}) do
    if is_binary(key) and key =~ ~r/\A[\x21-\x7e]{1,255}\z/ do
      {:ok, key}
    else
      invalid(
        "invalid_idempotency_key",
        "idempotency_key must be 1 to 255 visible ASCII characters without spaces.",
        "idempotency_key"
      )
    end
  end

  def idempotency_key(_options), do: {:ok, uuid4()}

  @doc false
  def max_retries(%{max_retries: retries}) when is_integer(retries) and retries >= 0,
    do: {:ok, retries}

  def max_retries(%{max_retries: _retries}),
    do:
      invalid("invalid_max_retries", "max_retries must be a nonnegative integer.", "max_retries")

  def max_retries(_options), do: {:ok, nil}

  defp scheduled_at(%{scheduled_at: %DateTime{} = at}),
    do: ceil_to_millisecond(DateTime.to_unix(at, :microsecond), false)

  defp scheduled_at(%{scheduled_at: at}) when is_binary(at) do
    case parse_time(at) do
      {:ok, microseconds, digits_past_microseconds?} ->
        ceil_to_millisecond(microseconds, digits_past_microseconds?)

      :error ->
        invalid_scheduled_at()
    end
  end

  defp scheduled_at(%{scheduled_at: _at}), do: invalid_scheduled_at()
  defp scheduled_at(_options), do: {:ok, nil}

  defp invalid_scheduled_at,
    do:
      invalid(
        "invalid_scheduled_at",
        "scheduled_at must be a DateTime or an ISO 8601 string with a UTC offset, such as \"2026-12-01T09:00:00Z\" or \"2026-12-01T09:00:00+02:00\", so the email can't go out at the wrong time. Seconds and their fraction are optional.",
        "scheduled_at"
      )

  defp parse_time(text) do
    with %{} = parts <- Regex.named_captures(@scheduled_at_shape, text),
         {:ok, parsed, _offset} <- DateTime.from_iso8601(extended(parts)) do
      {:ok, DateTime.to_unix(parsed, :microsecond), digits_past_microseconds?(parts)}
    else
      _invalid -> :error
    end
  end

  defp extended(%{"minute" => minute, "seconds" => seconds, "offset" => offset}),
    do: minute <> with_seconds(seconds) <> utc_offset(offset)

  defp with_seconds(""), do: ":00"
  defp with_seconds(seconds), do: seconds

  defp utc_offset("-00:00"), do: "Z"
  defp utc_offset(offset), do: offset

  defp digits_past_microseconds?(%{"fraction" => fraction}),
    do: fraction |> String.slice(7..-1//1) |> String.trim("0") != ""

  defp ceil_to_millisecond(microseconds, _digits_past_microseconds?)
       when microseconds < @year_one_us,
       do: invalid_scheduled_at()

  defp ceil_to_millisecond(microseconds, digits_past_microseconds?) do
    milliseconds = Integer.floor_div(microseconds, 1000)

    milliseconds =
      if Integer.mod(microseconds, 1000) > 0 or digits_past_microseconds?,
        do: milliseconds + 1,
        else: milliseconds

    case DateTime.from_unix(milliseconds, :millisecond) do
      {:ok, at} -> {:ok, at}
      {:error, _reason} -> invalid_scheduled_at()
    end
  end

  defp put_scheduled_at(content, nil), do: content

  defp put_scheduled_at(content, scheduled_at),
    do: Map.put(content, :scheduled_at, DateTime.to_iso8601(scheduled_at))

  @doc false
  def encode(content, options) do
    case Jason.encode(content) do
      {:ok, body} ->
        {:ok, body}

      {:error, _reason} when is_map_key(options, :template_id) ->
        invalid("invalid_template_data", "template_data must encode as JSON.", "template_data")

      {:error, _reason} ->
        {:error, Error.new("invalid_form", "Every string option must be valid UTF-8.")}
    end
  end

  defp check_message_id(message_id) do
    if uuid?(message_id) do
      {:ok, String.downcase(message_id)}
    else
      invalid(
        "invalid_message_id",
        "message_id must be the message ID that send/2 returned.",
        "message_id"
      )
    end
  end

  defp uuid?(value), do: UUIDv7.decode(value) != :error

  defp nonempty?(value), do: is_binary(value) and value != ""
  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""

  defp invalid(code, message, field), do: {:error, Error.new(code, message, field: field)}

  defp uuid4 do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)

    UUIDv7.encode(<<a::48, 4::4, b::12, 2::2, c::62>>)
  end

  # Connection

  @doc false
  def connect(name, operation) do
    nothing_done =
      if operation == :send, do: "no email was sent", else: "no email status was read"

    instance = GenServer.whereis(name)
    config = PostHog.Registry.config(name)

    with :ok <- check_enabled(config, name, nothing_done),
         {:ok, app_host} <- app_host(config),
         {:ok, secret_key} <- secret_key(name, operation) do
      {:ok,
       %{
         name: name,
         instance: instance,
         nothing_done: nothing_done,
         api_client: config.api_client,
         app_host: app_host,
         secret_key: secret_key,
         migrated_from: Map.get(config, :migrated_from),
         timeout_ms: config.email_request_timeout_ms,
         max_retries: config.email_request_max_retries,
         sleep: Map.get(config, :email_sleep, &Process.sleep/1),
         now: Map.get(config, :email_now, &DateTime.utc_now/0),
         monotonic_ms:
           Map.get(config, :email_monotonic_ms, fn -> System.monotonic_time(:millisecond) end),
         upload_adapter: Map.get(config, :email_upload_adapter, :none)
       }}
    end
  end

  defp check_enabled(%{enabled: true, api_client: %{}}, _name, _nothing_done), do: :ok

  defp check_enabled(_config, name, nothing_done) do
    {:error,
     Error.new(
       "client_disabled",
       "The PostHog instance #{inspect(name)} is not running or has no api_key, so #{nothing_done}."
     )}
  end

  defp check_running(%{name: name, instance: instance, nothing_done: nothing_done}) do
    with %{enabled: true} <- PostHog.Registry.config(name),
         ^instance <- GenServer.whereis(name) do
      :ok
    else
      _stopped ->
        {:error,
         Error.new(
           "client_closed",
           "The PostHog instance #{inspect(name)} stopped during the call, so #{nothing_done}."
         )}
    end
  end

  # A custom host is often an ingestion proxy, which must not receive the secret key.
  defp app_host(config) do
    case Map.get(config, :app_host) do
      app_host when is_binary(app_host) ->
        app_host = String.trim_trailing(app_host, "/")
        {:ok, Map.get(@cloud_app_hosts, app_host, app_host)}

      nil ->
        case Map.fetch(@cloud_app_hosts, String.trim_trailing(config.api_host, "/")) do
          {:ok, app_host} ->
            {:ok, app_host}

          :error ->
            {:error,
             Error.new(
               "missing_app_host",
               "The config's api_host is not PostHog Cloud, so the SDK can't tell where to send email. Set app_host to your PostHog app host."
             )}
        end
    end
  end

  defp check_schedulable(%{app_host: app_host}, %{scheduled_at: %DateTime{}})
       when app_host not in [@us_app_host, @eu_app_host] do
    {:error,
     Error.new(
       "scheduling_requires_cloud",
       "Scheduled sends work only on PostHog Cloud (#{@us_app_host} or #{@eu_app_host}), and this client sends email to #{origin(app_host)}, so no email was sent.",
       field: "scheduled_at",
       why: "A PostHog that doesn't schedule emails would send this one at once.",
       fix:
         "Send without scheduled_at, or set app_host to PostHog Cloud's app host. A reverse proxy or custom domain can't schedule emails yet."
     )}
  end

  defp check_schedulable(_connection, _prepared), do: :ok

  defp origin(url) do
    with [_match, scheme, rest] <- Regex.run(~r{\A([A-Za-z][A-Za-z0-9+.-]*://)(.*)\z}s, url),
         host when is_binary(host) <- named_host(rest),
         true <- Regex.match?(@host_shape, host) do
      scheme <> host
    else
      _unnamed -> "the configured app_host"
    end
  end

  defp named_host(rest) do
    [authority | after_authority] = String.split(rest, ["/", "?", "#"], parts: 2)

    if Enum.any?(after_authority, &String.contains?(&1, "@")),
      do: nil,
      else: authority |> String.split("@") |> List.last()
  end

  defp secret_key(name, operation) do
    case PostHog.Registry.secret_key(name) do
      %PostHog.Config.Secret{} = secret ->
        {:ok, PostHog.Config.Secret.reveal(secret)}

      nil ->
        message =
          if operation == :send,
            do:
              "Sending email needs secret_key, a project secret API key with the transactional_email:write scope.",
            else:
              "Reading an email status needs secret_key, a project secret API key with the transactional_email:read or transactional_email:write scope."

        {:error, Error.new("missing_secret_key", message)}
    end
  end

  @doc false
  def headers(connection) do
    headers = [
      {"authorization", "Bearer #{connection.secret_key}"},
      {"accept", "application/json"},
      {"user-agent", PostHog.API.Client.user_agent()}
    ]

    case connection.migrated_from do
      nil -> headers
      migrated_from -> [{"x-posthog-migrated-from", migrated_from} | headers]
    end
  end

  # Requests

  @doc false
  def request(connection, method, path, headers, body) do
    %{module: module, client: client} = connection.api_client
    url = connection.app_host <> path

    # The SDK parses the body itself, so a malformed acceptance stays an api_error with its status.
    options =
      [
        headers: headers,
        retry: false,
        redirect: false,
        compress_body: false,
        decode_body: false,
        receive_timeout: connection.timeout_ms
      ] ++ if(body, do: [body: body], else: [])

    case run_request(connection, connection.timeout_ms, fn ->
           module.request(client, method, url, options)
         end) do
      {:ok, status, body, retry_after_ms} -> {:ok, status, fields(body), retry_after_ms}
      {:error, error} -> {:error, error}
    end
  end

  # A bare request: not through the api_client, whose defaults, such as headers a custom client
  # adds, are meant for PostHog, and without Req's steps and the app's Req.default_options, such as
  # an auth or compress_body set for other requests. The storage gets the bytes and the headers
  # PostHog signed the upload with, nothing else. Without Req's steps it never follows a redirect,
  # so the file goes only to the URL PostHog signed. It reads only the start of the storage's
  # answer, so a storage that answers without end can't fill the app's memory.
  defp send_upload(connection, upload, content, timeout_ms) do
    request =
      Req.Request.new(
        method: :put,
        url: upload.url,
        headers: for({name, value} <- upload.headers, do: {String.downcase(name), value}),
        body: content,
        options: [receive_timeout: timeout_ms]
      )
      |> Map.put(:into, &keep_start/2)
      |> with_upload_adapter(connection.upload_adapter)

    run_request(connection, timeout_ms, fn ->
      case Req.Request.run_request(request) do
        {_request, %Req.Response{} = response} -> {:ok, response}
        {_request, exception} -> {:error, exception}
      end
    end)
  end

  defp keep_start({:data, data}, {request, response}) do
    body = response.body <> data

    if byte_size(body) < @max_storage_answer_bytes,
      do: {:cont, {request, %{response | body: body}}},
      else:
        {:halt, {request, %{response | body: binary_part(body, 0, @max_storage_answer_bytes)}}}
  end

  # Req's own default adapter, which differs between Req versions, unless a test sets one.
  defp with_upload_adapter(request, :none), do: request

  defp with_upload_adapter(request, {adapter, options}),
    do: %{request | adapter: adapter, options: Map.merge(request.options, Map.new(options))}

  # Each request checks that the instance still runs, so a send stopped between its steps sends
  # nothing more.
  defp run_request(connection, timeout_ms, request) do
    with :ok <- check_running(connection),
         {:ok, %{status: status} = response} when is_integer(status) <-
           within_deadline(timeout_ms, fn -> call_client(request) end) do
      {:ok, status, Map.get(response, :body), retry_after_ms(Map.get(response, :headers))}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, _reason} -> {:error, Error.new("network_error", "The request to PostHog failed.")}
    end
  end

  # Finch raises, rather than returns, when no pooled connection frees up in time.
  defp call_client(request) do
    request.()
  rescue
    exception in RuntimeError ->
      if String.starts_with?(exception.message, "Finch was unable to provide a connection"),
        do: {:error, exception},
        else: reraise(exception, __STACKTRACE__)
  end

  # The client's own timeouts bound each phase, not the whole request, so the request runs in a
  # monitored worker that is killed at the deadline. The worker is not linked, so its failure comes
  # back as an error rather than killing the caller, and a caller that traps exits gets no exit
  # message. A watchdog kills the worker when the caller dies, so the request ends with its caller.
  defp within_deadline(timeout_ms, fun) do
    caller = self()
    reply = make_ref()
    # Keeps test allowances, such as Mox's, for the worker.
    callers = [caller | Process.get(:"$callers", [])]

    {worker, monitor} =
      spawn_monitor(fn ->
        worker = self()
        spawn(fn -> watch(caller, worker) end)
        Process.put(:"$callers", callers)
        Kernel.send(caller, {reply, run_capturing(fun)})
      end)

    receive do
      {^reply, result} ->
        Process.demonitor(monitor, [:flush])
        unwrap(result)

      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        {:error, :worker_down}
    after
      timeout_ms ->
        Process.exit(worker, :kill)
        # The DOWN message comes after any reply the worker sent, so both leave the mailbox here.
        receive do
          {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
        end

        receive do
          {^reply, _late} -> :ok
        after
          0 -> :ok
        end

        {:error, :timeout}
    end
  end

  # Monitoring a caller that is already gone delivers DOWN at once, so no window is missed.
  defp watch(caller, worker) do
    caller_monitor = Process.monitor(caller)
    worker_monitor = Process.monitor(worker)

    receive do
      {:DOWN, ^caller_monitor, :process, ^caller, _reason} -> Process.exit(worker, :kill)
      {:DOWN, ^worker_monitor, :process, ^worker, _reason} -> :ok
    end
  end

  defp run_capturing(fun) do
    {:returned, fun.()}
  rescue
    exception -> {:raised, exception, __STACKTRACE__}
  catch
    kind, reason -> {:caught, kind, reason, __STACKTRACE__}
  end

  defp unwrap({:returned, result}), do: result
  defp unwrap({:raised, exception, stacktrace}), do: reraise(exception, stacktrace)
  defp unwrap({:caught, :exit, reason, _stacktrace}), do: {:error, {:client_exit, reason}}

  defp unwrap({:caught, :throw, value, stacktrace}),
    do: :erlang.raise(:error, {:nocatch, value}, stacktrace)

  defp fields(body) when is_map(body), do: body

  defp fields(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = fields} -> fields
      _other -> %{}
    end
  end

  defp fields(_body), do: %{}

  defp with_retries(connection, max_retries, attempt_once) do
    attempt_once = fn nil, _attempt ->
      with {:error, error} <- attempt_once.(), do: {:error, error, nil}
    end

    with {:error, error, nil} <- retry(connection, {max_retries, nil}, nil, attempt_once, 0),
         do: {:error, error}
  end

  @doc false
  def with_retries(connection, max_retries, state, attempt_once),
    do:
      retry(
        connection,
        {max_retries, {connection.monotonic_ms.(), connection.now.()}},
        state,
        attempt_once,
        0
      )

  defp retry(connection, {max_retries, started_at} = limits, state, attempt_once, attempt) do
    case attempt_once.(state, attempt) do
      {:ok, result} ->
        {:ok, result}

      {:error, %Error{} = error, state} ->
        delay_ms = retry_delay_ms(error, attempt, max_retries)

        if is_nil(delay_ms) or past_retry_window?(connection, started_at, delay_ms) do
          {:error, error, state}
        else
          connection.sleep.(delay_ms)
          retry_in_window(connection, limits, {error, state}, attempt_once, attempt + 1)
        end
    end
  end

  defp retry_in_window(
         connection,
         {_max, started_at} = limits,
         {error, state},
         attempt_once,
         attempt
       ) do
    if past_retry_window?(connection, started_at, 0) do
      case check_running(connection) do
        :ok -> {:error, error, state}
        {:error, closed} -> {:error, closed, state}
      end
    else
      retry(connection, limits, state, attempt_once, attempt)
    end
  end

  defp past_retry_window?(_connection, nil, _delay_ms), do: false

  defp past_retry_window?(connection, {monotonic_at, wall_at}, delay_ms) do
    elapsed_ms =
      max(
        connection.monotonic_ms.() - monotonic_at,
        DateTime.diff(connection.now.(), wall_at, :millisecond)
      )

    elapsed_ms + delay_ms >= @max_retry_window_ms
  end

  # A send carries an idempotency key, so a retry can't queue a second email. A status read changes nothing.
  # An upload writes the same bytes to the same key, and S3 asks clients to retry its 500s.
  defp retryable?(%Error{code: "attachment_upload_failed", status_code: status}),
    do: status in [429, 500, 502, 503, 504]

  defp retryable?(%Error{status_code: nil, code: code}), do: code == "network_error"
  defp retryable?(%Error{status_code: 409, code: code}), do: code == "idempotency_key_in_flight"
  # Waiting doesn't fix a monthly quota.
  defp retryable?(%Error{status_code: 429, code: code}),
    do: code not in ["quota_limited", "upload_quota_exceeded"]

  defp retryable?(%Error{status_code: status}), do: status == 503

  defp retry_delay_ms(error, attempt, max_retries) do
    cond do
      attempt >= max_retries or not retryable?(error) ->
        nil

      # Retrying before a longer Retry-After would break the server's rate limit.
      (error.retry_after_ms || 0) > @max_retry_delay_ms ->
        nil

      true ->
        backoff =
          min(
            @max_retry_delay_ms,
            round(1000 * 2 ** min(attempt, @max_retry_doublings) * (0.8 + :rand.uniform() * 0.4))
          )

        max(backoff, error.retry_after_ms || 0)
    end
  end

  # Replies

  defp parse_send_reply({:ok, status, fields, _retry_after}, scheduled_at, sent_at)
       when status in 200..299 do
    case text(fields["message_id"]) do
      nil ->
        {:error,
         Error.new("api_error", "PostHog answered without a message ID.", status_code: status)}

      id ->
        %SendResult{
          id: id,
          replayed: fields["replayed"] == true,
          warnings: warnings(fields["warnings"])
        }
        |> confirm_schedule(fields, scheduled_at, status, sent_at)
    end
  end

  defp parse_send_reply(reply, _scheduled_at, _sent_at), do: reply_error(reply)

  defp confirm_schedule(result, _fields, nil, _status, _sent_at), do: {:ok, result}

  defp confirm_schedule(result, fields, scheduled_at, status, sent_at) do
    cond do
      confirms?(fields, scheduled_at) ->
        {:ok, %{result | status: "scheduled", scheduled_at: scheduled_at}}

      sent_now_as_time_passed?(fields, scheduled_at, sent_at) ->
        {:ok, result}

      true ->
        log_warnings(result)
        {:error, schedule_not_confirmed(result.id, status)}
    end
  end

  defp confirms?(fields, scheduled_at),
    do: fields["status"] == "scheduled" and same_instant?(fields["scheduled_at"], scheduled_at)

  defp sent_now_as_time_passed?(fields, scheduled_at, sent_at) do
    fields["status"] == "queued" and Map.fetch(fields, "scheduled_at") == {:ok, nil} and
      DateTime.diff(scheduled_at, sent_at, :microsecond) <= @sent_now_tolerance_us
  end

  defp same_instant?(answer, scheduled_at) when is_binary(answer) do
    case parse_time(answer) do
      {:ok, microseconds, false} -> microseconds == DateTime.to_unix(scheduled_at, :microsecond)
      _other -> false
    end
  end

  defp same_instant?(_answer, _scheduled_at), do: false

  defp schedule_not_confirmed(message_id, status) do
    Error.new(
      "schedule_not_confirmed",
      "PostHog accepted email #{message_id} without confirming its scheduled_at, so it may go out at another time.",
      status_code: status,
      field: "scheduled_at",
      message_id: message_id,
      fix:
        "Read the email's status with PostHog.Emails.get/2 before you send it again: a send with another idempotency_key sends a second email."
    )
  end

  defp parse_uploads_reply({:ok, status, fields, _retry_after}, files) when status in 200..299 do
    case Attachments.uploads(fields, files) do
      {:ok, uploads} ->
        {:ok, uploads}

      :error ->
        {:error,
         Error.new("api_error", "PostHog answered the upload request in a way the SDK can't use.",
           status_code: status
         )}
    end
  end

  defp parse_uploads_reply(reply, files) do
    {:error, error} = reply_error(reply)
    {:error, %{error | field: Attachments.field(error, files)}}
  end

  @doc false
  def warnings(warnings) when is_list(warnings) do
    for %{} = warning <- warnings do
      %Warning{
        code: text(warning["code"]) || "warning",
        message: text(warning["detail"]) || text(warning["message"]) || "",
        fix: text(warning["fix"])
      }
    end
  end

  def warnings(_warnings), do: []

  @doc false
  def log_warnings(%{warnings: warnings}) do
    for warning <- warnings do
      Logger.warning("PostHog email warning #{warning.code}: #{warning.message}", @log_metadata)
    end
  end

  defp parse_status_reply({:ok, status, fields, _retry_after}) when status in 200..299 do
    with id when is_binary(id) <- text(fields["id"]),
         delivery_status when is_binary(delivery_status) <- text(fields["status"]),
         {:ok, created_at, _offset} <- DateTime.from_iso8601(text(fields["created_at"]) || ""),
         {:ok, status_at, _offset} <- DateTime.from_iso8601(text(fields["status_at"]) || "") do
      {:ok,
       %Status{
         id: id,
         status: delivery_status,
         created_at: created_at,
         status_at: status_at,
         reason: text(fields["reason"])
       }}
    else
      _missing ->
        {:error,
         Error.new("api_error", "PostHog answered without an email status.", status_code: status)}
    end
  end

  defp parse_status_reply(reply), do: reply_error(reply)

  @doc false
  def reply_error({:error, error}), do: {:error, error}

  def reply_error({:ok, status, fields, retry_after_ms}) do
    {:error,
     Error.new(
       text(fields["code"]) || "api_error",
       text(fields["detail"]) || "PostHog answered HTTP #{status}.",
       status_code: status,
       why: text(fields["why"]),
       fix: text(fields["fix"]),
       docs_url: text(fields["docs_url"]),
       field: text(fields["attr"]),
       retry_after_ms: retry_after_ms
     )}
  end

  @doc false
  def text(value) when is_binary(value) and value != "", do: value
  def text(_value), do: nil

  @doc false
  def unexpected(exception, message) do
    Logger.error("#{message} #{inspect(exception.__struct__)}", @log_metadata)
    Error.new("unexpected_error", message)
  end

  # Retry-After: delay-seconds or an HTTP date.

  defp retry_after_ms(headers) do
    case header_value(headers, "retry-after") do
      value when is_binary(value) -> parse_retry_after(String.trim(value))
      _missing -> nil
    end
  end

  defp header_value(headers, name) when is_map(headers) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(to_string(key)) == name, do: List.wrap(value) |> List.first()
    end)
  end

  defp header_value(headers, name) when is_list(headers) do
    Enum.find_value(headers, fn
      {key, value} -> if String.downcase(to_string(key)) == name, do: value
      _other -> nil
    end)
  end

  defp header_value(_headers, _name), do: nil

  defp parse_retry_after(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> seconds * 1000
      _other -> parse_http_date(value)
    end
  end

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  defp parse_http_date(value) do
    with [_, day, month, year, time] <-
           Regex.run(~r/\A\w{3}, (\d{2}) (\w{3}) (\d{4}) (\d{2}:\d{2}:\d{2}) GMT\z/, value),
         month when is_integer(month) <- Enum.find_index(@months, &(&1 == month)),
         {:ok, date} <- Date.new(String.to_integer(year), month + 1, String.to_integer(day)),
         {:ok, time} <- Time.from_iso8601(time),
         {:ok, at} <- DateTime.new(date, time) do
      max(0, DateTime.diff(at, DateTime.utc_now(), :millisecond))
    else
      _invalid -> nil
    end
  end
end
