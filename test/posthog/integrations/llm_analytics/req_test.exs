defmodule PostHog.Integrations.LLMAnalytics.ReqTest do
  use PostHog.Case, async: true

  alias PostHog.LLMAnalytics

  @supervisor_name __MODULE__
  @mock_module LLMock

  @moduletag config: [supervisor_name: @supervisor_name]

  setup :setup_supervisor
  setup {Req.Test, :verify_on_exit!}

  setup %{test: test} do
    PostHog.set_context(@supervisor_name, %{distinct_id: test})

    %{
      req:
        Req.new()
        |> PostHog.Integrations.LLMAnalytics.Req.attach(
          plug: {Req.Test, @mock_module},
          posthog_supervisor: @supervisor_name
        )
    }
  end

  test "captures bare minimum if everything is empty", %{req: req} do
    Req.Test.expect(@mock_module, fn conn ->
      Req.Test.json(conn, %{})
    end)

    assert %{status: 200, body: %{}} = Req.post!(req, url: "http://localhost/chat/completions")

    assert [
             %{
               event: "$ai_generation",
               properties: %{
                 "$ai_latency": latency,
                 "$ai_http_status": 200,
                 "$ai_base_url": "http://localhost",
                 "$ai_request_url": "http://localhost/chat/completions"
               }
             }
           ] = all_captured(@supervisor_name)

    assert is_float(latency)
  end

  test "captures for current span if open", %{req: req} do
    Req.Test.expect(@mock_module, fn conn ->
      Req.Test.json(conn, %{})
    end)

    span_id = LLMAnalytics.start_span(@supervisor_name)

    assert %{status: 200, body: %{}} = Req.post!(req, url: "http://localhost/chat/completions")

    assert [
             %{
               event: "$ai_generation",
               properties: %{"$ai_span_id": ^span_id}
             }
           ] = all_captured(@supervisor_name)
  end

  test "captures errors", %{req: req} do
    Req.Test.expect(@mock_module, fn conn ->
      conn
      |> Plug.Conn.put_status(429)
      |> Req.Test.json(%{
        "error" => %{
          "code" => "insufficient_quota",
          "message" =>
            "You exceeded your current quota, please check your plan and billing details. For more information on this error, read the docs: https://platform.openai.com/docs/guides/error-codes/api-errors.",
          "param" => nil,
          "type" => "insufficient_quota"
        }
      })
    end)

    assert %{status: 429, body: %{}} =
             Req.post!(req,
               url: "https://api.openai.com/v1/responses",
               json: %{
                 model: "gpt-5-mini",
                 input: "Cite me the greatest opening line in the history of cyberpunk."
               }
             )

    assert [
             %{
               event: "$ai_generation",
               properties: %{
                 "$ai_base_url": "https://api.openai.com/v1",
                 "$ai_http_status": 429,
                 "$ai_input": "Cite me the greatest opening line in the history of cyberpunk.",
                 "$ai_provider": "openai",
                 "$ai_request_url": "https://api.openai.com/v1/responses",
                 "$ai_is_error": true,
                 "$ai_error": %{}
               }
             }
           ] = all_captured(@supervisor_name)
  end

  test "captures transport errors", %{req: req} do
    Req.Test.expect(@mock_module, fn conn ->
      Req.Test.transport_error(conn, :timeout)
    end)

    assert {:error, %Req.TransportError{}} =
             Req.post(req,
               url: "https://api.openai.com/v1/responses",
               json: %{
                 model: "gpt-5-mini",
                 input: "Cite me the greatest opening line in the history of cyberpunk."
               }
             )

    assert [
             %{
               event: "$ai_generation",
               properties: %{
                 "$ai_base_url": "https://api.openai.com/v1",
                 "$ai_input": "Cite me the greatest opening line in the history of cyberpunk.",
                 "$ai_provider": "openai",
                 "$ai_request_url": "https://api.openai.com/v1/responses",
                 "$ai_is_error": true,
                 "$ai_error": "timeout"
               }
             }
           ] = all_captured(@supervisor_name)
  end

  test "captures OpenAI Responses properties", %{req: req} do
    Req.Test.expect(@mock_module, fn conn ->
      Req.Test.json(conn, %{
        "background" => false,
        "billing" => %{"payer" => "openai"},
        "created_at" => 1_762_633_410,
        "error" => nil,
        "id" => "resp_0ec7c3d0dd738b5300690fa6c20f8c819ea37dd4eef5168b68",
        "incomplete_details" => nil,
        "instructions" => nil,
        "max_output_tokens" => nil,
        "max_tool_calls" => nil,
        "metadata" => %{},
        "model" => "gpt-5-mini-2025-08-07",
        "object" => "response",
        "output" => [
          %{
            "id" => "rs_0ec7c3d0dd738b5300690fa6c27648819e979d7e7fbe609727",
            "summary" => [],
            "type" => "reasoning"
          },
          %{
            "content" => [
              %{
                "annotations" => [],
                "logprobs" => [],
                "text" =>
                  "\"The sky above the port was the color of television, tuned to a dead channel.\"\n\n— William Gibson, Neuromancer (Ace Books, 1984), opening line.",
                "type" => "output_text"
              }
            ],
            "id" => "msg_0ec7c3d0dd738b5300690fa6cf19b0819e9a7b3d9578566939",
            "role" => "assistant",
            "status" => "completed",
            "type" => "message"
          }
        ],
        "parallel_tool_calls" => true,
        "previous_response_id" => nil,
        "prompt_cache_key" => nil,
        "prompt_cache_retention" => nil,
        "reasoning" => %{"effort" => "medium", "summary" => nil},
        "safety_identifier" => nil,
        "service_tier" => "default",
        "status" => "completed",
        "store" => true,
        "temperature" => 1.0,
        "text" => %{"format" => %{"type" => "text"}, "verbosity" => "medium"},
        "tool_choice" => "auto",
        "tools" => [],
        "top_logprobs" => 0,
        "top_p" => 1.0,
        "truncation" => "disabled",
        "usage" => %{
          "input_tokens" => 20,
          "input_tokens_details" => %{"cached_tokens" => 0},
          "output_tokens" => 873,
          "output_tokens_details" => %{"reasoning_tokens" => 832},
          "total_tokens" => 893
        },
        "user" => nil
      })
    end)

    assert %{status: 200, body: %{}} =
             Req.post!(req,
               url: "https://api.openai.com/v1/responses",
               json: %{
                 model: "gpt-5-mini",
                 input: "Cite me the greatest opening line in the history of cyberpunk."
               }
             )

    assert [
             %{
               event: "$ai_generation",
               properties: %{
                 "$ai_base_url": "https://api.openai.com/v1",
                 "$ai_http_status": 200,
                 "$ai_input": "Cite me the greatest opening line in the history of cyberpunk.",
                 "$ai_input_tokens": 20,
                 "$ai_model": "gpt-5-mini-2025-08-07",
                 "$ai_output_choices": [
                   %{
                     "id" => "rs_0ec7c3d0dd738b5300690fa6c27648819e979d7e7fbe609727",
                     "summary" => [],
                     "type" => "reasoning"
                   },
                   %{
                     "content" => [
                       %{
                         "annotations" => [],
                         "logprobs" => [],
                         "text" =>
                           "\"The sky above the port was the color of television, tuned to a dead channel.\"\n\n— William Gibson, Neuromancer (Ace Books, 1984), opening line.",
                         "type" => "output_text"
                       }
                     ],
                     "id" => "msg_0ec7c3d0dd738b5300690fa6cf19b0819e9a7b3d9578566939",
                     "role" => "assistant",
                     "status" => "completed",
                     "type" => "message"
                   }
                 ],
                 "$ai_output_tokens": 873,
                 "$ai_provider": "openai",
                 "$ai_request_url": "https://api.openai.com/v1/responses",
                 "$ai_is_error": false
               }
             }
           ] = all_captured(@supervisor_name)
  end

  test "captures OpenAI Chat Completions properties", %{req: req} do
    Req.Test.expect(@mock_module, fn conn ->
      Req.Test.json(conn, %{
        "choices" => [
          %{
            "finish_reason" => "stop",
            "index" => 0,
            "message" => %{
              "annotations" => [],
              "content" =>
                "\"The sky above the port was the color of television, tuned to a dead channel.\"\n\n— William Gibson, Neuromancer (Ace Books, 1984).",
              "refusal" => nil,
              "role" => "assistant"
            }
          }
        ],
        "created" => 1_762_633_739,
        "id" => "chatcmpl-CZjqN8CQTG1dX9GUXy8opa6EtSeLM",
        "model" => "gpt-5-mini-2025-08-07",
        "object" => "chat.completion",
        "service_tier" => "default",
        "system_fingerprint" => nil,
        "usage" => %{
          "completion_tokens" => 809,
          "completion_tokens_details" => %{
            "accepted_prediction_tokens" => 0,
            "audio_tokens" => 0,
            "reasoning_tokens" => 768,
            "rejected_prediction_tokens" => 0
          },
          "prompt_tokens" => 20,
          "prompt_tokens_details" => %{"audio_tokens" => 0, "cached_tokens" => 0},
          "total_tokens" => 829
        }
      })
    end)

    assert %{status: 200, body: %{}} =
             Req.post!(req,
               url: "https://api.openai.com/v1/chat/completions",
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

    assert [
             %{
               event: "$ai_generation",
               properties: %{
                 "$ai_base_url": "https://api.openai.com/v1",
                 "$ai_http_status": 200,
                 "$ai_input": [
                   %{
                     role: "user",
                     content: "Cite me the greatest opening line in the history of cyberpunk."
                   }
                 ],
                 "$ai_input_tokens": 20,
                 "$ai_model": "gpt-5-mini-2025-08-07",
                 "$ai_output_choices": [
                   %{
                     "finish_reason" => "stop",
                     "index" => 0,
                     "message" => %{
                       "annotations" => [],
                       "content" =>
                         "\"The sky above the port was the color of television, tuned to a dead channel.\"\n\n— William Gibson, Neuromancer (Ace Books, 1984).",
                       "refusal" => nil,
                       "role" => "assistant"
                     }
                   }
                 ],
                 "$ai_output_tokens": 809,
                 "$ai_provider": "openai",
                 "$ai_request_url": "https://api.openai.com/v1/chat/completions",
                 "$ai_is_error": false
               }
             }
           ] = all_captured(@supervisor_name)
  end
end
