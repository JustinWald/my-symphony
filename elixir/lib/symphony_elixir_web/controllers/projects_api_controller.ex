defmodule SymphonyElixirWeb.ProjectsApiController do
  @moduledoc "Project discovery and deployment readiness. Approval is deliberately absent from HTTP."
  use Phoenix.Controller, formats: [:json]
  alias SymphonyElixir.{Config, DeploymentControl, Orchestrator, Project}
  alias SymphonyElixir.Management.{Recorder, Scheduler, Settings, Store, Tasks}

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    json(conn, %{projects: Enum.map(Project.all(), &links/1)})
  end

  defp links(project) do
    %{id: project.id, enabled: project.enabled, dashboard: "/projects/#{project.id}", usage: "/projects/#{project.id}/usage", reports: "/projects/#{project.id}/reports"}
  end

  @spec settings(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def settings(conn, _params), do: management(conn, &Settings.public/0)

  @spec reports(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def reports(conn, _params) do
    management(conn, fn ->
      Store.rows("SELECT week,body,metrics,audit,url,published,notified FROM reports ORDER BY week DESC LIMIT 100")
    end)
  end

  defp management(conn, fun) do
    json(conn, %{data: fun.()})
  rescue
    _ -> conn |> put_status(503) |> json(%{error: "management_unavailable"})
  end

  @spec health(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def health(conn, _params) do
    projects = Enum.filter(Project.all(), & &1.enabled)
    previous = Project.current()
    runtimes = Enum.map(if(projects == [], do: [nil], else: projects), &runtime/1)
    Project.bind(previous)
    ready = Enum.all?(runtimes, & &1.ready)
    held = DeploymentControl.status()

    payload =
      Map.merge(held, %{
        revision: DeploymentControl.revision(),
        ready: ready,
        projects: runtimes,
        state_paths_sha256: state_digest(projects),
        running_jobs: Enum.sum(Enum.map(runtimes, & &1.running_jobs)),
        management_tasks: Enum.sum(Enum.map(runtimes, & &1.management_tasks)),
        checkpoint_ready: held.dispatch_paused and held.effects_held and Enum.all?(runtimes, & &1.checkpoint_ready)
      })

    conn |> put_status(if(ready, do: 200, else: 503)) |> json(payload)
  end

  defp state_digest(projects) do
    paths =
      case projects do
        [] -> if Config.management_enabled?(), do: [Config.management_state_dir()], else: []
        projects -> Enum.map(projects, & &1.state_dir)
      end

    paths =
      Enum.map(paths, fn path ->
        {:ok, canonical} = SymphonyElixir.PathSafety.canonicalize(path)
        canonical
      end)

    :crypto.hash(:sha256, Jason.encode!(Enum.sort(paths))) |> Base.encode16(case: :lower)
  end

  defp runtime(project) do
    Project.bind(project)
    snapshot = Orchestrator.snapshot(Project.name(Orchestrator), 2_000)
    storage = storage_ready?()
    if DeploymentControl.effects_held?(), do: barrier(Scheduler, :quiesce)
    tasks = task_count()
    ready = is_map(snapshot) and storage and management_ready?()
    running = running_count(snapshot)
    checkpoint = ready and running == 0 and tasks == 0 and checkpoint?()

    %{
      id: project_id(project),
      ready: ready,
      storage_ready: storage,
      migrations_ready: storage,
      running_jobs: running,
      management_tasks: tasks,
      checkpoint_ready: checkpoint
    }
  catch
    :exit, _ -> unavailable(project)
  end

  defp unavailable(project) do
    %{
      id: project_id(project),
      ready: false,
      storage_ready: false,
      migrations_ready: false,
      running_jobs: 0,
      management_tasks: 0,
      checkpoint_ready: false
    }
  end

  defp project_id(nil), do: "default"
  defp project_id(project), do: project.id
  defp running_count(%{running: running}), do: length(running)
  defp running_count(_), do: 0

  defp task_count do
    case Project.whereis(Project.name(Tasks)) do
      nil -> 0
      pid -> length(Task.Supervisor.children(pid))
    end
  end

  defp management_ready? do
    if Project.current() || Config.management_enabled?() do
      Enum.all?([Recorder, Scheduler, Tasks], fn module -> is_pid(Project.whereis(Project.name(module))) end)
    else
      true
    end
  end

  defp storage_ready? do
    if Project.current() || Config.management_enabled?() do
      Store.rows("SELECT version FROM schema_migrations ORDER BY version DESC LIMIT 1") != []
    else
      true
    end
  rescue
    _ -> false
  end

  defp barrier(module, message) do
    case Project.whereis(Project.name(module)) do
      nil -> :ok
      pid -> GenServer.call(pid, message, 1_000)
    end
  end

  defp checkpoint? do
    if DeploymentControl.dispatch_paused?() and DeploymentControl.effects_held?() do
      barrier(Recorder, :flush)
      GenServer.call(Project.name(Orchestrator), :checkpoint) == :ok
    else
      false
    end
  end
end
