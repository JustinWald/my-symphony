defmodule SymphonyElixir.AgentRuntimeSupervisor do
  @moduledoc """
  Supervises the scheduler authority together with its agent tasks.
  """

  use Supervisor
  alias SymphonyElixir.{Orchestrator, Project, TaskSupervisor}

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, Project.name(__MODULE__, Keyword.get(opts, :project, Project.current())))
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    Project.bind(Keyword.get(opts, :project, Project.current()))

    task_supervisor_name =
      Keyword.get(opts, :task_supervisor_name, Project.name(TaskSupervisor))

    orchestrator_name = Keyword.get(opts, :orchestrator_name, Project.name(Orchestrator))

    children = [
      Supervisor.child_spec(
        {Task.Supervisor, name: task_supervisor_name},
        id: task_supervisor_name
      ),
      Supervisor.child_spec(
        {Orchestrator, name: orchestrator_name, task_supervisor: task_supervisor_name, project: Project.current()},
        id: orchestrator_name
      )
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
