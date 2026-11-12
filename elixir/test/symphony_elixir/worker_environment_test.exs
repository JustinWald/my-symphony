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
      "SYMPHONY_WORKER_ENVIRONMENT_TEST" => "host-only"
    }

    previous = Map.new(variables, fn {name, _value} -> {name, System.get_env(name)} end)

    on_exit(fn ->
      Enum.each(previous, fn {name, value} -> restore_env(name, value) end)
      File.rm_rf!(root)
    end)

    File.write!(binary, """
    #!/bin/sh
    env | sed -n '/^SYMPHONY_/s/=.*//p' > '#{trace}'
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
    assert File.read!(trace) == ""
    # Scrubbing belongs to the worker boundary; the service retains its own controls.
    for {name, value} <- variables, do: assert(System.get_env(name) == value)
  end
end
