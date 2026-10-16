defmodule PostHog.HandlerTraceContextIsolationTest do
  use ExUnit.Case, async: true

  for failure <- [:absent, :raise, :throw, :exit] do
    @failure failure

    test "captures exceptions when the OpenTelemetry API is #{@failure}" do
      script = """
      false = Code.ensure_loaded?(:otel_tracer)
      if #{@failure != :absent} do
        defmodule :otel_tracer do
          def current_span_ctx, do: #{@failure}("Example lookup failure")
        end
      end

      Application.load(:posthog)
      Application.put_env(:posthog, :enable, false)
      {:ok, _} = Application.ensure_all_started(:posthog)

      config = PostHog.Config.validate!(
        api_key: "example-key",
        api_host: "https://example.com",
        before_send: fn event -> send(self(), {:captured, event}); nil end
      )
      {:ok, _} = PostHog.Supervisor.start_link(config)
      :ok = :logger.add_handler(:trace_test, PostHog.Handler, %{config: config})

      require Logger
      Logger.error("Example failure", distinct_id: "example-user")

      receive do
        {:captured, %{event: "$exception", properties: properties}} ->
          if Map.has_key?(properties, :"$trace_id") or Map.has_key?(properties, :"$span_id"),
            do: raise("Unexpected derived trace IDs")
          IO.puts("exception captured")
      after
        0 -> raise "Exception was not captured"
      end
      """

      paths =
        :code.get_path()
        |> Enum.map(&List.to_string/1)
        |> Enum.reject(&(Path.basename(Path.dirname(&1)) == "opentelemetry_api"))
        |> Enum.flat_map(&["-pa", &1])

      {output, status} =
        System.cmd(System.find_executable("elixir"), paths ++ ["-e", script],
          stderr_to_stdout: true,
          env: [{"ERL_FLAGS", "+S 2:2"}]
        )

      assert status == 0, output
      assert output =~ "exception captured"
    end
  end
end
