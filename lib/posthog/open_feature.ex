if Code.ensure_loaded?(OpenFeature.Provider) do
  defmodule PostHog.OpenFeature.Provider do
    @moduledoc """
    [OpenFeature](https://openfeature.dev) provider backed by PostHog feature flags.

    Requires the optional `:open_feature` dependency:

        {:open_feature, "~> 0.1"}

    ## Usage

        {:ok, _provider} = OpenFeature.set_provider(%PostHog.OpenFeature.Provider{})
        client = OpenFeature.get_client()

        OpenFeature.Client.get_boolean_value(client, "new-dashboard", false,
          context: %{
            "targeting_key" => "user-123",
            "plan" => "enterprise",
            "groups" => %{"company" => "acme"},
            "group_properties" => %{"company" => %{"size" => 250}}
          }
        )

    ## Options

    - `:supervisor_name` - PostHog instance to evaluate flags with. Defaults to
      `PostHog`.
    - `:default_distinct_id` - distinct ID used when the evaluation context has
      no `targeting_key`. When unset, such evaluations fail with
      `:targeting_key_missing`.
    - `:send_feature_flag_events` - whether evaluations fire
      `$feature_flag_called` events. Defaults to `true`.

    ## Evaluation context

    Keys can be strings or atoms.

    - `targeting_key` - used as the PostHog `distinct_id`.
    - `groups` - map of group type to group key.
    - `group_properties` - map of group type to group properties.
    - Every other key is sent as a person property.

    ## Resolution

    - Boolean flags resolve to whether the flag is enabled.
    - String flags resolve to the variant key.
    - Number flags resolve to the variant key parsed as a number, including
      unsigned hexadecimal integers such as `0x10`.
    - Map flags resolve to the flag's JSON object or array payload. The upstream
      OpenFeature SDK requires a map default (`%{}`), even for array payloads;
      `get_map_value/4` can return a list when the payload is an array.

    For string, number, and map reads, a disabled flag returns the default value,
    unless it still carries a variant (or object/array payload, for maps). That
    value is then returned, as in the Node and Python providers. Boolean reads
    return the flag's enabled state, including `false` regardless of the default.
    Reading an enabled flag whose value doesn't fit the requested type returns
    the default value with `error_code: :type_mismatch`. Unknown flags return
    `:flag_not_found`.

    Resolution details include `flag_metadata["posthog_reason"]` when PostHog
    supplies an evaluation reason. Off results use `:disabled` when the server
    explicitly reports the `flag_disabled` reason code, otherwise `:default`.

    The OpenFeature Elixir SDK has no error tuple for `:type_mismatch` or
    `:targeting_key_missing`, so these are returned as resolution details with
    `reason: :error` and run `after` hooks rather than `error` hooks.
    """

    @behaviour OpenFeature.Provider

    alias OpenFeature.ResolutionDetails
    alias PostHog.FeatureFlags
    alias PostHog.FeatureFlags.{Evaluations, Result}

    @typedoc "PostHog OpenFeature provider."
    @type t :: %__MODULE__{
            name: String.t(),
            domain: String.t() | nil,
            state: atom(),
            hooks: list(),
            supervisor_name: PostHog.supervisor_name(),
            default_distinct_id: PostHog.distinct_id() | nil,
            send_feature_flag_events: boolean()
          }

    defstruct name: "PostHogProvider",
              domain: nil,
              state: :not_ready,
              hooks: [],
              supervisor_name: PostHog,
              default_distinct_id: nil,
              send_feature_flag_events: true

    @reserved_keys ["targeting_key", "groups", "group_properties"]

    @impl true
    def initialize(%__MODULE__{} = provider, domain, _context) do
      {:ok, %{provider | domain: domain, state: :ready}}
    end

    @impl true
    def shutdown(_provider), do: :ok

    @impl true
    def resolve_boolean_value(provider, key, default, context) do
      with {:ok, %Result{} = result} <- evaluate(provider, key, default, context) do
        {:ok, details(result, result.enabled)}
      end
    end

    @impl true
    def resolve_string_value(provider, key, default, context) do
      with {:ok, %Result{} = result} <- evaluate(provider, key, default, context) do
        case result do
          %Result{variant: nil, enabled: false} ->
            {:ok, default_details(result, default)}

          %Result{variant: nil} ->
            {:ok, type_mismatch(default, "Flag '#{key}' has no string variant.")}

          %Result{variant: variant} ->
            {:ok, details(result, variant)}
        end
      end
    end

    @impl true
    def resolve_number_value(provider, key, default, context) do
      with {:ok, %Result{} = result} <- evaluate(provider, key, default, context) do
        case result do
          %Result{variant: nil, enabled: false} ->
            {:ok, default_details(result, default)}

          %Result{variant: nil} ->
            {:ok, type_mismatch(default, "Flag '#{key}' has no numeric variant.")}

          %Result{variant: variant} ->
            {:ok, number_details(result, key, variant, default)}
        end
      end
    end

    # open-feature/elixir-sdk 0.1.3 guards get_map_value/get_map_details defaults
    # with is_map/1 before calling the provider, but does not restrict returned
    # values. Array payloads work with a map default; list defaults need an upstream fix.
    @impl true
    def resolve_map_value(provider, key, default, context) do
      with {:ok, %Result{} = result} <- evaluate(provider, key, default, context) do
        case result do
          %Result{payload: payload} when is_map(payload) or is_list(payload) ->
            {:ok, details(result, payload)}

          %Result{enabled: false} ->
            {:ok, default_details(result, default)}

          %Result{} ->
            {:ok, type_mismatch(default, "Flag '#{key}' has no object/JSON payload.")}
        end
      end
    end

    defp evaluate(%__MODULE__{} = provider, key, default, context) do
      case resolve_distinct_id(provider, context) do
        {:ok, distinct_id} ->
          body = flags_body(distinct_id, key, context)

          case FeatureFlags.evaluate_flags(provider.supervisor_name, body) do
            {:ok, snapshot} -> fetch_result(provider, snapshot, key)
            {:error, reason} -> {:error, :unexpected_error, to_exception(reason)}
          end

        :error ->
          {:ok,
           error_details(
             default,
             :targeting_key_missing,
             "No targeting_key in evaluation context and no default_distinct_id configured."
           )}
      end
    end

    defp fetch_result(provider, %Evaluations{flags: flags} = snapshot, key) do
      if provider.send_feature_flag_events, do: Evaluations.get_flag(snapshot, key)

      case Map.fetch(flags, key) do
        {:ok, result} -> {:ok, result}
        :error -> {:error, :flag_not_found}
      end
    end

    defp resolve_distinct_id(provider, context) do
      case get_key(context, :targeting_key) do
        targeting_key when targeting_key not in [nil, ""] -> {:ok, targeting_key}
        _ when not is_nil(provider.default_distinct_id) -> {:ok, provider.default_distinct_id}
        _ -> :error
      end
    end

    defp flags_body(distinct_id, key, context) do
      person_properties =
        context
        |> Enum.map(fn {k, v} -> {to_string(k), v} end)
        |> Enum.reject(fn {k, _v} -> k in @reserved_keys end)
        |> Map.new()

      %{distinct_id: distinct_id, flag_keys: [key]}
      |> put_non_empty(:person_properties, person_properties)
      |> put_non_empty(:groups, get_key(context, :groups))
      |> put_non_empty(:group_properties, get_key(context, :group_properties))
    end

    defp get_key(context, key) do
      Map.get(context, Atom.to_string(key), Map.get(context, key))
    end

    defp put_non_empty(body, key, value) when is_map(value) and map_size(value) > 0,
      do: Map.put(body, key, value)

    defp put_non_empty(body, _key, _value), do: body

    defp number_details(result, key, variant, default) do
      case parse_number(variant) do
        {:ok, number} -> details(result, number)
        :error -> type_mismatch(default, "Flag '#{key}' variant '#{variant}' is not a number.")
      end
    end

    defp parse_number(variant) do
      trimmed = String.trim(variant)

      cond do
        trimmed =~ ~r/\A0[xX][0-9a-fA-F]+\z/ ->
          <<_prefix::binary-size(2), digits::binary>> = trimmed
          {:ok, String.to_integer(digits, 16)}

        trimmed =~ ~r/\d/ ->
          case Integer.parse(trimmed) do
            {integer, ""} -> {:ok, integer}
            _ -> parse_float(trimmed)
          end

        true ->
          :error
      end
    end

    # Float.parse/1 needs digits on both sides of the decimal point, unlike
    # JavaScript's Number() and Python's float(), so `.5` and `1.` are padded.
    defp parse_float(string) do
      padded =
        string
        |> String.replace(~r/^([+-]?)\./, "\\g{1}0.")
        |> String.replace(~r/\.$/, ".0")

      case Float.parse(padded) do
        {float, ""} -> {:ok, float}
        _ -> :error
      end
    end

    defp details(%Result{} = result, value) do
      %ResolutionDetails{
        value: value,
        variant: result.variant,
        reason: resolution_reason(result),
        flag_metadata: reason_metadata(result.reason)
      }
    end

    defp resolution_reason(%Result{enabled: true}), do: :targeting_match
    defp resolution_reason(%Result{reason: %{"code" => "flag_disabled"}}), do: :disabled
    defp resolution_reason(_result), do: :default

    defp reason_metadata(%{"description" => description}) when is_binary(description),
      do: %{"posthog_reason" => description}

    defp reason_metadata(%{"code" => code}) when is_binary(code),
      do: %{"posthog_reason" => code}

    defp reason_metadata(reason) when is_binary(reason), do: %{"posthog_reason" => reason}
    defp reason_metadata(_reason), do: %{}

    defp default_details(result, default), do: %{details(result, default) | variant: nil}

    defp type_mismatch(default, message), do: error_details(default, :type_mismatch, message)

    defp error_details(default, code, message) do
      %ResolutionDetails{value: default, reason: :error, error_code: code, error_message: message}
    end

    defp to_exception(%{__exception__: true} = exception), do: exception
    defp to_exception(reason), do: %PostHog.Error{message: inspect(reason)}
  end
end
