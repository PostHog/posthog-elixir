defmodule PostHog.Integrations.Plug do
  @moduledoc """
  Provides a plug that automatically extracts and sets relevant metadata from
  `Plug.Conn`.

  For Phoenix apps, add it to your `endpoint.ex` somewhere before your router:

      plug PostHog.Integrations.Plug
      
  For Plug apps, add it directly to your router:

      defmodule MyRouterPlug do
        use Plug.Router
        
        plug PostHog.Integrations.Plug
        plug :match
        plug :dispatch
        
        ...
      end
  """

  @doc false
  def init(opts), do: opts

  @doc false
  def call(conn, _opts) do
    context = conn_to_context(conn)
    PostHog.Context.set(:all, :all, context)

    conn
  end

  @tracing_headers [
    {"x-posthog-distinct-id", :distinct_id},
    {"x-posthog-session-id", :"$session_id"}
  ]
  @max_header_value_length 1000
  @control_chars_regex ~r/[\x{00}-\x{1F}\x{7F}-\x{9F}]/u

  @doc false
  def conn_to_context(conn) when is_struct(conn, Plug.Conn) do
    query_string = if conn.query_string == "", do: nil, else: conn.query_string

    %{
      "$current_url":
        %URI{
          scheme: to_string(conn.scheme),
          host: conn.host,
          path: conn.request_path,
          query: query_string
        }
        |> URI.to_string(),
      "$host": conn.host,
      "$pathname": conn.request_path,
      "$ip": remote_ip(conn),
      "$request_method": conn.method
    }
    |> put_if_present(:"$user_agent", first_header_value(conn, "user-agent"))
    |> Map.merge(tracing_context(conn))
  end

  defp tracing_context(conn) when is_struct(conn, Plug.Conn) do
    Enum.reduce(@tracing_headers, %{}, fn {header_name, context_key}, context ->
      put_if_present(context, context_key, header_value(conn, header_name))
    end)
  end

  defp header_value(conn, header_name) when is_struct(conn, Plug.Conn) do
    case req_header_values(conn, header_name) do
      [value | _] when is_binary(value) -> sanitize_value(value)
      _ -> nil
    end
  end

  defp first_header_value(conn, header_name) when is_struct(conn, Plug.Conn) do
    case req_header_values(conn, header_name) do
      [value | _] when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp req_header_values(conn, header_name) do
    normalized_header_name = String.downcase(header_name)

    # Avoid compilation warnings for cases where Plug isn't available
    # credo:disable-for-lines:1
    case apply(Plug.Conn, :get_req_header, [conn, normalized_header_name]) do
      [] ->
        for {key, value} <- conn.req_headers,
            is_binary(key),
            String.downcase(key) == normalized_header_name do
          value
        end

      values ->
        values
    end
  end

  defp sanitize_value(value) when is_binary(value) do
    value =
      value
      |> String.replace(@control_chars_regex, "")
      |> String.trim()
      |> String.slice(0, @max_header_value_length)

    if value == "", do: nil, else: value
  end

  defp sanitize_value(_value), do: nil

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp remote_ip(conn) when is_struct(conn, Plug.Conn) do
    # Avoid compilation warnings for cases where Plug isn't available
    # credo:disable-for-lines:2
    remote_ip =
      case apply(Plug.Conn, :get_req_header, [conn, "x-forwarded-for"]) do
        [x_forwarded_for | _] ->
          x_forwarded_for |> String.split(",", parts: 2) |> List.first()

        [] ->
          case :inet.ntoa(conn.remote_ip) do
            {:error, _} -> ""
            address -> to_string(address)
          end
      end

    String.trim(remote_ip)
  end
end
