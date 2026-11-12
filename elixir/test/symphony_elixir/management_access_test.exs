defmodule SymphonyElixirWeb.ManagementAccessTest do
  use ExUnit.Case, async: true
  alias SymphonyElixirWeb.ManagementAccess

  test "Host and peer must both be loopback" do
    opts = ManagementAccess.init([])

    for {host, peer} <- [
          {"localhost", {127, 0, 0, 1}},
          {"127.0.0.1", {127, 0, 0, 1}},
          {"::1", {0, 0, 0, 0, 0, 0, 0, 1}}
        ] do
      conn = %{Plug.Test.conn(:get, "/usage") | host: host, remote_ip: peer}
      refute ManagementAccess.call(conn, opts).halted
    end

    for {host, peer} <- [{"attacker.example", {127, 0, 0, 1}}, {"localhost", {10, 0, 0, 1}}] do
      conn = %{Plug.Test.conn(:get, "/usage") | host: host, remote_ip: peer}
      assert %{halted: true, status: 403} = ManagementAccess.call(conn, opts)
    end
  end
end
