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
                 "$ai_temperature": 1.0,
                 "$ai_is_error": false
               }
             }
           ] = all_captured(@supervisor_name)
  end

  test "captures OpenAI Responses properties with tools", %{req: req} do
    Req.Test.expect(@mock_module, fn conn ->
      Req.Test.json(conn, %{
        "background" => false,
        "billing" => %{"payer" => "openai"},
        "created_at" => 1_762_639_304,
        "error" => nil,
        "id" => "resp_0d66366be310730a00690fbdc80b80819e87f4c4d6f3660fd2",
        "incomplete_details" => nil,
        "instructions" => nil,
        "max_output_tokens" => nil,
        "max_tool_calls" => nil,
        "metadata" => %{},
        "model" => "gpt-5-mini-2025-08-07",
        "object" => "response",
        "output" => [
          %{
            "id" => "rs_0d66366be310730a00690fbdc87ec4819e9fe151f6b38fe50a",
            "summary" => [],
            "type" => "reasoning"
          },
          %{
            "arguments" => "{\"unit\":\"celsius\",\"location\":\"Vancouver, BC\"}",
            "call_id" => "call_EE2yXpU9vjsy7iHabR76gM2l",
            "id" => "fc_0d66366be310730a00690fbdc9d8f0819e8d96327bdf8a7761",
            "name" => "get_current_weather",
            "status" => "completed",
            "type" => "function_call"
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
        "tools" => [
          %{
            "description" => "Get the current weather in a given location",
            "name" => "get_current_weather",
            "parameters" => %{
              "additionalProperties" => false,
              "properties" => %{
                "location" => %{
                  "description" => "The city and state, e.g. San Francisco, CA",
                  "type" => "string"
                },
                "unit" => %{"enum" => ["celsius", "fahrenheit"], "type" => "string"}
              },
              "required" => ["unit", "location"],
              "type" => "object"
            },
            "strict" => true,
            "type" => "function"
          }
        ],
        "top_logprobs" => 0,
        "top_p" => 1.0,
        "truncation" => "disabled",
        "usage" => %{
          "input_tokens" => 76,
          "input_tokens_details" => %{"cached_tokens" => 0},
          "output_tokens" => 93,
          "output_tokens_details" => %{"reasoning_tokens" => 64},
          "total_tokens" => 169
        },
        "user" => nil
      })
    end)

    assert %{status: 200, body: %{}} =
             Req.post!(req,
               url: "https://api.openai.com/v1/responses",
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

    assert [
             %{
               event: "$ai_generation",
               properties: %{
                 "$ai_base_url": "https://api.openai.com/v1",
                 "$ai_http_status": 200,
                 "$ai_input": "Tell me weather in Vancouver",
                 "$ai_input_tokens": 76,
                 "$ai_model": "gpt-5-mini-2025-08-07",
                 "$ai_output_choices": [
                   %{
                     "id" => "rs_0d66366be310730a00690fbdc87ec4819e9fe151f6b38fe50a",
                     "summary" => [],
                     "type" => "reasoning"
                   },
                   %{
                     "id" => "fc_0d66366be310730a00690fbdc9d8f0819e8d96327bdf8a7761",
                     "status" => "completed",
                     "type" => "function_call",
                     "arguments" => "{\"unit\":\"celsius\",\"location\":\"Vancouver, BC\"}",
                     "call_id" => "call_EE2yXpU9vjsy7iHabR76gM2l",
                     "name" => "get_current_weather"
                   }
                 ],
                 "$ai_output_tokens": 93,
                 "$ai_provider": "openai",
                 "$ai_request_url": "https://api.openai.com/v1/responses",
                 "$ai_temperature": 1.0,
                 "$ai_tools": [
                   %{
                     "description" => "Get the current weather in a given location",
                     "name" => "get_current_weather",
                     "parameters" => %{
                       "additionalProperties" => false,
                       "properties" => %{
                         "location" => %{
                           "description" => "The city and state, e.g. San Francisco, CA",
                           "type" => "string"
                         },
                         "unit" => %{"enum" => ["celsius", "fahrenheit"], "type" => "string"}
                       },
                       "required" => ["unit", "location"],
                       "type" => "object"
                     },
                     "strict" => true,
                     "type" => "function"
                   }
                 ],
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
                 ],
                 temperature: 0.5
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
                 "$ai_temperature": 0.5,
                 "$ai_is_error": false
               }
             }
           ] = all_captured(@supervisor_name)
  end

  test "captures OpenAI Chat Completions properties with tools", %{req: req} do
    Req.Test.expect(@mock_module, fn conn ->
      Req.Test.json(conn, %{
        "choices" => [
          %{
            "finish_reason" => "tool_calls",
            "index" => 0,
            "message" => %{
              "annotations" => [],
              "content" => nil,
              "refusal" => nil,
              "role" => "assistant",
              "tool_calls" => [
                %{
                  "function" => %{
                    "arguments" => "{\"unit\":\"celsius\",\"location\":\"Vancouver, BC\"}",
                    "name" => "get_current_weather"
                  },
                  "id" => "call_tzyxFZeoSvg7ZSpdJxU0ogXb",
                  "type" => "function"
                }
              ]
            }
          }
        ],
        "created" => 1_762_639_511,
        "id" => "chatcmpl-CZlLTnJNNYuN6sFvyHukBaVjnNxIs",
        "model" => "gpt-5-mini-2025-08-07",
        "object" => "chat.completion",
        "service_tier" => "default",
        "system_fingerprint" => nil,
        "usage" => %{
          "completion_tokens" => 96,
          "completion_tokens_details" => %{
            "accepted_prediction_tokens" => 0,
            "audio_tokens" => 0,
            "reasoning_tokens" => 64,
            "rejected_prediction_tokens" => 0
          },
          "prompt_tokens" => 160,
          "prompt_tokens_details" => %{"audio_tokens" => 0, "cached_tokens" => 0},
          "total_tokens" => 256
        }
      })
    end)

    assert %{status: 200, body: %{}} =
             Req.post!(req,
               url: "https://api.openai.com/v1/chat/completions",
               json: %{
                 model: "gpt-5-mini",
                 messages: [%{role: "user", content: "Tell me weather in Vancouver, BC"}],
                 temperature: 0.5,
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

    assert [
             %{
               event: "$ai_generation",
               properties: %{
                 "$ai_base_url": "https://api.openai.com/v1",
                 "$ai_http_status": 200,
                 "$ai_input": [%{content: "Tell me weather in Vancouver, BC", role: "user"}],
                 "$ai_input_tokens": 160,
                 "$ai_model": "gpt-5-mini-2025-08-07",
                 "$ai_output_choices": [
                   %{
                     "finish_reason" => "tool_calls",
                     "index" => 0,
                     "message" => %{
                       "annotations" => [],
                       "content" => nil,
                       "refusal" => nil,
                       "role" => "assistant",
                       "tool_calls" => [
                         %{
                           "function" => %{
                             "arguments" =>
                               "{\"unit\":\"celsius\",\"location\":\"Vancouver, BC\"}",
                             "name" => "get_current_weather"
                           },
                           "id" => "call_tzyxFZeoSvg7ZSpdJxU0ogXb",
                           "type" => "function"
                         }
                       ]
                     }
                   }
                 ],
                 "$ai_output_tokens": 96,
                 "$ai_provider": "openai",
                 "$ai_request_url": "https://api.openai.com/v1/chat/completions",
                 "$ai_temperature": 0.5,
                 "$ai_tools": [
                   %{
                     function: %{
                       name: "get_current_weather",
                       description: "Get the current weather in a given location",
                       parameters: %{
                         type: "object",
                         required: ["location", "unit"],
                         properties: %{
                           unit: %{type: "string", enum: ["celsius", "fahrenheit"]},
                           location: %{
                             type: "string",
                             description: "The city and state, e.g. San Francisco, CA"
                           }
                         }
                       }
                     },
                     type: "function"
                   }
                 ],
                 "$ai_is_error": false
               }
             }
           ] = all_captured(@supervisor_name)
  end

  test "captures Gemini generateContent properties", %{req: req} do
    Req.Test.expect(@mock_module, fn conn ->
      Req.Test.json(conn, %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{
                  "text" =>
                    "The greatest opening line in the history of cyberpunk, arguably the most iconic and genre-defining, comes from the novel that started it all:\n\n**\"The sky above the port was the color of television, tuned to a dead channel.\"**\n\n— **William Gibson, *Neuromancer*** (1984)\n\n**Why it's so great:**\n\n1.  **Establishes the Aesthetic:** In a single, vivid simile, it perfectly captures the \"high tech, low life\" ethos of cyberpunk. It's an urban, gritty landscape (the \"port\") imbued with a technological metaphor (\"television, tuned to a dead channel\") that speaks of decay, static, information overload, and a world where technology is omnipresent but not necessarily pristine or hopeful.\n2.  **Immersive and Evocative:** It immediately drops the reader into a specific, slightly dystopian atmosphere without needing to explain anything further. You instantly *feel* the world.\n3.  **Influential:** This line, and the book it begins, fundamentally shaped the literary and visual language of cyberpunk across all media. It's instantly recognizable and frequently referenced."
                }
              ],
              "role" => "model"
            },
            "finishReason" => "STOP",
            "index" => 0
          }
        ],
        "modelVersion" => "gemini-2.5-flash",
        "responseId" => "ukoeaZ6wG8aM_PUPlbuE-A8",
        "usageMetadata" => %{
          "candidatesTokenCount" => 238,
          "promptTokenCount" => 12,
          "promptTokensDetails" => [%{"modality" => "TEXT", "tokenCount" => 12}],
          "thoughtsTokenCount" => 1169,
          "totalTokenCount" => 1419
        }
      })
    end)

    assert %{status: 200, body: %{}} =
             Req.post!(req,
               url:
                 "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent",
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

    assert [
             %{
               event: "$ai_generation",
               properties: %{
                 "$ai_base_url": "https://generativelanguage.googleapis.com/v1beta/models",
                 "$ai_http_status": 200,
                 "$ai_input": %{
                   parts: [
                     %{text: "Cite me the greatest opening line in the history of cyberpunk."}
                   ]
                 },
                 "$ai_input_tokens": 12,
                 "$ai_model": "gemini-2.5-flash",
                 "$ai_output_choices": [
                   %{
                     "index" => 0,
                     "content" => %{
                       "parts" => [%{"text" => "The greatest" <> _}],
                       "role" => "model"
                     },
                     "finishReason" => "STOP"
                   }
                 ],
                 "$ai_output_tokens": 1407,
                 "$ai_provider": "gemini",
                 "$ai_request_url":
                   "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent",
                 "$ai_is_error": false
               }
             }
           ] = all_captured(@supervisor_name)
  end

  test "captures Gemini generateContent properties with tools", %{req: req} do
    Req.Test.expect(@mock_module, fn conn ->
      Req.Test.json(conn, %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{
                  "functionCall" => %{
                    "args" => %{"location" => "Vancouver, BC", "unit" => "celsius"},
                    "name" => "get_current_weather"
                  },
                  "thoughtSignature" => "foo"
                }
              ],
              "role" => "model"
            },
            "finishMessage" => "Model generated function call(s).",
            "finishReason" => "STOP",
            "index" => 0
          }
        ],
        "modelVersion" => "gemini-2.5-flash",
        "responseId" => "mkweacCdFKDP_uMPz7f2CQ",
        "usageMetadata" => %{
          "candidatesTokenCount" => 25,
          "promptTokenCount" => 82,
          "promptTokensDetails" => [%{"modality" => "TEXT", "tokenCount" => 82}],
          "thoughtsTokenCount" => 206,
          "totalTokenCount" => 313
        }
      })
    end)

    assert %{status: 200, body: %{}} =
             Req.post!(req,
               url:
                 "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent",
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

    assert [
             %{
               event: "$ai_generation",
               properties: %{
                 "$ai_base_url": "https://generativelanguage.googleapis.com/v1beta/models",
                 "$ai_http_status": 200,
                 "$ai_input": %{parts: [%{text: "Tell me weather in Vancouver, BC. Celsius."}]},
                 "$ai_input_tokens": 82,
                 "$ai_model": "gemini-2.5-flash",
                 "$ai_output_choices": [
                   %{
                     "index" => 0,
                     "content" => %{
                       "parts" => [
                         %{
                           "functionCall" => %{
                             "args" => %{"location" => "Vancouver, BC", "unit" => "celsius"},
                             "name" => "get_current_weather"
                           },
                           "thoughtSignature" => "foo"
                         }
                       ],
                       "role" => "model"
                     },
                     "finishMessage" => "Model generated function call(s).",
                     "finishReason" => "STOP"
                   }
                 ],
                 "$ai_output_tokens": 231,
                 "$ai_provider": "gemini",
                 "$ai_request_url":
                   "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent",
                 "$ai_tools": [
                   %{
                     functionDeclarations: [
                       %{
                         name: "get_current_weather",
                         description: "Get the current weather in a given location",
                         parameters: %{
                           type: "object",
                           required: ["location", "unit"],
                           properties: %{
                             unit: %{type: "string", enum: ["celsius", "fahrenheit"]},
                             location: %{
                               type: "string",
                               description: "The city and state, e.g. San Francisco, CA"
                             }
                           }
                         }
                       }
                     ]
                   }
                 ],
                 "$ai_is_error": false
               }
             }
           ] = all_captured(@supervisor_name)
  end

  test "captures Anthropic create message properties", %{req: req} do
    Req.Test.expect(@mock_module, fn conn ->
      Req.Test.json(conn, %{
        "content" => [
          %{
            "text" =>
              "I'd argue for this one from **William Gibson's \"Neuromancer\" (1984)**:\n\n\"The sky above the port was the color of television, tuned to a dead channel.\"\n\nIt's often cited as one of the greatest opening lines in science fiction period. It's evocative, immediately establishes a gritty aesthetic, and perfectly captures that cyberpunk blend of high-tech futurity meeting urban decay. The image is both poetic and oddly mundane—comparing something vast to the banal experience of dead air on a TV screen.\n\nThat said, honorable mentions go to:\n- **Bruce Sterling's \"Schismatrix\"** for its ambitious far-future worldbuilding\n- **Pat Cadigan's work** for her psychological approach to cyberspace\n\nBut Gibson's opening has become almost archetypal—it defined what cyberpunk *feels* like for generations of readers and writers who followed.",
            "type" => "text"
          }
        ],
        "id" => "msg_01USjdBRtDVTcZCcVQMdtAnW",
        "model" => "claude-haiku-4-5-20251001",
        "role" => "assistant",
        "stop_reason" => "end_turn",
        "stop_sequence" => nil,
        "type" => "message",
        "usage" => %{
          "cache_creation" => %{
            "ephemeral_1h_input_tokens" => 0,
            "ephemeral_5m_input_tokens" => 0
          },
          "cache_creation_input_tokens" => 0,
          "cache_read_input_tokens" => 0,
          "inference_geo" => "not_available",
          "input_tokens" => 22,
          "output_tokens" => 205,
          "service_tier" => "standard"
        }
      })
    end)

    assert %{status: 200, body: %{}} =
             Req.post!(req,
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

    assert [
             %{
               event: "$ai_generation",
               properties: %{
                 "$ai_base_url": "https://api.anthropic.com/v1/messages",
                 "$ai_http_status": 200,
                 "$ai_input": [
                   %{
                     role: :user,
                     content: "Cite me the greatest opening line in the history of cyberpunk."
                   }
                 ],
                 "$ai_input_tokens": 22,
                 "$ai_model": "claude-haiku-4-5-20251001",
                 "$ai_output_choices": [
                   %{
                     "text" =>
                       "I'd argue for this one from **William Gibson's \"Neuromancer\" (1984)**:\n\n\"The sky above the port was the color of television, tuned to a dead channel.\"\n\nIt's often cited as one of the greatest opening lines in science fiction period. It's evocative, immediately establishes a gritty aesthetic, and perfectly captures that cyberpunk blend of high-tech futurity meeting urban decay. The image is both poetic and oddly mundane—comparing something vast to the banal experience of dead air on a TV screen.\n\nThat said, honorable mentions go to:\n- **Bruce Sterling's \"Schismatrix\"** for its ambitious far-future worldbuilding\n- **Pat Cadigan's work** for her psychological approach to cyberspace\n\nBut Gibson's opening has become almost archetypal—it defined what cyberpunk *feels* like for generations of readers and writers who followed.",
                     "type" => "text"
                   }
                 ],
                 "$ai_output_tokens": 205,
                 "$ai_provider": "anthropic",
                 "$ai_request_url": "https://api.anthropic.com/v1/messages",
                 "$ai_is_error": false
               }
             }
           ] = all_captured(@supervisor_name)
  end

  test "captures Anthropic with tools", %{req: req} do
    Req.Test.expect(@mock_module, fn conn ->
      Req.Test.json(conn, %{
        "content" => [
          %{
            "id" => "toolu_01TB42J8UvzAYvRwaQC4xT2R",
            "input" => %{"location" => "Vancouver, BC", "unit" => "celsius"},
            "name" => "get_current_weather",
            "type" => "tool_use"
          }
        ],
        "id" => "msg_012zLWPheFNRzjaGeMSr35u9",
        "model" => "claude-haiku-4-5-20251001",
        "role" => "assistant",
        "stop_reason" => "tool_use",
        "stop_sequence" => nil,
        "type" => "message",
        "usage" => %{
          "cache_creation" => %{
            "ephemeral_1h_input_tokens" => 0,
            "ephemeral_5m_input_tokens" => 0
          },
          "cache_creation_input_tokens" => 0,
          "cache_read_input_tokens" => 0,
          "inference_geo" => "not_available",
          "input_tokens" => 613,
          "output_tokens" => 75,
          "service_tier" => "standard"
        }
      })
    end)

    assert %{status: 200, body: %{}} =
             Req.post!(req,
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

    assert [
             %{
               event: "$ai_generation",
               properties: %{
                 "$ai_base_url": "https://api.anthropic.com/v1/messages",
                 "$ai_http_status": 200,
                 "$ai_input": [
                   %{role: :user, content: "Tell me weather in Vancouver, BC. Celsius."}
                 ],
                 "$ai_input_tokens": 613,
                 "$ai_model": "claude-haiku-4-5-20251001",
                 "$ai_output_choices": [
                   %{
                     "type" => "tool_use",
                     "id" => "toolu_01TB42J8UvzAYvRwaQC4xT2R",
                     "input" => %{"location" => "Vancouver, BC", "unit" => "celsius"},
                     "name" => "get_current_weather"
                   }
                 ],
                 "$ai_output_tokens": 75,
                 "$ai_provider": "anthropic",
                 "$ai_request_url": "https://api.anthropic.com/v1/messages",
                 "$ai_is_error": false,
                 "$ai_tools": [
                   %{
                     name: "get_current_weather",
                     description: "Get the current weather in a given location",
                     input_schema: %{
                       type: "object",
                       required: ["location", "unit"],
                       properties: %{
                         unit: %{type: "string", enum: ["celsius", "fahrenheit"]},
                         location: %{
                           type: "string",
                           description: "The city and state, e.g. San Francisco, CA"
                         }
                       }
                     }
                   }
                 ]
               }
             }
           ] = all_captured(@supervisor_name)
  end
end
