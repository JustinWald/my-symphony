defmodule SymphonyElixir.WorkerEnvironmentTest do
  use SymphonyElixir.TestSupport

  test "coding workers do not inherit the orchestrator's runtime or deployment environment" do
    root = Path.join(System.tmp_dir!(), "worker-environment-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspaces/GH-1")
    File.mkdir_p!(workspace)
    trace = Path.join(workspace, "environment-names.txt")
    binary = Path.join(root, "fake-codex")

    variables = %{
      "SYMPHONY_PROJECT_MANIFEST" => Path.join(root, "host-projects.json"),
      "SYMPHONY_CONTROL_DIR" => Path.join(root, "host-control"),
      "SYMPHONY_MANAGEMENT_STATE_DIR" => Path.join(root, "host-state"),
      "SYMPHONY_WORKER_ENVIRONMENT_TEST" => "host-only",
      "__BURRITO" => "1",
      "__BURRITO_BIN_PATH" => Path.join(root, "host-executable"),
      "ROOTDIR" => Path.join(root, "host-release"),
      "BINDIR" => Path.join(root, "host-release/erts/bin"),
      "RELEASE_ROOT" => Path.join(root, "host-release"),
      "RELEASE_SYS_CONFIG" => Path.join(root, "host-sys-config")
    }

    previous = Map.new(variables, fn {name, _value} -> {name, System.get_env(name)} end)

    on_exit(fn ->
      Enum.each(previous, fn {name, value} -> restore_env(name, value) end)
      File.rm_rf!(root)
    end)

    File.write!(binary, """
    #!/bin/sh
    env | cut -d= -f1 | sort > '#{trace}'
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
        *'"method":"thread/start"'*) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"environment-test"}}}' ;;
      esac
    done
    """)

    File.chmod!(binary, 0o700)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: Path.join(root, "workspaces"), codex_command: binary)
    System.put_env(variables)

    assert {:ok, session} = AppServer.start_session(workspace)
    AppServer.stop_session(session)
    received = trace |> File.read!() |> String.split("\n", trim: true)
    for name <- Map.keys(variables), do: refute(name in received)
    refute Enum.any?(received, &String.starts_with?(&1, "SYMPHONY_"))
    # Scrubbing belongs to the worker boundary; the service retains its own controls.
    for {name, value} <- variables, do: assert(System.get_env(name) == value)
  end
end
