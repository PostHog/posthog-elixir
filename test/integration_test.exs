defmodule PostHog.IntegrationTest do
  # Note that this test suite lacks assertions and is meant to assist with
  # manual testing. There is not much point in running all tests in it at once.
  # Instead, pick one test and iterate over it while checking PostHog UI.
  use ExUnit.Case, async: false

  require Logger

  alias PostHog.LLMAnalytics

  @moduletag integration: true

  setup_all do
    {:ok, config} =
      Application.fetch_env!(:posthog, :integration_config) |> PostHog.Config.validate()

    start_link_supervised!({PostHog.Supervisor, Map.put(config, :sender_pool_size, 1)})

    wait = fn ->
      sender_pid =
        config.supervisor_name
        |> PostHog.Registry.via(PostHog.Sender, 1)
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

  describe "llm analytics" do
    setup %{test: test} do
      PostHog.set_context(%{distinct_id: test})
      LLMAnalytics.set_trace()
      :ok
    end

    test "documentation example", %{wait_fun: wait} do
      LLMAnalytics.capture_span("$ai_generation", %{
        "$ai_model": "gpt-5-mini",
        "$ai_latency": 1.5,
        "$ai_tools": [],
        "$ai_input": [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "text", "text" => "What's in this image?"},
              %{"type" => "image", "image" => "https://example.com/image.jpg"},
              %{
                "type" => "function",
                "function" => %{
                  "name" => "get_weather",
                  "arguments" => %{"location" => "San Francisco"}
                }
              }
            ]
          }
        ],
        "$ai_input_tokens": 100,
        "$ai_output_choices": [
          %{
            "role" => "assistant",
            "content" => [
              %{"type" => "text", "text" => "I can see a hedgehog in the image."},
              %{
                "type" => "function",
                "function" => %{
                  "name" => "get_weather",
                  "arguments" => %{"location" => "San Francisco"}
                }
              }
            ]
          }
        ],
        "$ai_output_tokens": 100,
        "$ai_span_name": "first request",
        "$ai_provider": "openai",
        "$ai_http_status": 200,
        "$ai_base_url": "https://api.openai.com/v1",
        "$ai_request_url": "https://api.openai.com/v1/chat/completions",
        "$ai_is_error": false
      })

      wait.()
    end

    test "responses API example", %{wait_fun: wait} do
      LLMAnalytics.capture_span("$ai_generation", %{
        "$ai_model": "gpt-5-mini",
        "$ai_latency": 1.5,
        "$ai_tools": [],
        "$ai_input": [
          %{
            role: "user",
            content: "Cite me the greatest opening line in the history of cyberpunk."
          }
        ],
        "$ai_input_tokens": 20,
        "$ai_output_choices": [
          %{
            "id" => "rs_0ac5587e0b21fd390068c6f9781d9c8195afbc14299ff7dc4d",
            "summary" => [],
            "type" => "reasoning"
          },
          %{
            "content" => [
              %{
                "annotations" => [],
                "logprobs" => [],
                "text" =>
                  "\"The sky above the port was the color of television, tuned to a dead channel.\"\n— William Gibson, Neuromancer (Ace Books, 1984).\n\nMLA: Gibson, William. Neuromancer. Ace Books, 1984.\nAPA: Gibson, W. (1984). Neuromancer. New York: Ace Books.\nChicago: Gibson, William. 1984. Neuromancer. New York: Ace Books.\n\nWant other contender opening lines from cyberpunk to compare?",
                "type" => "output_text"
              }
            ],
            "id" => "msg_0ac5587e0b21fd390068c6f97f63b081958254bb3bfd344060",
            "role" => "assistant",
            "status" => "completed",
            "type" => "message"
          }
        ],
        "$ai_output_tokens": 619,
        "$ai_span_name": "first request",
        "$ai_provider": "openai",
        "$ai_http_status": 200,
        "$ai_base_url": "https://api.openai.com/v1",
        "$ai_request_url": "https://api.openai.com/v1/responses",
        "$ai_is_error": false
      })

      wait.()
    end

    test "tool call example", %{wait_fun: wait} do
      {:ok, span_id} =
        LLMAnalytics.capture_span("$ai_generation", %{
          "$ai_model": "gpt-5-mini",
          "$ai_latency": 1.5,
          "$ai_tools": [
            %{
              type: "function",
              name: "get_current_weather",
              description: "Get the current weather in a given location",
              parameters: %{
                type: "object",
                properties: %{
                  location: %{
                    type: "string",
                    description: "The city and state, e.g. San Francisco, CA"
                  },
                  unit: %{
                    type: "string",
                    enum: ["celsius", "fahrenheit"]
                  }
                },
                required: ["location", "unit"]
              }
            }
          ],
          "$ai_input": [
            %{
              role: "user",
              content: "Tell me weather in Vancouver"
            }
          ],
          "$ai_input_tokens": 79,
          "$ai_output_choices": [
            %{
              "id" => "rs_0ad5cc1dea87abd60068c6ffdcff78819380572ff4e3882cd9",
              "summary" => [],
              "type" => "reasoning"
            },
            %{
              "arguments" => "{\"unit\":\"celsius\",\"location\":\"Vancouver, BC\"}",
              "call_id" => "call_gdzLdDbo8TqAJRzsq39zMXPr",
              "id" => "fc_0ad5cc1dea87abd60068c6ffdedeec8193a6c39f4c57326b8b",
              "name" => "get_current_weather",
              "status" => "completed",
              "type" => "function_call"
            }
          ],
          "$ai_output_tokens": 93,
          "$ai_span_name": "ask for weather",
          "$ai_provider": "openai",
          "$ai_http_status": 200,
          "$ai_base_url": "https://api.openai.com/v1",
          "$ai_request_url": "https://api.openai.com/v1/responses",
          "$ai_is_error": false
        })

      LLMAnalytics.capture_span("$ai_span", %{
        "$ai_span_name": "tool_call",
        "$ai_parent_id": span_id,
        "$ai_input_state": %{"unit" => "celsius", "location" => "Vancouver, BC"},
        "$ai_output_state": "17ºC",
        "$ai_latency": 0.361,
        "$ai_is_error": false,
        "$ai_error": nil
      })

      wait.()
    end
  end
end
