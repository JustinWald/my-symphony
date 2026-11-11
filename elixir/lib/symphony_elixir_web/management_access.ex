defmodule SymphonyElixirWeb.ManagementAccess do
  @moduledoc "Management stays on loopback, including Host checks against DNS rebinding."
  import Plug.Conn

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    if conn.host in ["localhost", "127.0.0.1", "::1"] and loopback?(conn.remote_ip) do
      conn
    else
      conn |> send_resp(403, "Management requires loopback access") |> halt()
    end
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_), do: false
end
