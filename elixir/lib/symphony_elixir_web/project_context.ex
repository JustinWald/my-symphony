defmodule SymphonyElixirWeb.ProjectContext do
  @moduledoc "Binds an HTTP request to a validated project before accessing runtime state."
  import Plug.Conn
  alias SymphonyElixir.Project

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    case conn.path_params["project_id"] do
      nil ->
        Project.mount(%{})
        conn

      id ->
        case Project.find(id) do
          {:ok, project} ->
            Project.bind(project)
            conn

          {:error, _} ->
            conn |> send_resp(404, "Unknown project") |> halt()
        end
    end
  end
end
