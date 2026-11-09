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

  `{:ok, result}` means PostHog queued the email. Delivery happens later: read it with `get/2`,
  or in the template's workflow in PostHog.

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
  SDK checks both before any request, counting each file and body as Base64, as PostHog does.

  A send with files takes three steps:

  1. The SDK hashes each file with SHA-256 and asks PostHog which files it doesn't have yet.
  2. It uploads each of those straight to PostHog's file storage with a plain `Req` request,
     carrying only the headers PostHog gave. The upload doesn't go through
     `:api_client_module`, so no secret key or header of your client reaches the storage. A
     file PostHog already has, such as the same terms PDF sent to every customer, uploads
     nothing again.
  3. Once every upload succeeded, it sends the email, which names each file by its hash.

  Your app must be able to reach the storage host that PostHog's answer names. If an upload
  fails, the SDK sends nothing and returns `attachment_upload_failed` with what the storage
  answered. An upload gets the request timeout plus one second per MB of the file, and retries
  as a send does, as well as when the storage answers HTTP 500, 502 or 504. It ignores your
  app's `Req.default_options`, which are meant for other requests.

  ## Timeouts, retries and idempotency

  Each request times out after `:email_request_timeout_ms` (15 seconds by default). A send
  retries network errors, rate limits, an idempotency key still in flight and an unavailable
  service `:email_request_max_retries` times (2 by default), waiting about 1 and then 2 seconds,
  or the server's `Retry-After` when it is longer. A `Retry-After` over 30 seconds fails at once
  with `:retry_after_ms` set. A monthly quota and the day's upload quota are never retried.
  The upload steps of a send with files retry the same way.

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
  - `authentication_failed` (401) or `permission_denied` (403): the key is wrong, or it lacks
    `transactional_email:write`.
  - `not_found` (404): the template ID is wrong, or transactional email is not enabled for the
    project.
  - `client_disabled`: the PostHog instance is not running or has no `:api_key`, so it sends
    nothing.
  - `client_closed`: the PostHog instance stopped during a call, so the call made no further
    request, and a send sent no email.

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
  alias PostHog.Emails.Error
  alias PostHog.Emails.SendResult
  alias PostHog.Emails.Status
  alias PostHog.Emails.Warning

  @send_path "/api/projects/@current/messaging/send/email/"
  @uploads_path "/api/projects/@current/messaging/attachments/uploads/"
  @status_path "/api/projects/@current/messaging/emails/"
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
  @log_metadata [posthog_skip_capture: true]

  @shared_fields [:to, :distinct_id, :idempotency_key, :max_retries]
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
  - `:capture_engagement` - whether PostHog captures the email's opens and clicks as events of
    the recipient. Defaults to `true`. A project whose admin turned engagement capture off
    captures nothing, whatever the send asks.

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
          | {:capture_engagement, boolean() | nil}

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

  @doc """
  Queues one email, from a template made in PostHog or from content your code rendered.

  Returns `{:ok, %PostHog.Emails.SendResult{}}` once PostHog queued the email, or
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

  defp deliver(connection, prepared) do
    headers = [
      {"content-type", "application/json"},
      {"idempotency-key", prepared.idempotency_key}
      | headers(connection)
    ]

    with_retries(connection, prepared.max_retries || connection.max_retries, fn ->
      connection
      |> request(:post, @send_path, headers, prepared.body)
      |> parse_send_reply()
    end)
  end

  defp upload(_connection, %{files: []}), do: :ok

  defp upload(connection, prepared) do
    max_retries = prepared.max_retries || connection.max_retries

    with {:ok, uploads} <- ask_where_to_upload(connection, prepared.files, max_retries) do
      put_files(connection, uploads, max_retries)
    end
  end

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

  defp upload_timeout_ms(connection, file),
    do: connection.timeout_ms + div(file.size, 1_000_000) * 1_000

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
  defp left_out?({key, []}) when key in [:attachments | @address_fields], do: true
  defp left_out?({_key, value}), do: is_nil(value)

  defp invalid_options,
    do: {:error, Error.new("invalid_form", "send takes a keyword list or a map of options.")}

  defp prepare(options) do
    with :ok <- check_recipient(options),
         {:ok, content} <- content(options),
         {:ok, files} <- attachments(options),
         {:ok, idempotency_key} <- idempotency_key(options),
         {:ok, max_retries} <- max_retries(options),
         {:ok, body} <-
           encode(put_if_any(content, :attachments, Enum.map(files, & &1.reference)), options) do
      {:ok,
       %{body: body, files: files, idempotency_key: idempotency_key, max_retries: max_retries}}
    end
  end

  defp check_recipient(options) do
    cond do
      not nonblank?(options[:to]) ->
        invalid("invalid_recipient", "to must be one email address as a nonempty string.", "to")

      Map.has_key?(options, :distinct_id) and not nonempty?(options.distinct_id) ->
        invalid("invalid_distinct_id", "distinct_id must be a nonempty string.", "distinct_id")

      true ->
        :ok
    end
  end

  defp content(%{template_id: _, template_key: _}), do: invalid_form()
  defp content(%{template_id: _} = options), do: template_content(options)
  defp content(%{template_key: _} = options), do: code_content(options)
  defp content(_options), do: invalid_form()

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
       |> Map.take([:to, :distinct_id, :template_key, :subject, :html, :text, :from])
       |> Map.put(:capture_engagement, Map.get(options, :capture_engagement, true))
       |> put_addresses(options)}
    end
  end

  defp attachments(options) do
    Attachments.prepare(
      Map.get(options, :attachments, []),
      Enum.flat_map([:html, :text], &List.wrap(options[&1]))
    )
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
            {"A template made in PostHog sets its own sender, copies, subject, content and attachments, and follows the project's engagement setting.",
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

  defp idempotency_key(%{idempotency_key: key}) do
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

  defp idempotency_key(_options), do: {:ok, uuid4()}

  defp max_retries(%{max_retries: retries}) when is_integer(retries) and retries >= 0,
    do: {:ok, retries}

  defp max_retries(%{max_retries: _retries}),
    do:
      invalid("invalid_max_retries", "max_retries must be a nonnegative integer.", "max_retries")

  defp max_retries(_options), do: {:ok, nil}

  defp encode(content, options) do
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

  defp connect(name, operation) do
    nothing_done =
      if operation == :send, do: "no email was sent", else: "no email status was read"

    config = PostHog.Registry.config(name)

    with :ok <- check_enabled(config, name, nothing_done),
         {:ok, app_host} <- app_host(config),
         {:ok, secret_key} <- secret_key(name, operation) do
      {:ok,
       %{
         name: name,
         nothing_done: nothing_done,
         api_client: config.api_client,
         app_host: app_host,
         secret_key: secret_key,
         migrated_from: Map.get(config, :migrated_from),
         timeout_ms: config.email_request_timeout_ms,
         max_retries: config.email_request_max_retries,
         sleep: Map.get(config, :email_sleep, &Process.sleep/1),
         upload_adapter: Map.get(config, :email_upload_adapter)
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

  defp check_running(%{name: name, nothing_done: nothing_done}) do
    case PostHog.Registry.config(name) do
      %{enabled: true} ->
        :ok

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

  defp headers(connection) do
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

  defp request(connection, method, path, headers, body) do
    url = connection.app_host <> path

    case send_request(connection, method, url, headers, body, connection.timeout_ms) do
      {:ok, status, body, retry_after_ms} -> {:ok, status, fields(body), retry_after_ms}
      {:error, error} -> {:error, error}
    end
  end

  defp send_request(connection, method, url, headers, body, timeout_ms) do
    # The SDK parses the body itself, so a malformed acceptance stays an api_error with its status.
    options =
      [
        headers: headers,
        retry: false,
        redirect: false,
        compress_body: false,
        decode_body: false,
        receive_timeout: timeout_ms
      ] ++ if(body, do: [body: body], else: [])

    %{module: module, client: client} = connection.api_client
    run_request(connection, timeout_ms, fn -> module.request(client, method, url, options) end)
  end

  # A bare request: not through the api_client, whose defaults, such as headers a custom client
  # adds, are meant for PostHog, and without Req's steps and the app's Req.default_options, such as
  # an auth or compress_body set for other requests. The storage gets the bytes and the headers
  # PostHog signed the upload with, nothing else.
  defp send_upload(connection, upload, content, timeout_ms) do
    request =
      Req.Request.new(
        method: :put,
        url: upload.url,
        headers: for({name, value} <- upload.headers, do: {String.downcase(name), value}),
        body: content,
        options: [receive_timeout: timeout_ms]
      )
      |> with_upload_adapter(connection.upload_adapter)

    run_request(connection, timeout_ms, fn ->
      case Req.Request.run_request(request) do
        {_request, %Req.Response{} = response} -> {:ok, response}
        {_request, exception} -> {:error, exception}
      end
    end)
  end

  # Req's own default adapter, which differs between Req versions, unless a test sets one.
  defp with_upload_adapter(request, nil), do: request

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

  defp with_retries(connection, max_retries, attempt_once, attempt \\ 0) do
    case attempt_once.() do
      {:ok, result} ->
        {:ok, result}

      {:error, %Error{} = error} ->
        case retry_delay_ms(error, attempt, max_retries) do
          nil ->
            {:error, error}

          delay_ms ->
            connection.sleep.(delay_ms)
            with_retries(connection, max_retries, attempt_once, attempt + 1)
        end
    end
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
          min(@max_retry_delay_ms, round(1000 * 2 ** attempt * (0.8 + :rand.uniform() * 0.4)))

        max(backoff, error.retry_after_ms || 0)
    end
  end

  # Replies

  defp parse_send_reply({:ok, status, fields, _retry_after}) when status in 200..299 do
    case text(fields["message_id"]) do
      nil ->
        {:error,
         Error.new("api_error", "PostHog answered without a message ID.", status_code: status)}

      id ->
        {:ok,
         %SendResult{
           id: id,
           replayed: fields["replayed"] == true,
           warnings: warnings(fields["warnings"])
         }}
    end
  end

  defp parse_send_reply(reply), do: reply_error(reply)

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

  defp warnings(warnings) when is_list(warnings) do
    for %{} = warning <- warnings do
      %Warning{
        code: text(warning["code"]) || "warning",
        message: text(warning["detail"]) || text(warning["message"]) || "",
        fix: text(warning["fix"])
      }
    end
  end

  defp warnings(_warnings), do: []

  defp log_warnings(%SendResult{warnings: warnings}) do
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

  defp reply_error({:error, error}), do: {:error, error}

  defp reply_error({:ok, status, fields, retry_after_ms}) do
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

  defp text(value) when is_binary(value) and value != "", do: value
  defp text(_value), do: nil

  defp unexpected(exception, message) do
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
