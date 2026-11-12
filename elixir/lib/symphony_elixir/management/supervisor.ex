defmodule SymphonyElixir.Management.Supervisor do
  @moduledoc "Management lifecycle, isolated from the agent runtime supervisor."
  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: SymphonyElixir.Project.name(__MODULE__, Keyword.get(opts, :project, SymphonyElixir.Project.current())))

  @impl true
  def init(opts) do
    SymphonyElixir.Project.bind(Keyword.get(opts, :project, SymphonyElixir.Project.current()))

    Supervisor.init(
      [
        {SymphonyElixir.Management.Repo, [name: SymphonyElixir.Project.name(SymphonyElixir.Management.Repo), state_dir: SymphonyElixir.Config.management_state_dir()]},
        {SymphonyElixir.Management.Bootstrap, opts},
        {SymphonyElixir.Management.WorkersSupervisor, opts}
      ],
      strategy: :rest_for_one
    )
  end
end

defmodule SymphonyElixir.Management.Bootstrap do
  @moduledoc false
  use GenServer
  alias SymphonyElixir.Management.Schema

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    SymphonyElixir.Project.bind(Keyword.get(opts, :project, SymphonyElixir.Project.current()))
    Schema.migrate()
    File.chmod!(Path.join(SymphonyElixir.Config.management_state_dir(), "management.sqlite3"), 0o600)
    {:ok, %{}}
  end
end

defmodule SymphonyElixir.Management.WorkersSupervisor do
  @moduledoc false
  use Supervisor
  alias SymphonyElixir.Management.{Recorder, Scheduler}

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: SymphonyElixir.Project.name(__MODULE__, Keyword.get(opts, :project, SymphonyElixir.Project.current())))

  @impl true
  def init(opts) do
    SymphonyElixir.Project.bind(Keyword.get(opts, :project, SymphonyElixir.Project.current()))

    Supervisor.init([{Recorder, opts}, {Task.Supervisor, name: SymphonyElixir.Project.name(SymphonyElixir.Management.Tasks)}, {Scheduler, opts}],
      strategy: :one_for_one
    )
  end
end
