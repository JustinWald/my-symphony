defmodule SymphonyElixir.Management.Supervisor do
  @moduledoc "Management lifecycle, isolated from the agent runtime supervisor."
  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Supervisor.init(
      [
        SymphonyElixir.Management.Repo,
        SymphonyElixir.Management.Bootstrap,
        SymphonyElixir.Management.WorkersSupervisor
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
  def init(_opts) do
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
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Supervisor.init([Recorder, {Task.Supervisor, name: SymphonyElixir.Management.Tasks}, Scheduler],
      strategy: :one_for_one
    )
  end
end
