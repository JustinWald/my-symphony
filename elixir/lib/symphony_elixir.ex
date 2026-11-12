defmodule SymphonyElixir do
  @moduledoc """
  Entry point for the Symphony orchestrator.
  """

  @doc """
  Start the agent runtime in the current BEAM node.
  """
  @spec start_link() :: Supervisor.on_start()
  def start_link do
    SymphonyElixir.AgentRuntimeSupervisor.start_link([])
  end
end

defmodule SymphonyElixir.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application

  @dialyzer {:nowarn_function, start_burrito_cli: 0}

  @impl true
  def start(_type, _args) do
    if burrito_runtime?() do
      start_burrito_cli()
    else
      start_runtime()
    end
  end

  @doc false
  @spec start_runtime() :: Supervisor.on_start()
  def start_runtime do
    :ok = SymphonyElixir.LogFile.configure()

    projects =
      case System.get_env("SYMPHONY_PROJECT_MANIFEST") do
        nil ->
          []

        path ->
          {:ok, projects} = SymphonyElixir.ProjectManifest.load(path)
          projects
      end

    Application.put_env(:symphony_elixir, :projects, projects)

    runtimes =
      if projects == [] do
        management =
          if SymphonyElixir.Config.management_enabled?(),
            do: [SymphonyElixir.Management.Supervisor],
            else: []

        [SymphonyElixir.WorkflowStore] ++ management ++ [SymphonyElixir.AgentRuntimeSupervisor]
      else
        projects
        |> Enum.filter(& &1.enabled)
        |> Enum.map(fn project ->
          Supervisor.child_spec({SymphonyElixir.ProjectSupervisor, project: project}, id: project.id)
        end)
      end

    children =
      [
        {Registry, keys: :unique, name: SymphonyElixir.ProjectRegistry}
      ] ++
        runtimes ++
        [
          {Phoenix.PubSub, name: SymphonyElixir.PubSub},
          SymphonyElixir.HttpServer,
          SymphonyElixir.StatusDashboard,
          SymphonyElixir.DispatchGate
        ]

    Supervisor.start_link(
      children,
      strategy: if(projects == [], do: :one_for_one, else: :rest_for_one),
      name: SymphonyElixir.Supervisor
    )
  end

  @impl true
  def stop(_state) do
    SymphonyElixir.StatusDashboard.render_offline_status()
    :ok
  end

  defp start_burrito_cli do
    Task.start_link(fn ->
      SymphonyElixir.CLI.main(
        plain_arguments(),
        &start_runtime/0
      )
    end)
  end

  defp burrito_runtime?, do: System.get_env("__BURRITO") == "1"

  defp plain_arguments, do: Enum.map(:init.get_plain_arguments(), &to_string/1)
end
