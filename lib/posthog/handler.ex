defmodule PostHog.Handler do
  @moduledoc """
  A [`logger handler`](https://www.erlang.org/doc/apps/kernel/logger_chapter.html#handlers).
  """
  if System.otp_release() |> String.to_integer() >= 27 do
    @behaviour :logger_handler
  end

  alias PostHog.Context

  # credo:disable-for-next-line Credo.Check.Design.TagTODO
  # TODO: add @impl :logger_handler once we drop support for OTP < 27
  @doc false
  def log(log_event, %{config: config}) do
    maybe_properties =
      cond do
        get_in(log_event, [:meta, :crash_reason]) ->
          properties(log_event, config)

        is_nil(config.capture_level) ->
          nil

        Logger.compare_levels(log_event.level, config.capture_level) in [:gt, :eq] ->
          properties(log_event, config)

        true ->
          nil
      end

    with %{} = properties <- maybe_properties do
      PostHog.bare_capture(
        config.supervisor_name,
        "$exception",
        Map.get(properties, :distinct_id, "unknown"),
        properties
      )
    end

    :ok
  end

  defp properties(log_event, config) do
    exception =
      Enum.reduce(
        [&type/1, &value/1, &stacktrace(&1, config.in_app_modules)],
        %{
          mechanism: %{handled: not Map.has_key?(log_event.meta, :crash_reason), type: "generic"}
        },
        fn fun, acc ->
          Map.merge(acc, fun.(log_event))
        end
      )

    metadata =
      log_event.meta
      |> then(fn metadata ->
        if config.metadata == :all do
          Map.delete(metadata, Context.logger_metadata_key())
        else
          Map.take(metadata, [:distinct_id | config.metadata])
        end
      end)
      |> Map.drop(["$exception_list"])
      |> maybe_update_file_key()

    Context.get(config.supervisor_name, "$exception")
    |> enrich_context(log_event)
    |> Map.put(:"$exception_list", [exception])
    |> Map.merge(metadata)
  end

  defp type(log_event) do
    log_event
    |> do_type()
    |> String.split("\n")
    |> then(fn [type | _] -> %{type: type} end)
  end

  defp do_type(%{meta: %{crash_reason: {reason, _}}}) when is_exception(reason),
    do: inspect(reason.__struct__)

  defp do_type(%{meta: %{crash_reason: {{:nocatch, throw}, _}}}),
    do: Exception.format_banner(:throw, throw)

  defp do_type(%{meta: %{crash_reason: {reason, _}}}),
    do: Exception.format_banner(:exit, reason)

  defp do_type(%{msg: {:string, chardata}}), do: IO.chardata_to_string(chardata)

  defp do_type(%{msg: {:report, report}, meta: %{report_cb: report_cb}})
       when is_function(report_cb, 1) do
    {io_format, data} = report_cb.(report)

    io_format
    |> :io_lib.format(data)
    |> IO.chardata_to_string()
  end

  defp do_type(%{msg: {:report, report}}), do: inspect(report)

  defp do_type(%{msg: {io_format, data}}),
    do: io_format |> :io_lib.format(data) |> IO.chardata_to_string()

  defp value(%{meta: %{crash_reason: {reason, stacktrace}}}) when is_exception(reason),
    do: %{value: Exception.format_banner(:error, reason, stacktrace)}

  defp value(%{meta: %{crash_reason: {{:nocatch, throw}, stacktrace}}}),
    do: %{value: Exception.format_banner(:throw, throw, stacktrace)}

  defp value(%{meta: %{crash_reason: {reason, stacktrace}}}),
    do: %{value: Exception.format_banner(:exit, reason, stacktrace)}

  defp value(%{msg: {:string, chardata}}), do: %{value: IO.chardata_to_string(chardata)}

  defp value(%{msg: {:report, report}, meta: %{report_cb: report_cb}})
       when is_function(report_cb, 1) do
    {io_format, data} = report_cb.(report)
    io_format |> :io_lib.format(data) |> IO.chardata_to_string() |> then(&%{value: &1})
  end

  defp value(%{msg: {:report, report}}), do: %{value: inspect(report)}

  defp value(%{msg: {io_format, data}}),
    do: io_format |> :io_lib.format(data) |> IO.chardata_to_string() |> then(&%{value: &1})

  defp stacktrace(%{meta: %{crash_reason: {_reason, [_ | _] = stacktrace}}}, in_app_modules) do
    frames =
      for {module, function, arity_or_args, location} <- stacktrace do
        in_app = module in in_app_modules

        %{
          platform: "custom",
          lang: "elixir",
          function: Exception.format_mfa(module, function, arity_or_args),
          filename: Keyword.get(location, :file, []) |> IO.chardata_to_string(),
          lineno: Keyword.get(location, :line),
          module: inspect(module),
          in_app: in_app,
          resolved: true
        }
      end

    %{
      stacktrace: %{
        type: "raw",
        frames: frames
      }
    }
  end

  defp stacktrace(_event, _), do: %{}

  defp enrich_context(context, %{meta: %{conn: conn}}) when is_struct(conn, Plug.Conn) do
    case context do
      # Context was set and survived
      %{"$current_url" => _} ->
        context

      _ ->
        conn
        |> PostHog.Integrations.Plug.conn_to_context()
        |> Map.merge(context)
    end
  end

  defp enrich_context(context, _log_event), do: context

  defp maybe_update_file_key(%{file: chardata} = metadata) when is_list(chardata) do
    Map.update!(metadata, :file, &IO.chardata_to_string/1)
  rescue
    _ -> metadata
  end

  defp maybe_update_file_key(metadata), do: metadata
end
