defmodule SymphonyElixir.DispatchGate do
  @moduledoc "FIFO project selection with a caller-owned coding reservation that survives gate restarts."
  use GenServer
  alias SymphonyElixir.{DeploymentControl, Project}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec acquire(String.t()) :: boolean()
  def acquire(issue_id) do
    cond do
      DeploymentControl.dispatch_paused?() -> false
      Project.all() == [] -> true
      Process.whereis(__MODULE__) -> acquire_reservation(key(issue_id))
      true -> false
    end
  end

  @spec release(String.t()) :: :ok
  def release(issue_id) do
    release_reservation(key(issue_id))
    :ok
  end

  defp acquire_reservation(key) do
    case Registry.register(SymphonyElixir.ProjectRegistry, :coding_slot, key) do
      {:ok, _partition} ->
        accepted = request_turn(key, true)
        if not accepted, do: release_reservation(key)
        accepted

      {:error, {:already_registered, _owner}} ->
        request_turn(key, false)
        false
    end
  rescue
    ArgumentError -> false
  end

  defp request_turn(key, reserved) do
    GenServer.call(__MODULE__, {:acquire, key, reserved})
  catch
    :exit, _reason -> false
  end

  defp release_reservation(key) do
    owner = self()

    case Registry.lookup(SymphonyElixir.ProjectRegistry, :coding_slot) do
      [{^owner, ^key}] -> Registry.unregister(SymphonyElixir.ProjectRegistry, :coding_slot)
      _ -> :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp key(issue), do: {if(Project.current(), do: Project.current().id), issue}

  @impl true
  def init(_opts), do: {:ok, %{waiting: []}}

  @impl true
  def handle_call({:acquire, {project, _issue}, reserved}, _from, state) do
    now = System.monotonic_time(:millisecond)
    waiting = Enum.reject(state.waiting, fn {_id, due} -> due < now end)
    waiting = if Enum.any?(waiting, fn {id, _} -> id == project end), do: waiting, else: waiting ++ [{project, now + 60_000}]
    allowed = reserved and elem(hd(waiting), 0) == project and not DeploymentControl.dispatch_paused?()

    if allowed do
      {:reply, true, %{waiting: Enum.reject(waiting, fn {id, _} -> id == project end)}}
    else
      {:reply, false, %{state | waiting: waiting}}
    end
  end
end
