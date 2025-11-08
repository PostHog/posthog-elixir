defmodule PostHog.Integrations.LLMAnalytics.Req do
  @start_at_key :posthog_llm_analytics_start_at
  @properties_key :posthog_llm_analytics_properties

  alias PostHog.LLMAnalytics

  def attach(%Req.Request{} = request, options \\ []) do
    request
    |> Req.Request.register_options([:posthog_supervisor])
    |> Req.Request.merge_options(options)
    |> Req.Request.append_request_steps(
      posthog_llm_analytics_request_properties: &put_request_properties/1,
      posthog_llm_analytics_latency_start: &put_start_time/1
    )
    |> Req.Request.prepend_response_steps(posthog_llm_analytics_latency_stop: &put_latency/1)
    |> Req.Request.prepend_error_steps(
      posthog_llm_analytics_latency_stop: &put_latency/1,
      posthog_llm_analytics_error_properties: &put_error_properties/1
    )
    |> Req.Request.append_error_steps(
      posthog_llm_analytics_capture_generation: &capture_generation/1
    )
    |> Req.Request.append_response_steps(
      posthog_llm_analytics_response_properties: &put_response_properties/1,
      posthog_llm_analytics_capture_generation: &capture_generation/1
    )
  end

  defp put_start_time(request) do
    Req.Request.put_private(request, @start_at_key, System.monotonic_time())
  end

  defp put_latency({request, response}) do
    stop_time = System.monotonic_time()
    start_time = Req.Request.get_private(request, @start_at_key)
    latency = System.convert_time_unit(stop_time - start_time, :native, :millisecond) / 1000
    request = put_properties(request, %{"$ai_latency": latency})
    {request, response}
  end

  defp put_request_properties(request) do
    request
    |> put_properties(request_url_properties(request))
    |> put_properties(request_body_properties(request))
  end

  defp put_response_properties({request, response}) do
    properties =
      response.body
      |> response_properties()
      |> Map.put(:"$ai_http_status", response.status)

    {put_properties(request, properties), response}
  end

  defp put_error_properties({request, exception}) when is_exception(exception) do
    request =
      put_properties(request, %{"$ai_is_error": true, "$ai_error": Exception.message(exception)})

    {request, exception}
  end

  defp put_error_properties({request, exception}) do
    request = put_properties(request, %{"$ai_is_error": true, "$ai_error": inspect(exception)})
    {request, exception}
  end

  defp put_properties(request, properties) do
    Req.Request.update_private(request, @properties_key, properties, fn current ->
      Map.merge(current, properties)
    end)
  end

  defp capture_generation({request, response_or_exception}) do
    properties = Req.Request.get_private(request, @properties_key, %{})

    LLMAnalytics.capture_current_span(
      request.options[:posthog_supervisor] || PostHog,
      "$ai_generation",
      properties
    )

    {request, response_or_exception}
  end

  defp request_url_properties(
         %Req.Request{url: %URI{host: "api.openai.com", path: "/v1" <> _}} = request
       ) do
    %{
      "$ai_base_url": "https://api.openai.com/v1",
      "$ai_request_url": URI.to_string(request.url),
      "$ai_provider": "openai"
    }
  end

  defp request_url_properties(%Req.Request{} = request) do
    %{
      "$ai_base_url": URI.to_string(%{request.url | path: nil}),
      "$ai_request_url": URI.to_string(request.url)
    }
  end

  defp request_url_properties(_), do: %{}

  defp request_body_properties(%Req.Request{options: %{json: json_body}}),
    do: request_body_properties(json_body)

  # OpenAI Responses
  defp request_body_properties(%{input: input}), do: %{"$ai_input": input}
  defp request_body_properties(%{"input" => input}), do: %{"$ai_input": input}
  # OpenAI Chat Completions
  defp request_body_properties(%{messages: input}), do: %{"$ai_input": input}
  defp request_body_properties(%{"messages" => input}), do: %{"$ai_input": input}
  defp request_body_properties(_), do: %{}

  defp response_properties(%{
         "model" => model,
         "output" => output,
         "usage" => %{"output_tokens" => output_tokens, "input_tokens" => input_tokens}
       }) do
    %{
      "$ai_output_choices": output,
      "$ai_input_tokens": input_tokens,
      "$ai_output_tokens": output_tokens,
      "$ai_model": model,
      "$ai_is_error": false
    }
  end

  defp response_properties(%{
         "model" => model,
         "choices" => output,
         "usage" => %{"completion_tokens" => output_tokens, "prompt_tokens" => input_tokens}
       }) do
    %{
      "$ai_output_choices": output,
      "$ai_input_tokens": input_tokens,
      "$ai_output_tokens": output_tokens,
      "$ai_model": model,
      "$ai_is_error": false
    }
  end

  defp response_properties(%{"error" => error}) do
    %{
      "$ai_is_error": true,
      "$ai_error": error
    }
  end

  defp response_properties(_), do: %{}
end
