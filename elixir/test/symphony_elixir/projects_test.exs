defmodule SymphonyElixir.ProjectsTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  @endpoint SymphonyElixirWeb.Endpoint
  alias SymphonyElixir.{Config, DeploymentControl, DispatchGate, Orchestrator, Project}
  alias SymphonyElixir.Management.{Command, HTTP, Scheduler, Settings, Store}
  alias SymphonyElixir.{ProjectManifest, RuntimeCheckpoint, WorkflowStore, Workspace}
  alias SymphonyElixir.Tracker.Memory

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-projects-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    old_control = System.get_env("SYMPHONY_CONTROL_DIR")
    old_effects = System.get_env("SYMPHONY_EXTERNAL_EFFECTS")
    old_projects = Project.all()
    System.put_env("SYMPHONY_CONTROL_DIR", Path.join(root, "control"))
    File.mkdir_p!(Path.join(root, "control"))
    System.delete_env("SYMPHONY_EXTERNAL_EFFECTS")

    on_exit(fn ->
      Application.put_env(:symphony_elixir, :projects, old_projects)
      SymphonyElixir.TestSupport.restore_env("SYMPHONY_CONTROL_DIR", old_control)
      SymphonyElixir.TestSupport.restore_env("SYMPHONY_EXTERNAL_EFFECTS", old_effects)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  defp project(root, id, repo \\ nil) do
    path = Path.join(root, id <> ".md")
    provider = if repo, do: "  provider:\n    repo: #{repo}\n    token: $#{String.upcase(id)}_TOKEN\n", else: ""
    kind = if repo, do: "github", else: "memory"

    File.write!(
      path,
      "---\ntracker:\n  kind: #{kind}\n#{provider}polling:\n  interval_ms: #{60_000}\nworkspace:\n  root: #{root}/workspaces/#{id}\nmanagement:\n  repo: #{repo || "owner/#{id}"}\n  github_token_env: #{String.upcase(id)}_SECRET\n---\nPrompt for #{id}\n"
    )

    %Project{id: id, workflow_path: path, state_dir: Path.join(root, "state/#{id}"), workspace_root: Path.join(root, "workspaces/#{id}")}
  end

  defp runtimes(projects) do
    Application.put_env(:symphony_elixir, :projects, projects)

    Enum.each(projects, fn project ->
      start_supervised!({SymphonyElixir.ProjectSupervisor, project: project}, id: project.id)
    end)
  end

  defp hold(root, paused, held), do: File.write!(Path.join(root, "control/pause.json"), Jason.encode!(%{dispatch_paused: paused, effects_held: held}))

  test "independent runtimes preserve identical issue identities, storage, configuration and workspaces", %{root: root} do
    a = project(root, "registry")
    b = project(root, "symphony")
    runtimes([a, b])
    Project.bind(a)
    assert Config.management_state_dir() == a.state_dir
    assert Config.local_workspace_root() == a.workspace_root
    assert {:ok, workflow} = WorkflowStore.current()
    assert workflow.prompt == "Prompt for registry"
    assert :ok = Store.event("same-delivery", "start", %{repo: "registry"}, 1, DateTime.utc_now())
    assert :ok = Store.put("setting", "registry")
    assert {:ok, wa} = Workspace.create_for_issue("1")
    assert is_map(Orchestrator.snapshot())
    Project.bind(b)
    assert Store.get("setting") == nil
    assert {:ok, wb} = Workspace.create_for_issue("1")
    refute wa == wb
    Store.event("same-delivery", "start", %{repo: "symphony"}, 1, DateTime.utc_now())
    assert [%{"issue" => 1}] = Store.rows("SELECT issue FROM events WHERE id='same-delivery'")
    assert Settings.config()["repo"] == "owner/symphony"
    Project.bind(a)
    assert Store.get("setting") == "registry"
    assert Settings.config()["repo"] == "owner/registry"
    assert {:ok, :ok} = Store.transaction(fn -> Store.put("nested", 1) end)
    assert Store.get("nested") == 1
    assert :ok = WorkflowStore.force_reload()
    assert Project.find("registry") == {:ok, a}
    assert Project.find("missing") == {:error, :unknown_project}
    assert :ok = Project.mount(%{"project_id" => "symphony"})
    assert Project.current() == b
    assert Project.path("/usage") == "/projects/symphony/usage"
    assert_raise ArgumentError, fn -> Project.mount(%{"project_id" => "missing"}) end
  end

  test "task closures carry identity without modifying the caller or global workflow", %{root: root} do
    a = project(root, "a")
    b = project(root, "b")
    Project.bind(a)
    fun = Project.wrap(fn -> {Project.current(), Config.management_state_dir()} end)
    Project.bind(b)
    assert Task.async(fun) |> Task.await() == {a, a.state_dir}
    assert Project.current() == b
    Project.bind(nil)
    assert Project.path("/usage") == "/usage"
    assert Project.name(Orchestrator) == Orchestrator
  end

  test "workers remove credential environment references from every configured repository", %{root: root} do
    a = project(root, "a", "owner/a")
    b = project(root, "b", "owner/b")
    Application.put_env(:symphony_elixir, :projects, [a, b])
    Project.bind(a)
    assert "B_TOKEN" in Project.secret_environment_names()
    assert "A_SECRET" in Settings.worker_secret_environment_names()
    assert "B_SECRET" in Settings.worker_secret_environment_names()
  end

  test "project manifest validates unique IDs and canonical nonoverlapping state/workspace paths", %{root: root} do
    a = project(root, "a")
    b = project(root, "b")
    path = Path.join(root, "projects.json")
    entry = fn p -> %{id: p.id, workflow_path: Path.basename(p.workflow_path), state_dir: p.state_dir} end

    write = fn entries ->
      File.write!(path, Jason.encode!(%{projects: entries}))
      ProjectManifest.load(path)
    end

    assert {:ok, [^a, ^b]} = write.([entry.(a), entry.(b)])
    assert {:error, :duplicate_project_id} = write.([entry.(a), entry.(a)])
    assert {:error, :overlapping_project_paths} = write.([entry.(a), %{entry.(b) | state_dir: a.state_dir}])
    assert {:error, :overlapping_project_paths} = write.([%{entry.(a) | state_dir: a.workspace_root <> "/state"}])
    File.mkdir_p!(a.state_dir)
    File.ln_s!(a.state_dir, Path.join(root, "alias"))
    assert {:error, :overlapping_project_paths} = write.([entry.(a), %{entry.(b) | state_dir: Path.join(root, "alias")}])
    assert {:error, :no_enabled_projects} = write.([])
    assert {:error, :no_enabled_projects} = write.([Map.put(entry.(a), :enabled, false)])
    assert {:error, {:invalid_project_manifest, _}} = write.([%{id: "BAD"}])
    assert {:error, {:invalid_project_manifest, _}} = ProjectManifest.load(path <> ".missing")
    File.write!(path, "[]")
    assert {:error, {:invalid_project_manifest, _}} = ProjectManifest.load(path)
    File.write!(path, "not json")
    assert {:error, {:invalid_project_manifest, _}} = ProjectManifest.load(path)
  end

  test "durable pause is fail closed and preflight disables all dispatch and effects", %{root: root} do
    assert %{dispatch_paused: false, effects_held: false} = DeploymentControl.status()
    assert is_binary(DeploymentControl.revision())
    hold(root, true, false)
    assert DeploymentControl.dispatch_paused?()
    refute DeploymentControl.effects_held?()
    refute DispatchGate.acquire("1")
    hold(root, false, true)
    assert DeploymentControl.dispatch_paused?()
    assert DeploymentControl.effects_held?()
    assert {:error, 0, 0} = HTTP.request("https://invalid.example")
    assert {:error, :effects_held} = Command.run("false", [], root, 100)
    File.write!(Path.join(root, "control/pause.json"), "invalid")
    assert DeploymentControl.effects_held?()
    File.rm!(Path.join(root, "control/pause.json"))
    System.put_env("SYMPHONY_EXTERNAL_EFFECTS", "disabled")
    assert DeploymentControl.effects_held?()
  end

  test "global coding slot queues projects fairly and releases after owner death", %{root: root} do
    a = project(root, "a")
    b = project(root, "b")
    Application.put_env(:symphony_elixir, :projects, [a, b])
    Project.bind(a)
    assert DispatchGate.acquire("1")
    Project.bind(b)
    refute DispatchGate.acquire("1")
    Project.bind(a)
    assert :ok = DispatchGate.release("other")
    DispatchGate.release("1")
    refute DispatchGate.acquire("2")
    Project.bind(b)
    parent = self()
    {pid, monitor} = spawn_monitor(Project.wrap(fn -> send(parent, {:acquired, DispatchGate.acquire("1")}) end))
    assert_receive {:acquired, true}
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    assert :ok = :sys.get_state(DispatchGate) |> then(fn _ -> :ok end)
    Project.bind(a)
    assert DispatchGate.acquire("2")
    DispatchGate.release("2")
  end

  test "checkpoint restores retry deadlines, completed and blocked state without process handles", %{root: root} do
    Project.bind(project(root, "a"))

    state = %Orchestrator.State{
      completed: MapSet.new(["done"]),
      claimed: MapSet.new(["retry"]),
      blocked: %{"blocked" => %{identifier: "1"}},
      retry_attempts: %{
        "retry" => %{
          attempt: 3,
          due_at_ms: System.monotonic_time(:millisecond) - 1,
          retry_token: make_ref(),
          timer_ref: make_ref(),
          identifier: "1"
        }
      }
    }

    assert RuntimeCheckpoint.restore(state) == state
    assert :ok = RuntimeCheckpoint.save(state)
    restored = RuntimeCheckpoint.restore(%Orchestrator.State{})
    assert restored.completed == state.completed
    assert restored.blocked == state.blocked
    assert restored.retry_attempts["retry"].attempt == 3
    assert_receive {:retry_issue, "retry", token}
    assert restored.retry_attempts["retry"].retry_token == token
    refute File.exists?(Path.join(Config.management_state_dir(), "runtime-checkpoint.term"))
  end

  test "scoped LiveViews, API and legacy routes select the correct runtime and history", %{root: root} do
    a = project(root, "registry")
    b = project(root, "symphony")
    runtimes([a, b])
    start_supervised!({@endpoint, []})
    Project.bind(a)
    Store.event("history", "start", %{session: "registry-only"}, 1, DateTime.utc_now())
    Store.put("operator_settings", %{email_sender: "registry@example.test"})
    Store.query!("INSERT INTO reports(week,body,metrics) VALUES(?,?,?)", ["2026-11-09", "registry report", "{}"])
    Project.bind(b)
    Store.event("history", "start", %{session: "symphony-only"}, 1, DateTime.utc_now())
    Store.put("operator_settings", %{email_sender: "symphony@example.test"})
    conn = fn -> %{build_conn() | host: "localhost"} end
    assert [%{"id" => "registry"}, %{"id" => "symphony"}] = json_response(get(conn.(), "/api/v1/projects"), 200)["projects"]
    assert json_response(get(conn.(), "/api/v1/projects/registry/state"), 200)["counts"]["running"] == 0
    assert json_response(get(conn.(), "/api/v1/projects/registry/settings"), 200)["data"]["email_sender"] == "registry@example.test"
    assert json_response(get(conn.(), "/api/v1/projects/symphony/settings/notifications"), 200)["data"]["email_sender"] == "symphony@example.test"
    assert [%{"body" => "registry report"}] = json_response(get(conn.(), "/api/v1/projects/registry/reports"), 200)["data"]
    assert [] == json_response(get(conn.(), "/api/v1/projects/symphony/reports"), 200)["data"]
    assert json_response(get(conn.(), "/api/v1/state"), 200)["counts"]["running"] == 0
    assert response(get(conn.(), "/api/v1/projects/missing/state"), 404) =~ "Unknown project"
    assert json_response(post(conn.(), "/api/v1/projects/symphony/refresh"), 202)["queued"]
    {:ok, dashboard, html} = live(conn.(), "/projects/symphony")
    assert html =~ "/projects/registry"
    assert html =~ "/projects/symphony/usage"
    send(dashboard.pid, :observability_updated)
    assert render(dashboard) =~ "0 running"
    {:ok, usage, _} = live(conn.(), "/projects/symphony/usage")
    assert render(usage) =~ "Usage history"
    {:ok, reports, _} = live(conn.(), "/projects/registry/reports")
    assert render(reports) =~ "/projects/registry"
    health = json_response(get(conn.(), "/api/v1/health"), 200)
    assert health["ready"]
    refute health["checkpoint_ready"]
    expected = :crypto.hash(:sha256, Jason.encode!([a.state_dir, b.state_dir])) |> Base.encode16(case: :lower)
    assert health["state_paths_sha256"] == expected
    hold(root, true, true)
    assert render_click(reports, "test", %{"channel" => "slack"}) =~ "management changes are held"
    health = json_response(get(conn.(), "/api/v1/health"), 200)
    assert health["checkpoint_ready"]
    for p <- [a, b], do: assert(File.regular?(Path.join(p.state_dir, "runtime-checkpoint.term")))
    hold(root, false, false)
    assert json_response(get(conn.(), "/api/v1/projects/symphony/usage"), 200)["data"]["input"] == 0
  end

  test "disabled projects cannot become the legacy default or fall back to another database", %{root: root} do
    a = %{project(root, "disabled") | enabled: false}
    b = project(root, "enabled")
    Application.put_env(:symphony_elixir, :projects, [a, b])
    assert Project.default() == b
    Project.mount(%{})
    assert Project.current() == b
    assert Project.find("disabled") == {:error, :unknown_project}
    assert_raise RuntimeError, ~r/Project storage unavailable/, fn -> Store.repo() end
  end

  test "workflow reload cannot move a running project's workspace root", %{root: root} do
    a = project(root, "a")
    runtimes([a])
    Project.bind(a)
    initial = Config.local_workspace_root()
    File.write!(a.workflow_path, File.read!(a.workflow_path) |> String.replace(a.workspace_root, root <> "/other"))
    assert {:error, {:project_workspace_changed, "a"}} = WorkflowStore.force_reload()
    assert Config.local_workspace_root() == initial
  end

  test "memory fixtures select issues within the bound project", %{root: root} do
    a = project(root, "a")
    fixture = Path.join(root, "issues.json")
    File.write!(fixture, Jason.encode!([%{id: "1", identifier: "S-1", title: "Synthetic", state: "Todo", dispatchable: true}]))
    File.write!(a.workflow_path, File.read!(a.workflow_path) |> String.replace("kind: memory", "kind: memory\n  provider:\n    issues_file: issues.json"))
    Project.bind(a)
    assert {:ok, [%{id: "1"}]} = Memory.fetch_issues_by_ids(["1"])
    assert {:ok, []} = Memory.fetch_issues_by_states(["Done"])
  end

  test "malformed checkpoint and nonfiles fail closed", %{root: root} do
    a = project(root, "a")
    Project.bind(a)
    File.mkdir_p!(a.state_dir)
    path = Path.join(a.state_dir, "runtime-checkpoint.term")
    File.write!(path, :erlang.term_to_binary({2, %{}}))
    assert_raise MatchError, fn -> RuntimeCheckpoint.restore(%Orchestrator.State{}) end
    File.rm!(path)
    File.mkdir!(path)
    assert_raise File.Error, fn -> RuntimeCheckpoint.restore(%Orchestrator.State{}) end
    File.rmdir!(path)
    File.rm_rf!(a.state_dir)
    File.write!(a.state_dir, "file")
    assert {:error, :enotdir} = RuntimeCheckpoint.save(%Orchestrator.State{})
  end

  test "legacy health is ready without management and holds checkpoint dispatch durably", %{root: root} do
    Application.put_env(:symphony_elixir, :projects, [])
    Project.bind(nil)
    Application.put_env(:symphony_elixir, :management_state_dir, root <> "/legacy")
    on_exit(fn -> Application.delete_env(:symphony_elixir, :management_state_dir) end)
    start_supervised!({@endpoint, []})
    health = fn -> get(%{build_conn() | host: "localhost"}, "/api/v1/health") |> json_response(200) end
    assert health.()["ready"]
    hold(root, true, true)
    assert health.()["checkpoint_ready"]
    hold(root, false, false)
    assert DispatchGate.acquire("legacy")
    assert SymphonyElixirWeb.ProjectContext.init([]) == []
    File.rm!(Path.join(root, "control/pause.json"))
    File.mkdir!(Path.join(root, "control/pause.json"))
    assert DeploymentControl.effects_held?()
  end

  test "readiness rejects missing storage, unavailable scheduler and unavailable orchestrator", %{root: root} do
    a = project(root, "a")
    runtimes([a])
    Project.bind(a)
    start_supervised!({@endpoint, []})
    conn = fn -> %{build_conn() | host: "localhost"} end
    scheduler = Project.whereis(Project.name(Scheduler))
    :sys.suspend(scheduler)
    hold(root, true, true)
    health = json_response(get(conn.(), "/api/v1/health"), 503)
    refute health["checkpoint_ready"]
    :sys.resume(scheduler)
    hold(root, false, false)
    runtime = Project.name(SymphonyElixir.AgentRuntimeSupervisor)
    assert :ok = Supervisor.terminate_child(runtime, Project.name(Orchestrator))
    refute json_response(get(conn.(), "/api/v1/health"), 503)["ready"]
    assert :ok = Supervisor.terminate_child(Project.name(SymphonyElixir.Management.Supervisor), SymphonyElixir.Management.Repo)
    refute json_response(get(conn.(), "/api/v1/health"), 503)["ready"]
    assert json_response(get(conn.(), "/api/v1/projects/a/settings"), 503)["error"] == "management_unavailable"
  end

  test "manifest refuses workflow configuration within a coding workspace", %{root: root} do
    a = project(root, "a")
    File.mkdir_p!(a.workspace_root)
    path = Path.join(a.workspace_root, "workflow.md")
    File.cp!(a.workflow_path, path)
    manifest = Path.join(root, "manifest.json")
    File.write!(manifest, Jason.encode!(%{projects: [%{id: a.id, workflow_path: path, state_dir: a.state_dir}]}))
    assert {:error, :workflow_inside_workspace} = ProjectManifest.load(manifest)
  end

  test "multi-project dispatch fails closed when the shared gate is unavailable", %{root: root} do
    a = project(root, "a")
    Application.put_env(:symphony_elixir, :projects, [a])
    Project.bind(a)
    Supervisor.terminate_child(SymphonyElixir.Supervisor, DispatchGate)

    try do
      refute DispatchGate.acquire("1")
      assert :ok = DispatchGate.release("1")
    after
      Supervisor.restart_child(SymphonyElixir.Supervisor, DispatchGate)
    end
  end

  test "promotion pause drains a real fake worker, retains completion, then resumes the other project", %{root: root} do
    a = project(root, "a")
    b = project(root, "b")
    started = root <> "/started"
    release = root <> "/release"
    trace = root <> "/trace"
    binary = root <> "/fake_worker.py"
    fixture = File.read!(Path.expand("../../../deploy/fake_worker.py", __DIR__))
    fixture = String.replace(fixture, "import json", "import json\nimport time")

    fixture =
      String.replace(
        fixture,
        "            issues = json.loads",
        "            Path(sys.argv[4]).write_text(project)\n            while not Path(sys.argv[5]).exists():\n                time.sleep(0.01)\n            issues = json.loads"
      )

    File.write!(binary, fixture)

    for p <- [a, b] do
      issues = root <> "/#{p.id}-issues.json"
      File.write!(issues, Jason.encode!([%{id: "1", identifier: "ISSUE-1", title: "Synthetic", state: "Todo", dispatchable: true}]))

      config = %{
        tracker: %{kind: "memory", provider: %{issues_file: issues}},
        polling: %{interval_ms: 60_000},
        workspace: %{root: p.workspace_root},
        codex: %{command: "python3 #{binary} #{issues} #{trace} #{p.id} #{started} #{release}"},
        management: %{delivery_enabled: false, publish_enabled: false, audit: %{enabled: false}}
      }

      File.write!(p.workflow_path, "---\n#{Jason.encode!(config)}\n---\nSynthetic worker")
    end

    hold(root, true, false)
    runtimes([a, b])
    start_supervised!({@endpoint, []})
    File.rm!(Path.join(root, "control/pause.json"))
    for p <- [a, b], do: Orchestrator.request_refresh(Project.name(Orchestrator, p))
    assert eventually(fn -> File.regular?(started) end)
    active = File.read!(started)
    active_project = Enum.find([a, b], &(&1.id == active))
    [running] = Orchestrator.snapshot(Project.name(Orchestrator, active_project), 1000).running
    assert Process.alive?(Project.whereis(Project.name(Orchestrator, active_project)))
    hold(root, true, false)
    health = fn -> get(%{build_conn() | host: "localhost"}, "/api/v1/health") |> json_response(200) end
    assert health.()["running_jobs"] == 1
    assert running.identifier == "ISSUE-1"
    File.write!(release, "finish")
    assert eventually(fn -> health.()["running_jobs"] == 0 end)
    assert length(File.read!(trace) |> String.split("\n", trim: true)) == 1
    hold(root, true, true)
    assert health.()["checkpoint_ready"]
    # Restore both runtimes from their drain checkpoints while effects stay held.
    for p <- [a, b] do
      stop_supervised!(p.id)
      start_supervised!({SymphonyElixir.ProjectSupervisor, project: p}, id: p.id)
    end

    assert health.()["running_jobs"] == 0
    assert length(File.read!(trace) |> String.split("\n", trim: true)) == 1
    hold(root, false, false)
    for p <- [a, b], do: Orchestrator.request_refresh(Project.name(Orchestrator, p))
    assert eventually(fn -> length(File.read!(trace) |> String.split("\n", trim: true)) == 2 end)
    assert eventually(fn -> health.()["running_jobs"] == 0 end)

    for p <- [a, b] do
      Project.bind(p)
      assert [%{"n" => 1}] = Store.rows("SELECT COUNT(*) AS n FROM events WHERE kind='finish'")
      assert [%{"input" => 10, "output" => 2}] = Store.rows("SELECT input,output FROM usage_observations")
    end
  end

  defp eventually(fun, remaining \\ 200)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, remaining) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, remaining - 1)
    end
  end
end
