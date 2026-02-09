defmodule PostHog.IntegrationTest do
  # Note that this test suite lacks assertions and is meant to assist with
  # manual testing. There is not much point in running all tests in it at once.
  # Instead, pick one test and iterate over it while checking PostHog UI.
  use ExUnit.Case, async: false

  require Logger

  alias PostHog.Integrations.LLMAnalytics.Req, as: LLMReq
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
      LLMAnalytics.set_session()
      LLMAnalytics.set_trace()
      :ok
    end

    test "OpenAI Responses", %{wait_fun: wait} do
      Req.new()
      |> LLMReq.attach()
      |> Req.post!(
        url: "https://api.openai.com/v1/responses",
        auth: {:bearer, Application.get_env(:posthog, :openai_key)},
        json: %{
          model: "gpt-5-mini",
          input: "Cite me the greatest opening line in the history of cyberpunk."
        }
      )

      wait.()
    end

    test "OpenAI Chat Completions", %{wait_fun: wait} do
      Req.new()
      |> LLMReq.attach()
      |> Req.post!(
        url: "https://api.openai.com/v1/chat/completions",
        auth: {:bearer, Application.get_env(:posthog, :openai_key)},
        json: %{
          model: "gpt-5-mini",
          messages: [
            %{
              role: "user",
              content: "Cite me the greatest opening line in the history of cyberpunk."
            }
          ]
        }
      )

      wait.()
    end

    test "OpenAI Responses with tool", %{wait_fun: wait} do
      Req.new()
      |> LLMReq.attach()
      |> Req.post!(
        url: "https://api.openai.com/v1/responses",
        auth: {:bearer, Application.get_env(:posthog, :openai_key)},
        json: %{
          model: "gpt-5-mini",
          input: "Tell me weather in Vancouver",
          tools: [
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
          ]
        }
      )

      wait.()
    end

    test "OpenAI Chat Completions with tool", %{wait_fun: wait} do
      Req.new()
      |> LLMReq.attach()
      |> Req.post!(
        url: "https://api.openai.com/v1/chat/completions",
        auth: {:bearer, Application.get_env(:posthog, :openai_key)},
        json: %{
          model: "gpt-5-mini",
          messages: [%{role: "user", content: "Tell me weather in Vancouver, BC"}],
          tools: [
            %{
              type: "function",
              function: %{
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
            }
          ]
        }
      )

      wait.()
    end

    test "Gemini", %{wait_fun: wait} do
      Req.new()
      |> LLMReq.attach()
      |> Req.post!(
        url: "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent",
        headers: [{"x-goog-api-key", Application.get_env(:posthog, :gemini_key)}],
        path_params: [model: "gemini-2.5-flash"],
        path_params_style: :curly,
        json: %{
          contents: %{
            parts: [
              %{text: "Cite me the greatest opening line in the history of cyberpunk."}
            ]
          }
        }
      )

      wait.()
    end

    test "Gemini with tool", %{wait_fun: wait} do
      Req.new()
      |> LLMReq.attach()
      |> Req.post!(
        url: "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent",
        headers: [{"x-goog-api-key", Application.get_env(:posthog, :gemini_key)}],
        path_params: [model: "gemini-2.5-flash"],
        path_params_style: :curly,
        json: %{
          contents: %{
            parts: [
              %{text: "Tell me weather in Vancouver, BC. Celsius."}
            ]
          },
          tools: [
            %{
              functionDeclarations: [
                %{
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
              ]
            }
          ]
        }
      )

      wait.()
    end

    test "Anthropic", %{wait_fun: wait} do
      Req.new()
      |> LLMReq.attach()
      |> Req.post!(
        url: "https://api.anthropic.com/v1/messages",
        headers: [
          {"x-api-key", Application.get_env(:posthog, :anthropic_key)},
          {"anthropic-version", "2023-06-01"}
        ],
        json: %{
          messages: [
            %{
              role: :user,
              content: "Cite me the greatest opening line in the history of cyberpunk."
            }
          ],
          max_tokens: 1024,
          model: "claude-haiku-4-5"
        }
      )

      wait.()
    end

    test "Anthropic with tool", %{wait_fun: wait} do
      Req.new()
      |> LLMReq.attach()
      |> Req.post!(
        url: "https://api.anthropic.com/v1/messages",
        headers: [
          {"x-api-key", Application.get_env(:posthog, :anthropic_key)},
          {"anthropic-version", "2023-06-01"}
        ],
        json: %{
          messages: [%{role: :user, content: "Tell me weather in Vancouver, BC. Celsius."}],
          max_tokens: 1024,
          model: "claude-haiku-4-5",
          tools: [
            %{
              name: "get_current_weather",
              description: "Get the current weather in a given location",
              input_schema: %{
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
          ]
        }
      )

      wait.()
    end
  end
end
