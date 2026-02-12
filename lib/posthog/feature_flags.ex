defmodule PostHog.FeatureFlags do
  @moduledoc """
  Convenience functions to work with Feature Flags API
  """

  @doc """
  Make request to [`/flags`](https://posthog.com/docs/api/flags) API.

  This function is a thin wrapper over a client call and is useful as a building
  block to build your own `check/3`. For example, this is a preferred
  way to access remote config payload.

  ## Examples

  Make request to `/flags` API:

      PostHog.FeatureFlags.flags(%{distinct_id: "user123"})

  Make request to `/flags` API with additional body params:

      PostHog.FeatureFlags.flags(%{distinct_id: "my_distinct_id", groups: %{group_type: "group_id"}})

  Make request to `/flags` API through a named PostHog instance:

      PostHog.FeatureFlags.flags(MyPostHog, %{distinct_id: "user123"})
  """
  @spec flags(PostHog.supervisor_name(), map()) ::
          PostHog.API.Client.response() | {:error, PostHog.Error.t()}
  def flags(name \\ PostHog, body) do
    config = PostHog.config(name)

    case PostHog.API.flags(config.api_client, body) do
      {:ok, %{status: 200, body: %{"flags" => _}}} = resp ->
        resp

      {:ok, %{status: 200, body: body}} ->
        {:error,
         %PostHog.UnexpectedResponseError{
           response: body,
           message: "Expected response body to have \"flags\" key"
         }}

      {:ok, resp} ->
        {:error, %PostHog.UnexpectedResponseError{response: resp, message: "Unexpected response"}}

      {:error, _} = error ->
        error
    end
  end

  @doc false
  def flags_for(distinct_id_or_body) when not is_atom(distinct_id_or_body),
    do: flags_for(PostHog, distinct_id_or_body)

  @doc """
  Get all feature flags.

  Accepts an optional `distinct_id` or a map with request body. If neither is
  passed, attempts to read `distinct_id` from the context.

  ## Examples

  Get all feature flags:

      PostHog.FeatureFlags.flags_for("user123")

  Get all feature flags with full request body:

      PostHog.FeatureFlags.flags_for(%{distinct_id: "user123", group: %{group_type: "group_id"}})

  Get all feature flags for `distinct_id` from the context:

      PostHog.set_context(%{distinct_id: "user123"})
      PostHog.FeatureFlags.flags_for()

  Get all feature flags through a named PostHog instance:

      PostHog.FeatureFlags.flags_for(MyPostHog, "foo")
  """
  @spec flags_for(PostHog.supervisor_name(), PostHog.distinct_id() | map() | nil) ::
          {:ok, map()} | {:error, Exception.t()}
  def flags_for(name \\ PostHog, distinct_id_or_body \\ nil) do
    with {:ok, body} <- body_for_flags(distinct_id_or_body),
         {:ok, %{body: %{"flags" => flags}}} <- flags(name, body) do
      {:ok, flags}
    end
  end

  @doc false
  def check(flag_name, distinct_id_or_body) when not is_atom(flag_name),
    do: check(PostHog, flag_name, distinct_id_or_body)

  @doc """
  Checks feature flag

  If there is a variant assigned, returns `{:ok, variant}`. Otherwise, `{:ok,
  true}` or `{:ok, false}`.

  Accepts an optional `distinct_id` or a map with request body. If neither is
  passed, attempts to read `distinct_id` from the context.

  This function will also
  [send](https://posthog.com/docs/api/flags#step-3-send-a-feature_flag_called-event)
  `$feature_flag_called` event and
  [set](https://posthog.com/docs/api/flags#step-2-include-feature-flag-information-when-capturing-events)
  `$feature/feature-flag-name` property in context.

  ## Examples

  Check boolean feature flag for `distinct_id`:

      iex> PostHog.FeatureFlags.check("example-feature-flag-1", "user123")
      {:ok, true}

  Check multivariant feature flag for `distinct_id` in the current context:

      iex> PostHog.set_context(%{distinct_id: "user123"})
      iex> PostHog.FeatureFlags.check("example-feature-flag-1")
      {:ok, "variant1"}

  Check boolean feature flag through a named PostHog instance:

      PostHog.check(MyPostHog, "example-feature-flag-1", "user123")
  """
  @spec check(PostHog.supervisor_name(), String.t(), PostHog.distinct_id() | map() | nil) ::
          {:ok, boolean()} | {:ok, String.t()} | {:error, Exception.t()}
  def check(name \\ PostHog, flag_name, distinct_id_or_body \\ nil) do
    case evaluate_flag(name, flag_name, distinct_id_or_body, []) do
      {:ok, %__MODULE__.Result{} = flag_result, _body} ->
        {:ok, __MODULE__.Result.value(flag_result)}

      {:ok, nil, body} ->
        {:error,
         %PostHog.UnexpectedResponseError{
           response: body,
           message: "Feature flag #{flag_name} was not found in the response"
         }}

      {:error, reason, _body} ->
        {:error, reason}
    end
  end

  @doc false
  def get_feature_flag_result(flag_name, distinct_id_or_body)
      when not is_atom(flag_name) and not is_list(distinct_id_or_body),
      do: get_feature_flag_result(PostHog, flag_name, distinct_id_or_body, [])

  @doc false
  def get_feature_flag_result(flag_name, distinct_id_or_body, opts)
      when not is_atom(flag_name) and is_list(opts),
      do: get_feature_flag_result(PostHog, flag_name, distinct_id_or_body, opts)

  @doc """
  Gets the full feature flag result including value and payload.

  Returns `{:ok, %PostHog.FeatureFlags.Result{}}` on success, `{:ok, nil}` if the flag
  is not found, or `{:error, reason}` on failure.

  The `PostHog.FeatureFlags.Result` struct contains:
  - `key` - The flag name
  - `enabled` - Whether the flag is enabled
  - `variant` - The variant string (nil for boolean flags)
  - `payload` - The JSON payload configured for the flag (nil if not set)

  By default, this function will
  [send](https://posthog.com/docs/api/flags#step-3-send-a-feature_flag_called-event)
  a `$feature_flag_called` event and
  [set](https://posthog.com/docs/api/flags#step-2-include-feature-flag-information-when-capturing-events)
  the `$feature/feature-flag-name` property in context.

  ## Options

  - `:send_event` - Whether to send the `$feature_flag_called` event. Defaults to `true`.

  ## Examples

  Get feature flag result for `distinct_id`:

      iex> PostHog.FeatureFlags.get_feature_flag_result("example-feature-flag-1", "user123")
      {:ok, %PostHog.FeatureFlags.Result{key: "example-feature-flag-1", enabled: true, variant: nil, payload: nil}}

  Get feature flag result with payload:

      iex> PostHog.FeatureFlags.get_feature_flag_result("feature-with-payload", "user123")
      {:ok, %PostHog.FeatureFlags.Result{key: "feature-with-payload", enabled: true, variant: "variant1", payload: %{"key" => "value"}}}

  Get feature flag result without sending event:

      iex> PostHog.FeatureFlags.get_feature_flag_result("my-flag", "user123", send_event: false)
      {:ok, %PostHog.FeatureFlags.Result{key: "my-flag", enabled: true, variant: nil, payload: nil}}

  Flag not found returns `{:ok, nil}`:

      iex> PostHog.FeatureFlags.get_feature_flag_result("non-existent-flag", "user123")
      {:ok, nil}

  Get feature flag result for `distinct_id` in the current context:

      iex> PostHog.set_context(%{distinct_id: "user123"})
      iex> PostHog.FeatureFlags.get_feature_flag_result("example-feature-flag-1")
      {:ok, %PostHog.FeatureFlags.Result{key: "example-feature-flag-1", enabled: true, variant: nil, payload: nil}}

  Get feature flag result through a named PostHog instance:

      PostHog.FeatureFlags.get_feature_flag_result(MyPostHog, "example-feature-flag-1", "user123")
  """
  @spec get_feature_flag_result(
          PostHog.supervisor_name(),
          String.t(),
          PostHog.distinct_id() | map() | nil,
          keyword()
        ) ::
          {:ok, __MODULE__.Result.t() | nil} | {:error, Exception.t()}
  def get_feature_flag_result(name \\ PostHog, flag_name, distinct_id_or_body \\ nil, opts \\ []) do
    case evaluate_flag(name, flag_name, distinct_id_or_body, opts) do
      {:ok, %__MODULE__.Result{} = result, _body} -> {:ok, result}
      {:ok, nil, _body} -> {:ok, nil}
      {:error, reason, _body} -> {:error, reason}
    end
  end

  @doc false
  def get_feature_flag_result!(flag_name, distinct_id_or_body)
      when not is_atom(flag_name) and not is_list(distinct_id_or_body),
      do: get_feature_flag_result!(PostHog, flag_name, distinct_id_or_body, [])

  @doc false
  def get_feature_flag_result!(flag_name, distinct_id_or_body, opts)
      when not is_atom(flag_name) and is_list(opts),
      do: get_feature_flag_result!(PostHog, flag_name, distinct_id_or_body, opts)

  @doc """
  Gets the full feature flag result or raises on error.

  This is a wrapper around `get_feature_flag_result/4` that returns the result
  directly or raises an exception on error. This follows the Elixir convention
  where functions ending with `!` raise exceptions instead of returning error
  tuples.

  Returns `nil` if the flag is not found (does not raise), consistent with
  other PostHog SDKs.

  > **Warning**: Use this function with care as it will raise an error if there
  > are any API errors (e.g. missing `distinct_id`). For more resilient code,
  > use `get_feature_flag_result/4` which returns `{:error, reason}` instead of
  > raising.

  ## Options

  - `:send_event` - Whether to send the `$feature_flag_called` event. Defaults to `true`.

  ## Examples

  Get feature flag result for `distinct_id`:

      iex> PostHog.FeatureFlags.get_feature_flag_result!("example-feature-flag-1", "user123")
      %PostHog.FeatureFlags.Result{key: "example-feature-flag-1", enabled: true, variant: nil, payload: nil}

  Returns `nil` when flag is not found:

      iex> PostHog.FeatureFlags.get_feature_flag_result!("non-existent-flag", "user123")
      nil

  Raises an error when `distinct_id` is missing:

      iex> PostHog.FeatureFlags.get_feature_flag_result!("example-feature-flag-1")
      ** (PostHog.Error) distinct_id is required but wasn't explicitly provided or found in the context
  """
  @spec get_feature_flag_result!(
          PostHog.supervisor_name(),
          String.t(),
          PostHog.distinct_id() | map() | nil,
          keyword()
        ) ::
          __MODULE__.Result.t() | nil | no_return()
  def get_feature_flag_result!(name \\ PostHog, flag_name, distinct_id_or_body \\ nil, opts \\ []) do
    case get_feature_flag_result(name, flag_name, distinct_id_or_body, opts) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  defp evaluate_flag(name, flag_name, distinct_id_or_body, opts) do
    send_event = Keyword.get(opts, :send_event, true)

    with {:ok, %{distinct_id: distinct_id} = body} <- body_for_flags(distinct_id_or_body),
         {:ok, %{body: body}} <- flags(name, body) do
      case body do
        %{"flags" => %{^flag_name => flag_data}} ->
          {enabled, variant} = extract_flag_enabled_and_variant(flag_data)
          payload = get_in(flag_data, ["metadata", "payload"])

          flag_result = %__MODULE__.Result{
            key: flag_name,
            enabled: enabled,
            variant: variant,
            payload: payload
          }

          evaluated_at = Map.get(body, "evaluatedAt")

          if send_event do
            value = __MODULE__.Result.value(flag_result)
            log_feature_flag_usage(name, distinct_id, flag_name, {:ok, value}, evaluated_at)
          end

          {:ok, flag_result, body}

        %{"flags" => _} ->
          {:ok, nil, body}
      end
    else
      {:error, reason} -> {:error, reason, nil}
    end
  end

  defp extract_flag_enabled_and_variant(flag_data) do
    enabled = Map.get(flag_data, "enabled", false) == true
    variant = Map.get(flag_data, "variant")
    {enabled, variant}
  end

  @doc false
  def check!(flag_name, distinct_id_or_body) when not is_atom(flag_name),
    do: check!(PostHog, flag_name, distinct_id_or_body)

  @doc """
  Checks feature flag and returns the variant or raises on error.

  This is a wrapper around `check/3` that returns the variant directly
  or raises an exception on error. This follows the Elixir convention where
  functions ending with `!` raise exceptions instead of returning error tuples.

  > **Warning**: Use this function with care as it will raise an error if the feature flag
  > is not found or if there are any API errors. For more resilient code, use `check/3`
  > which returns `{:error, reason}` instead of raising.

  ## Examples

  Check feature flag and get the variant:

      iex> PostHog.FeatureFlags.check!("example-feature-flag-1", "user123")
      true

  Check multivariant feature flag for distinct_id in current context:

      iex> PostHog.set_context(%{distinct_id: "user123"})
      iex> PostHog.FeatureFlags.check!("example-feature-flag-1")
      "variant1"

  Check feature flag through a named PostHog instance:

      iex> PostHog.FeatureFlags.check!(MyPostHog, "example-feature-flag-1", "user123")
      false

  Raises an error when feature flag is not found:

      iex> PostHog.FeatureFlags.check!("example-feature-flag-3", "user123")
      ** (PostHog.UnexpectedResponseError) Feature flag example-feature-flag-3 was not found in the response
  """
  @spec check!(PostHog.supervisor_name(), String.t(), PostHog.distinct_id() | map() | nil) ::
          boolean() | String.t() | no_return()
  def check!(name \\ PostHog, flag_name, distinct_id_or_body \\ nil) do
    case check(name, flag_name, distinct_id_or_body) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  defp log_feature_flag_usage(name, distinct_id, flag_name, result, evaluated_at) do
    with {:ok, variant} <- result do
      properties = %{
        distinct_id: distinct_id,
        "$feature_flag": flag_name,
        "$feature_flag_response": variant
      }

      properties =
        if evaluated_at do
          Map.put(properties, :"$feature_flag_evaluated_at", evaluated_at)
        else
          properties
        end

      PostHog.capture(name, "$feature_flag_called", properties)

      PostHog.set_context(name, %{"$feature/#{flag_name}" => variant})
    end
  end

  defp body_for_flags(distinct_id_or_body) do
    case distinct_id_or_body do
      %{distinct_id: _distinct_id} = body ->
        {:ok, body}

      nil ->
        case PostHog.get_context() do
          %{distinct_id: distinct_id} ->
            {:ok, %{distinct_id: distinct_id}}

          _context ->
            {:error,
             %PostHog.Error{
               message:
                 "distinct_id is required but wasn't explicitly provided or found in the context"
             }}
        end

      distinct_id when is_binary(distinct_id) ->
        {:ok, %{distinct_id: distinct_id}}
    end
  end
end
