defmodule SymphonyElixir.GateRecoveryTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.{DispatchGate, Project}

  setup do
    old_projects = Project.all()
    old_control = System.get_env("SYMPHONY_CONTROL_DIR")
    old_effects = System.get_env("SYMPHONY_EXTERNAL_EFFECTS")
    System.delete_env("SYMPHONY_CONTROL_DIR")
    System.delete_env("SYMPHONY_EXTERNAL_EFFECTS")
    a = %Project{id: "gate-a"}
    b = %Project{id: "gate-b"}
    Application.put_env(:symphony_elixir, :projects, [a, b])
    restart_gate()

    on_exit(fn ->
      Application.put_env(:symphony_elixir, :projects, old_projects)
      SymphonyElixir.TestSupport.restore_env("SYMPHONY_CONTROL_DIR", old_control)
      SymphonyElixir.TestSupport.restore_env("SYMPHONY_EXTERNAL_EFFECTS", old_effects)
      restart_gate()
    end)

    %{a: a, b: b}
  end

  defp restart_gate do
    :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, DispatchGate)
    {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, DispatchGate)
    :ok
  end

  test "gate restart keeps caller reservation and running runtime supervisors intact", %{a: a, b: b} do
    Project.bind(a)
    assert DispatchGate.acquire("1")
    runtime = Process.whereis(SymphonyElixir.AgentRuntimeSupervisor)
    tasks = Process.whereis(SymphonyElixir.TaskSupervisor)
    assert is_pid(runtime)
    assert is_pid(tasks)
    {:ok, worker} = Task.Supervisor.start_child(tasks, fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> if Process.alive?(worker), do: send(worker, :stop) end)
    assert :ok = restart_gate()
    assert Process.whereis(SymphonyElixir.AgentRuntimeSupervisor) == runtime
    assert Process.whereis(SymphonyElixir.TaskSupervisor) == tasks
    assert Process.alive?(worker)
    Project.bind(b)
    refute DispatchGate.acquire("1")
    Project.bind(a)
    assert :ok = DispatchGate.release("wrong-issue")
    assert [{owner, {"gate-a", "1"}}] = Registry.lookup(SymphonyElixir.ProjectRegistry, :coding_slot)
    assert owner == self()
    assert :ok = DispatchGate.release("1")
    Project.bind(b)
    assert DispatchGate.acquire("1")
    DispatchGate.release("1")
  end

  test "owner death after gate restart automatically releases the coding reservation", %{a: a, b: b} do
    parent = self()

    {owner, monitor} =
      spawn_monitor(fn ->
        Project.bind(a)
        send(parent, {:reserved, DispatchGate.acquire("1")})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:reserved, true}
    assert :ok = restart_gate()
    Project.bind(b)
    refute DispatchGate.acquire("1")
    assert :ok = DispatchGate.release("1")
    assert [{^owner, {"gate-a", "1"}}] = Registry.lookup(SymphonyElixir.ProjectRegistry, :coding_slot)
    send(owner, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
    assert DispatchGate.acquire("1")
    DispatchGate.release("1")
  end

  test "failed fairness call releases the caller reservation", %{a: a} do
    :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, DispatchGate)
    parent = self()

    {gate, monitor} =
      spawn_monitor(fn ->
        Process.register(self(), DispatchGate)
        send(parent, :gate_ready)

        receive do
          {:"$gen_call", _from, {:acquire, _key, true}} -> exit(:fixture_failure)
        end
      end)

    try do
      assert_receive :gate_ready
      Project.bind(a)
      refute DispatchGate.acquire("1")
      assert_receive {:DOWN, ^monitor, :process, ^gate, :fixture_failure}
      assert Registry.lookup(SymphonyElixir.ProjectRegistry, :coding_slot) == []
    after
      if Process.alive?(gate), do: Process.exit(gate, :kill)
      {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, DispatchGate)
    end
  end

  test "missing reservation registry refuses new dispatch and permits safe release", %{a: a} do
    :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.ProjectRegistry)

    try do
      Project.bind(a)
      refute DispatchGate.acquire("1")
      assert :ok = DispatchGate.release("1")
    after
      {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.ProjectRegistry)
    end
  end
end
