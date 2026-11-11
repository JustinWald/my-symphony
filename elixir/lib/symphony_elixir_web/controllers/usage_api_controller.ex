defmodule SymphonyElixirWeb.UsageApiController do
  @moduledoc "Read-only usage history; no credential or protocol payload fields."
  use Phoenix.Controller, formats: [:json]
  alias SymphonyElixir.Management.{Repo, UsageHistory}

  @spec summary(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def summary(conn, params), do: respond(conn, params, :summary)

  @spec sessions(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def sessions(conn, params), do: respond(conn, params, :sessions)

  defp respond(conn, params, action) do
    case range(params) do
      {:ok, from, until, page} -> render_data(conn, action, from, until, page)
      :error -> conn |> put_status(400) |> json(%{error: "invalid_range_or_page"})
    end
  end

  defp range(params) do
    today = Date.utc_today()
    monday = Date.add(today, 1 - Date.day_of_week(today))

    with {:ok, from} <- Date.from_iso8601(params["from"] || Date.to_iso8601(monday)),
         {:ok, until} <- Date.from_iso8601(params["until"] || Date.to_iso8601(Date.add(today, 1))),
         true <- Date.compare(from, until) == :lt,
         {page, ""} when page > 0 and page <= 100_000 <- Integer.parse(params["page"] || "1") do
      {:ok, DateTime.new!(from, ~T[00:00:00], "Etc/UTC"), DateTime.new!(until, ~T[00:00:00], "Etc/UTC"), page}
    else
      _ -> :error
    end
  end

  defp render_data(conn, action, from, until, page) do
    if Process.whereis(Repo) do
      data = usage_data(action, from, until, page)
      json(conn, %{data: data, page: page, page_size: 50})
    else
      conn |> put_status(503) |> json(%{error: "management_unavailable"})
    end
  end

  defp usage_data(:summary, from, until, _page), do: UsageHistory.summary(from, until)
  defp usage_data(:sessions, from, until, page), do: UsageHistory.sessions(from, until, page)
end
