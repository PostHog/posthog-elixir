defmodule PostHog.IntegrationTest do
  require Config
  use ExUnit.Case, async: false

  require Logger

  @moduletag integration: true

  setup_all do
    {:ok, config} =
      Application.fetch_env!(:posthog, :integration_config) |> PostHog.Config.validate()

    start_link_supervised!({PostHog.Supervisor, config})

    wait = fn ->
      sender_pid =
        config.supervisor_name
        |> PostHog.Registry.via(PostHog.Sender)
        |> GenServer.whereis()

      send(sender_pid, :batch_time_reached)
      :sys.get_status(sender_pid)
    end

    :logger.add_handler(:posthog, PostHog.Handler, %{config: config})

    %{wait_fun: wait}
  end

  describe "error tracking" do
    setup %{test: test} do
      Logger.metadata(distinct_id: test)
    end

    test "log message", %{wait_fun: wait} do
      Logger.info("Hello World!")
      wait.()
    end

    test "genserver crash exception", %{wait_fun: wait} do
      LoggerHandlerKit.Act.genserver_crash(:exception)
      wait.()
    end

    test "task exception", %{wait_fun: wait} do
      LoggerHandlerKit.Act.task_error(:exception)
      wait.()
    end

    test "task throw", %{wait_fun: wait} do
      LoggerHandlerKit.Act.task_error(:throw)
      wait.()
    end

    test "task exit", %{wait_fun: wait} do
      LoggerHandlerKit.Act.task_error(:exit)
      wait.()
    end

    test "exports metadata", %{wait_fun: wait} do
      LoggerHandlerKit.Act.metadata_serialization(:all)
      Logger.error("Error with metadata")
      wait.()
    end

    test "supervisor report", %{wait_fun: wait} do
      Application.stop(:logger)
      Application.put_env(:logger, :handle_sasl_reports, true)
      Application.put_env(:logger, :level, :info)
      Application.start(:logger)

      on_exit(fn ->
        Application.stop(:logger)
        Application.put_env(:logger, :handle_sasl_reports, false)
        Application.delete_env(:logger, :level)
        Application.start(:logger)
      end)

      LoggerHandlerKit.Act.supervisor_progress_report(:failed_to_start_child)
      wait.()
    end
  end

  describe "event capture" do
    test "captures event", %{test: test, wait_fun: wait} do
      PostHog.capture("case tested", test, %{number: 1})
      wait.()
    end
  end
end
