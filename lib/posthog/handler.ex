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
    exceptions = exceptions(log_event, config)

    metadata =
      log_event.meta
      |> then(fn metadata ->
        if config.metadata == :all do
          metadata
          |> Map.delete(Context.logger_metadata_key())
          |> Map.drop([
            :crash_reason,
            :error_logger,
            :gl,
            :report_cb
          ])
        else
          Map.take(metadata, [:distinct_id | config.metadata])
        end
      end)
      |> Map.drop(["$exception_list"])
      |> enrich_metadata(log_event)
      |> maybe_update_file_key()

    Context.get(config.supervisor_name, "$exception")
    |> enrich_context(log_event)
    |> Map.put(:"$exception_list", exceptions)
    |> Map.merge(metadata)
  end

  # Reports, such as GenServer crash, should be seen as downstream effects of
  # initial exceptions
  defp exceptions(%{meta: %{crash_reason: _}, msg: {:report, _}} = log_event, config) do
    initial_exception = exception(log_event, config)

    reporter_exception =
      log_event |> Map.update!(:meta, &Map.delete(&1, :crash_reason)) |> exception(config)

    [initial_exception, reporter_exception]
  end

  # Bare process crash shaped like complex error but it really isnt
  defp exceptions(
         %{meta: %{crash_reason: _, error_logger: %{emulator: true}}, msg: {:string, _}} =
           log_event,
         config
       ) do
    [exception(log_event, config)]
  end

  # Non-reports, such as log messages with attached crash_reason, should be seen
  # as primary errors and define grouping. 
  defp exceptions(%{meta: %{crash_reason: _}} = log_event, config) do
    initial_exception = exception(log_event, config)

    reporter_exception =
      log_event |> Map.update!(:meta, &Map.delete(&1, :crash_reason)) |> exception(config)

    [reporter_exception, initial_exception]
  end

  defp exceptions(log_event, config) do
    [exception(log_event, config)]
  end

  defp exception(log_event, config) do
    [&type/1, &value/1, &stacktrace(&1, config.in_app_modules)]
    |> Enum.reduce(
      %{
        mechanism: %{handled: not Map.has_key?(log_event.meta, :crash_reason), type: "generic"}
      },
      fn fun, acc ->
        Map.merge(acc, fun.(log_event))
      end
    )
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

  defp do_type(%{msg: {:report, %{label: {:gen_server, :terminate}}}}) do
    "GenServer terminating"
  end

  defp do_type(%{msg: {:report, %{label: {Task.Supervisor, :terminating}}}}) do
    "Task terminating"
  end

  defp do_type(%{msg: {:report, %{label: {:gen_statem, :terminate}}}}) do
    ":gen_statem terminating"
  end

  defp do_type(%{msg: {:report, %{label: {:proc_lib, :crash}}}}) do
    "Process terminating"
  end

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

  defp stacktrace(%{meta: %{crash_reason: {_reason, [_ | _] = stacktrace}}}, in_app_modules),
    do: %{stacktrace: do_stacktrace(stacktrace, in_app_modules)}

  defp stacktrace(
         %{msg: {:report, %{client_info: {_, {_, [_ | _] = stacktrace}}}}},
         in_app_modules
       ),
       do: %{stacktrace: do_stacktrace(stacktrace, in_app_modules)}

  defp stacktrace(_event, _), do: %{}

  defp do_stacktrace([_ | _] = stacktrace, in_app_modules) do
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
      type: "raw",
      frames: frames
    }
  end

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

  defp enrich_metadata(metadata, log_event) do
    [
      :genserver_name,
      :genserver_state,
      :genserver_last_message,
      :genserver_process_label,
      :genserver_client,
      :task_name,
      :task_process_label,
      :task_starter,
      :gen_statem_name,
      :gen_statem_state,
      :gen_statem_queue,
      :gen_statem_client,
      :gen_statem_process_label,
      :gen_statem_callback_mode,
      :gen_statem_postponed,
      :gen_statem_state_enter
    ]
    |> Enum.reduce(metadata, fn key, acc ->
      key |> extract_extra_meta(log_event) |> Map.merge(acc)
    end)
  end

  defp extract_extra_meta(:genserver_name, %{
         msg: {:report, %{label: {:gen_server, :terminate}, name: name}}
       }),
       do: %{genserver_name: name}

  defp extract_extra_meta(:genserver_state, %{
         msg: {:report, %{label: {:gen_server, :terminate}, state: state}}
       }),
       do: %{genserver_state: state}

  defp extract_extra_meta(:genserver_last_message, %{
         msg: {:report, %{label: {:gen_server, :terminate}, last_message: last_message}}
       }),
       do: %{genserver_last_message: last_message}

  defp extract_extra_meta(:genserver_process_label, %{
         msg: {:report, %{label: {:gen_server, :terminate}, process_label: process_label}}
       }),
       do: %{genserver_process_label: process_label}

  defp extract_extra_meta(:genserver_client, %{
         msg: {:report, %{label: {:gen_server, :terminate}, client_info: {_, {client, _}}}}
       }),
       do: %{genserver_client: client}

  defp extract_extra_meta(:genserver_client, %{
         msg: {:report, %{label: {:gen_server, :terminate}, client_info: {client, _}}}
       }),
       do: %{genserver_client: client}

  defp extract_extra_meta(:task_name, %{
         msg: {:report, %{label: {Task.Supervisor, :terminating}, report: %{name: name}}}
       }),
       do: %{task_name: name}

  defp extract_extra_meta(:task_process_label, %{
         msg:
           {:report,
            %{label: {Task.Supervisor, :terminating}, report: %{process_label: process_label}}}
       }),
       do: %{task_process_label: process_label}

  defp extract_extra_meta(:task_starter, %{
         msg: {:report, %{label: {Task.Supervisor, :terminating}, report: %{starter: starter}}}
       }),
       do: %{task_starter: starter}

  defp extract_extra_meta(:gen_statem_name, %{
         msg: {:report, %{label: {:gen_statem, :terminate}, name: name}}
       }),
       do: %{gen_statem_name: name}

  defp extract_extra_meta(:gen_statem_state, %{
         msg: {:report, %{label: {:gen_statem, :terminate}, state: state}}
       }),
       do: %{gen_statem_state: state}

  defp extract_extra_meta(:gen_statem_queue, %{
         msg: {:report, %{label: {:gen_statem, :terminate}, queue: queue}}
       }),
       do: %{gen_statem_queue: queue}

  defp extract_extra_meta(:gen_statem_client, %{
         msg: {:report, %{label: {:gen_statem, :terminate}, client_info: {_, {client, _}}}}
       }),
       do: %{gen_statem_client: client}

  defp extract_extra_meta(:gen_statem_client, %{
         msg: {:report, %{label: {:gen_statem, :terminate}, client_info: {client, _}}}
       }),
       do: %{gen_statem_client: client}

  defp extract_extra_meta(:gen_statem_process_label, %{
         msg: {:report, %{label: {:gen_statem, :terminate}, process_label: process_label}}
       }),
       do: %{gen_statem_process_label: process_label}

  defp extract_extra_meta(:gen_statem_callback_mode, %{
         msg: {:report, %{label: {:gen_statem, :terminate}, callback_mode: callback_mode}}
       }),
       do: %{gen_statem_callback_mode: callback_mode}

  defp extract_extra_meta(:gen_statem_postponed, %{
         msg: {:report, %{label: {:gen_statem, :terminate}, postponed: postponed}}
       }),
       do: %{gen_statem_postponed: postponed}

  defp extract_extra_meta(:gen_statem_state_enter, %{
         msg: {:report, %{label: {:gen_statem, :terminate}, state_enter: state_enter}}
       }),
       do: %{gen_statem_state_enter: state_enter}

  defp extract_extra_meta(_, _), do: %{}
end
