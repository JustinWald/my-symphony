defmodule SymphonyElixir.ProjectSupervisor do
  @moduledoc "Owns one project's workflow, storage, scheduler and workers as a single recovery boundary."
  use Supervisor
  alias SymphonyElixir.Project

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Project.name(__MODULE__, Keyword.fetch!(opts, :project)))
  end

  @impl true
  def init(opts) do
    project = Keyword.fetch!(opts, :project)
    Project.bind(project)

    Supervisor.init(
      [
        {SymphonyElixir.WorkflowStore, opts},
        {SymphonyElixir.Management.Supervisor, opts},
        {SymphonyElixir.AgentRuntimeSupervisor, opts}
      ],
      strategy: :rest_for_one
    )
  end
end
