defmodule SymphonyElixir.DispatchGate do
  @moduledoc "One service-wide coding slot with FIFO project selection and owner monitoring."
  use GenServer
  alias SymphonyElixir.{DeploymentControl, Project}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec acquire(String.t()) :: boolean()
  def acquire(issue_id) do
    cond do
      DeploymentControl.dispatch_paused?() -> false
      Project.all() == [] -> true
      Process.whereis(__MODULE__) -> GenServer.call(__MODULE__, {:acquire, key(issue_id)})
      true -> false
    end
  end

  @spec release(String.t()) :: :ok
  def release(issue_id) do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, {:release, key(issue_id)})
    :ok
  end

  defp key(issue), do: {if(Project.current(), do: Project.current().id), issue}

  @impl true
  def init(_opts), do: {:ok, %{holder: nil, waiting: []}}

  @impl true
  def handle_call({:acquire, {project, _issue} = key}, {owner, _}, state) do
    now = System.monotonic_time(:millisecond)
    waiting = Enum.reject(state.waiting, fn {_id, due} -> due < now end)
    waiting = if Enum.any?(waiting, fn {id, _} -> id == project end), do: waiting, else: waiting ++ [{project, now + 60_000}]
    allowed = state.holder == nil and elem(hd(waiting), 0) == project and not DeploymentControl.dispatch_paused?()

    if allowed do
      ref = Process.monitor(owner)
      {:reply, true, %{holder: {key, ref}, waiting: Enum.reject(waiting, fn {id, _} -> id == project end)}}
    else
      {:reply, false, %{state | waiting: waiting}}
    end
  end

  def handle_call({:release, key}, _from, %{holder: {key, ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:reply, :ok, %{state | holder: nil}}
  end

  def handle_call({:release, _key}, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{holder: {_key, ref}} = state),
    do: {:noreply, %{state | holder: nil}}
end
