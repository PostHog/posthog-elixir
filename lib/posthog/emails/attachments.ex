defmodule PostHog.Emails.Attachments do
  @moduledoc false

  alias PostHog.Emails.Error

  @max_files 10
  @max_message_bytes 40_000_000
  @headers_and_mime_boundaries_bytes 64 * 1024
  @limit "10 files and 40 MB per email after Base64 encoding, about 29 MB of files"
  @fields [:filename, :content, :content_type, :content_id]
  @field_names Enum.map(@fields, &Atom.to_string/1)

  @type file() :: %{
          field: String.t(),
          filename: String.t(),
          content: binary(),
          sha256: String.t(),
          size: pos_integer(),
          reference: map()
        }

  @type upload() :: %{url: String.t(), headers: [{String.t(), String.t()}]}

  @doc """
  Checks the files and the size of the email they make with `bodies`, and hashes each file.
  """
  @spec prepare(term(), [String.t()]) :: {:ok, [file()]} | {:error, Error.t()}
  def prepare(attachments, bodies) when is_list(attachments) do
    # Hashing reads every byte, so it waits until the files are known to fit.
    with :ok <- check_count(attachments),
         {:ok, files} <- check_each(attachments),
         :ok <- check_size(files, bodies) do
      {:ok, Enum.map(files, &hash/1)}
    end
  end

  def prepare(_attachments, _bodies),
    do: invalid("attachments must be a list of files.", "attachments")

  @doc "The body of the upload request: each distinct file once."
  @spec upload_request([file()]) :: map()
  def upload_request(files),
    do: %{files: for(file <- distinct(files), do: %{sha256: file.sha256, size: file.size})}

  @doc """
  The files PostHog asks the SDK to upload, from its answer to the upload request, or `:error`
  when the answer leaves a file out or names an upload the SDK can't make.
  """
  @spec uploads(map(), [file()]) :: {:ok, [{file(), upload()}]} | :error
  def uploads(%{"files" => answers}, files) when is_list(answers),
    do: files |> distinct() |> uploads(answers, [])

  def uploads(_answer, _files), do: :error

  defp uploads([], _answers, uploads), do: {:ok, Enum.reverse(uploads)}

  defp uploads([file | files], answers, uploads) do
    answer = Enum.find(answers, &match?(%{"sha256" => sha256} when sha256 == file.sha256, &1))

    case upload(answer) do
      :present -> uploads(files, answers, uploads)
      {:ok, upload} -> uploads(files, answers, [{file, upload} | uploads])
      :error -> :error
    end
  end

  @doc """
  Names the option a refusal of the upload request is about: `attachments`, or one of them.
  PostHog names the upload request's `files`, and the caller passed `attachments`. A refusal of
  the files without a field, such as a PostHog without the upload route, is about
  `attachments`; one about the key, the scope, a rate limit or an outage names no option.
  """
  @spec field(Error.t(), [file()]) :: String.t() | nil
  def field(%Error{field: nil, status_code: status}, _files) when status in [400, 404, 413, 422],
    do: "attachments"

  def field(%Error{field: "files"}, _files), do: "attachments"
  def field(%Error{field: "files__" <> rest}, files), do: file_field(rest, files)
  def field(%Error{field: field}, _files), do: field

  defp file_field(rest, files) do
    with [index | _] <- String.split(rest, "__"),
         {index, ""} <- Integer.parse(index),
         %{field: field} <- Enum.at(distinct(files), index) do
      field <> "__content"
    else
      _other -> "attachments"
    end
  end

  @doc "The error of an upload that failed, with what the storage answered, if anything."
  @spec upload_failed(file(), String.t(), pos_integer() | nil, term()) :: Error.t()
  def upload_failed(file, url, status, body) do
    host = URI.parse(url).host

    answer =
      if status,
        do: "the storage answered #{s3_error(status, body)}",
        else: "the request failed"

    Error.new(
      "attachment_upload_failed",
      "Uploading #{file.filename} to #{host} failed: #{answer}.",
      status_code: status,
      field: file.field,
      why:
        "The SDK sends an email only once each of its files is uploaded, so no email was sent.",
      fix:
        "Send again. If it keeps failing, check that your app can reach #{host}, and that no proxy changes the upload."
    )
  end

  defp check_count(attachments) when length(attachments) > @max_files do
    {:error,
     Error.new(
       "too_many_attachments",
       "An email carries at most #{@max_files} files, so no email was sent.",
       field: "attachments",
       why: "PostHog sends at most #{@limit}.",
       fix: "Attach at most #{@max_files} files, and link to any others from the email body."
     )}
  end

  defp check_count(_attachments), do: :ok

  defp check_each(attachments) do
    attachments
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {attachment, index}, {:ok, files} ->
      case file(attachment, "attachments__#{index}") do
        {:ok, file} -> {:cont, {:ok, [file | files]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.reverse(files)}
      error -> error
    end
  end

  defp check_size(files, bodies) do
    sizes = Enum.map(files, & &1.size) ++ Enum.map(bodies, &byte_size/1)

    if base64_message_bytes(sizes) > @max_message_bytes do
      {:error,
       Error.new(
         "message_too_large",
         "These files make the email too large to send, so no email was sent.",
         field: "attachments",
         why:
           "PostHog sends emails up to 40 MB, and Base64 encoding makes each file and body about a third larger.",
         fix:
           "Keep the email under 40 MB after Base64 encoding, about 29 MB of files: attach fewer or smaller files, or link to large files from the email body."
       )}
    else
      :ok
    end
  end

  defp base64_message_bytes(sizes) do
    Enum.reduce(sizes, @headers_and_mime_boundaries_bytes, fn size, total ->
      total + ceil_div(ceil_div(size, 3) * 4 * 78, 76)
    end)
  end

  defp ceil_div(dividend, divisor), do: div(dividend + divisor - 1, divisor)

  defp file(attachment, field) when is_map(attachment) and not is_struct(attachment) do
    attachment = Map.reject(attachment, fn {_key, value} -> is_nil(value) end)

    with :ok <- check_keys(attachment, field),
         :ok <- check_values(attachment, field) do
      {:ok,
       %{
         field: field,
         filename: attachment.filename,
         content: attachment.content,
         size: byte_size(attachment.content),
         reference: Map.take(attachment, [:filename, :content_type, :content_id])
       }}
    end
  end

  defp file(_attachment, field),
    do: invalid("An attachment is a map with filename and content.", field)

  defp hash(file) do
    sha256 = :crypto.hash(:sha256, file.content) |> Base.encode16(case: :lower)
    %{file | reference: Map.put(file.reference, :sha256, sha256)} |> Map.put(:sha256, sha256)
  end

  defp check_keys(attachment, field) do
    unknown = attachment |> Map.keys() |> Enum.reject(&(&1 in @fields)) |> Enum.sort()

    cond do
      Map.has_key?(attachment, :path) ->
        invalid(
          "PostHog can't fetch an attachment from a path or URL. Read the file, for example " <>
            "with File.read!/1, and pass its bytes as content.",
          field <> "__path"
        )

      unknown != [] ->
        unknown_key(key_to_report(unknown), field)

      true ->
        :ok
    end
  end

  defp check_values(attachment, field) do
    cond do
      not is_binary(attachment[:filename]) ->
        invalid("An attachment needs its filename as a string.", field <> "__filename")

      not is_binary(attachment[:content]) ->
        invalid(
          "An attachment needs content: the file's bytes as a binary.",
          field <> "__content"
        )

      attachment.content == "" ->
        invalid(
          "An attachment's content is empty, so the recipient would get nothing to open.",
          field <> "__content"
        )

      key = Enum.find([:content_type, :content_id], &not_string?(attachment, &1)) ->
        invalid("An attachment's #{key} must be a string.", "#{field}__#{key}")

      true ->
        :ok
    end
  end

  defp not_string?(attachment, key),
    do: Map.has_key?(attachment, key) and not is_binary(attachment[key])

  defp key_to_report(unknown_keys),
    do: Enum.find(unknown_keys, hd(unknown_keys), &(&1 in @field_names))

  defp unknown_key(key, field) when key in @field_names,
    do: invalid(~s(Attachment keys are atoms: use :#{key}, not "#{key}".), "#{field}__#{key}")

  defp unknown_key(key, field) when is_atom(key) or is_binary(key),
    do: invalid(keys_message(key), "#{field}__#{key}")

  defp unknown_key(key, field), do: invalid(keys_message(inspect(key)), field)

  defp keys_message(key),
    do: "An attachment takes filename, content, content_type and content_id, not #{key}."

  defp invalid(message, field),
    do: {:error, Error.new("invalid_attachment", message, field: field)}

  defp distinct(files), do: Enum.uniq_by(files, & &1.sha256)

  defp upload(%{"status" => "present"}), do: :present

  defp upload(%{"status" => "upload", "url" => url, "method" => "PUT", "headers" => headers})
       when is_binary(url) and is_map(headers) do
    with %URI{scheme: scheme, host: host}
         when scheme in ["https", "http"] and is_binary(host) and host != "" <-
           URI.parse(url),
         true <- Enum.all?(headers, fn {name, value} -> is_binary(name) and is_binary(value) end) do
      {:ok, %{url: url, headers: Map.to_list(headers)}}
    else
      _unusable -> :error
    end
  end

  defp upload(_answer), do: :error

  defp s3_error(status, body) when is_binary(body) do
    case {xml_text(body, "Code"), xml_text(body, "Message")} do
      {nil, _message} ->
        "HTTP #{status}"

      {code, nil} ->
        "HTTP #{status} #{code}"

      {code, message} ->
        "HTTP #{status} #{code}: #{message |> String.slice(0, 300) |> String.trim_trailing(".")}"
    end
  end

  defp s3_error(status, _body), do: "HTTP #{status}"

  defp xml_text(body, tag) do
    case Regex.run(~r{<#{tag}>([^<]*)</#{tag}>}, body, capture: :all_but_first) do
      [text] when text != "" -> text
      _none -> nil
    end
  end
end
