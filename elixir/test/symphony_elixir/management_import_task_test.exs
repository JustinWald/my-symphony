defmodule Mix.Tasks.Management.ImportTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Mix.Tasks.Management.Import, as: ImportTask
  alias SymphonyElixir.Management.{Repo, Schema, Store}

  setup do
    root = Path.join(System.tmp_dir!(), "management-import-task-#{System.unique_integer([:positive])}")
    Application.put_env(:symphony_elixir, :management_state_dir, Path.join(root, "source"))
    {:ok, repo} = Repo.start_link()
    Schema.migrate()
    Store.put("fixture", "preserved")
    GenServer.stop(repo)
    source = Path.join(root, "source/management.sqlite3")

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :management_state_dir)
      File.rm_rf!(root)
    end)

    %{root: root, source: source}
  end

  test "validation mode does not create destination state", %{root: root, source: source} do
    output = capture_io(fn -> ImportTask.run(["--database", source, "--check"]) end)
    assert output =~ "validated"
    refute File.exists?(Path.join(root, "destination"))
  end

  test "interrupted finalization can be repeated without rewriting configuration", %{root: root, source: source} do
    config = Path.join(root, "visibility.json")
    File.write!(config, Jason.encode!(%{repo: "example/project", delivery_enabled: false}))
    target = Path.join(root, "destination")
    telemetry = Path.join(root, "telemetry")
    File.mkdir_p!(telemetry)
    opts = ["--database", source, "--state-dir", target, "--config", config, "--telemetry", telemetry]
    assert capture_io(fn -> ImportTask.run(opts) end) =~ "imported"
    File.write!(config, Jason.encode!(%{repo: "example/changed"}))
    assert capture_io(fn -> ImportTask.run(opts) end) =~ "Already imported"
    assert Jason.decode!(File.read!(Path.join(target, "policy.json")))["repo"] == "example/project"
  end

  test "missing arguments, source or destination fail explicitly", %{source: source} do
    assert_raise Mix.Error, fn -> ImportTask.run([]) end
    assert_raise Mix.Error, fn -> ImportTask.run(["--database", source, "--unknown"]) end
    assert_raise Mix.Error, fn -> ImportTask.run(["--database", source]) end
    assert_raise Mix.Error, fn -> ImportTask.run(["--database", source <> ".missing", "--check"]) end
  end

  test "a nonempty destination is never overwritten", %{root: root, source: source} do
    target = Path.join(root, "target")
    Application.put_env(:symphony_elixir, :management_state_dir, target)
    {:ok, repo} = Repo.start_link()
    Schema.migrate()
    Store.put("existing", "preserve")
    GenServer.stop(repo)

    assert_raise Mix.Error, ~r/original state preserved/, fn ->
      ImportTask.run(["--database", source, "--state-dir", target])
    end
  end
end
