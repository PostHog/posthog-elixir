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
    PostHog.Context.set(:all, "$exception", context)

    conn
  end

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
      "$ip": remote_ip(conn)
    }
  end

  defp remote_ip(conn) when is_struct(conn, Plug.Conn) do
    # Avoid compilation warnings for cases where Plug isn't available
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
