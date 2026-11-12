defmodule SymphonyElixir.Management.AuditTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.Management.{Audit, Command, Proposals, Reports, Settings, Store}

  setup do
    root = Path.join(System.tmp_dir!(), "management-audit-#{System.unique_integer([:positive])}")
    Application.put_env(:symphony_elixir, :management_state_dir, root)
    Application.put_env(:symphony_elixir, :management_policy, %{})
    start_supervised!(SymphonyElixir.Management.Supervisor)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :management_state_dir)
      Application.delete_env(:symphony_elixir, :management_policy)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "command execution bounds output, timeout and exit failures", %{root: root} do
    assert {:ok, "hello"} = Command.run("/bin/echo", ["hello"], root, 1000)
    assert {:error, :command_failed} = Command.run("/bin/false", [], root, 1000)
    assert {:error, :timeout} = Command.run("/bin/sleep", ["2"], root, 20)
    assert {:error, :output_limit} = Command.run("/usr/bin/head", ["-c", "1000001", "/dev/zero"], root, 1000)
  end

  test "analysis retries are bounded and failure never fabricates a recommendation", %{root: root} do
    Application.put_env(:symphony_elixir, :management_policy, %{"audit" => %{"codex_binary" => "/bin/false"}})
    Settings.save(%{"audit" => %{"enabled" => true, "max_calls_per_week" => 1}})
    Reports.weekly(~U[2026-11-11 00:00:00Z])
    Audit.run()
    Audit.run()
    assert Store.get("audit_attempts:2026-11-02") == 1
    assert Store.get("audit_health") =~ "unavailable"
    assert Store.rows("SELECT * FROM proposals") == []
    Proposals.prepare()
    assert File.dir?(root)
  end

  test "analysis without file changes persists its evidence", %{root: root} do
    binary = Path.join(root, "fake-codex")

    result = %{
      summary: "Insufficient sample; improve measurements",
      recommendations: [
        %{
          title: "Measure",
          hypothesis: "More observations reduce uncertainty",
          evidence: "No observations",
          evaluation: "Collect a full week",
          quality_guardrails: "Retain validation",
          promotion: "Human review",
          rollback: "Disable measurement",
          tradeoff: "Storage overhead",
          changes: []
        }
      ]
    }

    script =
      ~S"""
      #!/bin/sh
      while [ "$#" -gt 0 ]; do
        if [ "$1" = '--output-last-message' ]; then shift; output="$1"; fi
        shift
      done
      cat > "$output" <<'SYNTHETIC'
      """ <> Jason.encode!(result) <> "\nSYNTHETIC\n"

    File.write!(binary, script)
    File.chmod!(binary, 0o700)
    Application.put_env(:symphony_elixir, :management_policy, %{"audit" => %{"codex_binary" => binary}})
    Settings.save(%{"audit" => %{"enabled" => true}})
    Reports.weekly(~U[2026-11-11 00:00:00Z])
    Audit.run()
    assert [%{"status" => "proposed"}] = Store.rows("SELECT status FROM proposals")
    assert [%{"audit" => audit}] = Store.rows("SELECT audit FROM reports")
    assert audit =~ "Insufficient sample; improve measurements"
    assert audit =~ "rollback: Disable measurement"
    Audit.run()
    assert Store.get("audit_attempts:2026-11-02") == 1
  end

  test "analysis rejects duplicate paths, unsupported files, and oversized changes" do
    base =
      Map.new(
        ~w(title hypothesis evidence evaluation quality_guardrails promotion rollback tradeoff),
        &{&1, "evidence"}
      )

    valid = Map.put(base, "changes", [%{"path" => "WORKFLOW.md", "content" => "test"}])
    assert :ok = Audit.validate(%{"summary" => "test", "recommendations" => [valid]}, %{})

    for changes <- [
          "bad",
          [%{"path" => "WORKFLOW.md", "content" => String.duplicate("x", 100_001)}],
          [%{"path" => "private.env", "content" => "x"}],
          List.duplicate(%{"path" => "WORKFLOW.md", "content" => "x"}, 2)
        ] do
      assert {:error, :invalid_analysis} =
               Audit.validate(%{"summary" => "test", "recommendations" => [Map.put(base, "changes", changes)]}, %{})
    end

    assert {:error, _} = Audit.validate(%{}, %{})
    assert {:error, _} = Audit.validate(%{"summary" => "test", "recommendations" => ["invalid"]}, %{})
  end

  test "audit reads only bounded tracked evidence from a disposable revision and records observed model usage", %{root: root} do
    source = Path.join(root, "source")
    File.mkdir_p!(source)
    File.write!(Path.join(source, "WORKFLOW.md"), "Synthetic workflow")
    File.write!(Path.join(source, "large.md"), String.duplicate("x", 30_001))
    File.write!(Path.join(source, "other.txt"), "excluded")
    File.ln_s!("other.txt", Path.join(source, "link.md"))

    for args <- [["init", "-b", "main"], ["add", "."], ["-c", "user.name=Test", "-c", "user.email=test@example.test", "commit", "-m", "fixture"]] do
      assert {_, 0} = System.cmd("git", args, cd: source, stderr_to_stdout: true)
    end

    binary = Path.join(root, "fake-codex")

    script = ~S"""
    #!/bin/sh
    while [ "$#" -gt 0 ]; do
      if [ "$1" = '--output-last-message' ]; then shift; output="$1"; fi
      shift
    done
    cat > captured-prompt.json
    echo '{"summary":"Measured evidence","recommendations":[]}' > "$output"
    echo '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":2,"cached_input_tokens":3}}'
    echo '{"type":"turn.completed","usage":{"input_tokens":5,"output_tokens":1}}'
    echo 'malformed line'
    """

    File.write!(binary, script)
    File.chmod!(binary, 0o700)
    policy = %{"source_repo" => source, "audit" => %{"enabled" => true, "codex_binary" => binary, "proposal_paths" => ["*.md"]}}
    Application.put_env(:symphony_elixir, :management_policy, policy)
    Audit.run()
    Reports.weekly(~U[2026-11-11 00:00:00Z], notify: false)
    {:ok, token} = Store.claim_job("audit:2026-11-02", 120)
    Audit.run()
    refute Store.get("audit_attempts:2026-11-02")
    Store.release_job("audit:2026-11-02", token)
    Audit.run()
    assert [%{"input" => 15, "output" => 3, "cached" => nil}] = Store.rows("SELECT input,output,cached FROM usage_observations")
    [prompt] = Path.wildcard(Path.join(root, "audit-*/captured-prompt.json"))
    [_, json] = String.split(File.read!(prompt), "\n", parts: 2)
    evidence = Jason.decode!(json)["source"]
    assert evidence["files"] == %{"WORKFLOW.md" => "Synthetic workflow"}
    assert byte_size(evidence["revision"]) == 40
  end
end
