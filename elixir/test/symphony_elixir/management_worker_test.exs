defmodule SymphonyElixir.Management.WorkerTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Management.{Settings, Store, UsageHistory}

  test "coding harness receives neither notifier secrets nor legacy sandbox overrides" do
    root = Path.join(System.tmp_dir!(), "native-worker-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(root, "workspaces")
    workspace = Path.join(workspace_root, "GH-1")
    File.mkdir_p!(workspace)
    binary = Path.join(root, "fake-codex")
    environment_trace = Path.join(root, "environment.txt")
    protocol_trace = Path.join(root, "protocol.jsonl")
    Application.put_env(:symphony_elixir, :management_state_dir, Path.join(root, "state"))
    Application.put_env(:symphony_elixir, :management_policy, %{"m365_secret_env" => "NATIVE_TEST_GRAPH_SECRET"})
    System.put_env("NATIVE_TEST_GRAPH_SECRET", "SYNTHETIC-SECRET")
    start_supervised!(SymphonyElixir.Management.Supervisor)

    on_exit(fn ->
      System.delete_env("NATIVE_TEST_GRAPH_SECRET")
      Application.delete_env(:symphony_elixir, :management_state_dir)
      Application.delete_env(:symphony_elixir, :management_policy)
      File.rm_rf!(root)
    end)

    File.write!(binary, """
    #!/bin/sh
    if [ -z "${NATIVE_TEST_GRAPH_SECRET+x}" ]; then printf stripped > '#{environment_trace}'; else printf leaked > '#{environment_trace}'; fi
    count=0
    while IFS= read -r line; do
      printf '%s\\n' "$line" >> '#{protocol_trace}'
      count=$((count + 1))
      case "$count" in
        1) printf '%s\\n' '{"id":1,"result":{}}' ;;
        3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-test"},"model":"model-test","reasoningEffort":"high"}}' ;;
      esac
    done
    """)

    File.chmod!(binary, 0o700)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root, codex_command: binary)

    workflow =
      File.read!(Workflow.workflow_file_path())
      |> String.replace("codex:\n", "codex:\n  preserve_permission_profile: true\n")

    File.write!(Workflow.workflow_file_path(), workflow)
    WorkflowStore.force_reload()
    assert {:ok, session} = AppServer.start_session(workspace)
    AppServer.stop_session(session)
    assert File.read!(environment_trace) == "stripped"

    thread =
      protocol_trace
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.find(&(&1["method"] == "thread/start"))

    refute Map.has_key?(thread["params"], "sandbox")
    Application.delete_env(:symphony_elixir, :management_policy)
    path = Workflow.workflow_file_path()
    workflow = File.read!(path) |> String.replace("---\n", "---\nmanagement:\n  repo: example/native\n", global: false)
    File.write!(path, workflow)
    WorkflowStore.force_reload()
    assert Settings.config()["repo"] == "example/native"
  end

  test "a harness that fails before its first turn remains visible as an incomplete failed session" do
    root = Path.join(System.tmp_dir!(), "native-start-failure-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(root, "workspaces")
    workspace = Path.join(workspace_root, "GH-1")
    File.mkdir_p!(workspace)
    Application.put_env(:symphony_elixir, :management_state_dir, Path.join(root, "state"))
    Application.put_env(:symphony_elixir, :management_policy, %{})
    start_supervised!(SymphonyElixir.Management.Supervisor)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :management_state_dir)
      Application.delete_env(:symphony_elixir, :management_policy)
      File.rm_rf!(root)
    end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root, codex_command: "/bin/false")
    WorkflowStore.force_reload()
    assert {:error, _} = AppServer.start_session(workspace, issue: %{id: "1"})
    :sys.get_state(SymphonyElixir.Management.Recorder)
    [%{"data" => text}] = Store.rows("SELECT data FROM events WHERE kind='finish'")
    assert Jason.decode!(text)["returncode"] == 1
    assert Jason.decode!(text)["usage_missing"]
    from = DateTime.add(DateTime.utc_now(), -60)
    until = DateTime.add(DateTime.utc_now(), 60)
    assert [%{"incomplete" => true, "failures" => 1, "input_tokens" => nil}] = UsageHistory.sessions(from, until, 1)
  end
end
