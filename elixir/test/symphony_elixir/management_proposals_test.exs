defmodule SymphonyElixir.Management.ProposalsTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.Management.{Proposals, Settings, Store}

  setup do
    root = Path.join(System.tmp_dir!(), "management-proposal-#{System.unique_integer([:positive])}")
    source = Path.join(root, "source")
    File.mkdir_p!(source)
    System.cmd("git", ["init", "--quiet"], cd: source)
    File.write!(Path.join(source, "WORKFLOW.md"), "original\n")
    System.cmd("git", ["add", "WORKFLOW.md"], cd: source)

    System.cmd(
      "git",
      ["-c", "user.name=Synthetic", "-c", "user.email=synthetic@example.test", "commit", "--quiet", "-m", "fixture"],
      cd: source
    )

    {revision, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: source)
    revision = String.trim(revision)
    binary = Path.join(root, "validator")
    File.write!(binary, "#!/bin/sh\nexit 0\n")
    File.chmod!(binary, 0o700)
    Application.put_env(:symphony_elixir, :management_state_dir, Path.join(root, "state"))

    Application.put_env(:symphony_elixir, :management_policy, %{
      "repo" => "example/project",
      "github_auth_mode" => "separate",
      "source_repo" => source,
      "audit" => %{"codex_binary" => binary, "validation_commands" => [["/bin/true"]]}
    })

    Application.put_env(:symphony_elixir, :management_http_options, plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared()
    start_supervised!(SymphonyElixir.Management.Supervisor)

    Settings.save(%{"publish_enabled" => true, "audit" => %{"enabled" => true, "draft_prs" => true}}, %{
      "github_token" => "synthetic-token"
    })

    recommendation =
      Map.new(
        ~w(title hypothesis evidence evaluation quality_guardrails promotion rollback tradeoff),
        &{&1, "Synthetic evidence"}
      )
      |> Map.put("changes", [%{"path" => "WORKFLOW.md", "content" => "reviewed candidate\n"}])
      |> Map.put("source_revision", revision)

    Store.query!("INSERT INTO proposals(id,week,status,data) VALUES(?,?,?,?)", [
      "2026-11-02-1",
      "2026-11-02",
      "proposed",
      Jason.encode!(recommendation)
    ])

    on_exit(fn ->
      for key <- [:management_state_dir, :management_policy, :management_http_options],
          do: Application.delete_env(:symphony_elixir, key)

      File.rm_rf!(root)
    end)

    %{root: root, revision: revision, binary: binary, recommendation: recommendation}
  end

  test "draft proposal uses a validated independent clone and never mutates the source checkout", %{
    root: root,
    revision: revision
  } do
    parent = self()
    Req.Test.stub(__MODULE__, &provider(&1, revision, parent))
    assert :ok = Proposals.prepare()

    assert [%{"status" => "evaluating", "url" => "https://github.com/example/project/pull/9"}] =
             Store.rows("SELECT status,url FROM proposals")

    assert File.read!(Path.join(root, "source/WORKFLOW.md")) == "original\n"
    assert_receive {:draft_pr, %{"draft" => true, "head" => "symphony/audit-2026-11-02-1"}}
    Proposals.prepare()
    refute_receive {:draft_pr, _}
  end

  test "a changed remote base blocks publication instead of rebasing silently", %{revision: revision} do
    Req.Test.stub(__MODULE__, &provider(&1, revision <> "changed", self()))
    Proposals.prepare()
    assert [%{"status" => "needs_rebase"}] = Store.rows("SELECT status FROM proposals")
  end

  test "validation failure preserves the clone and publishes no PR", %{revision: revision, binary: binary, root: root} do
    File.write!(binary, "#!/bin/sh\nexit 1\n")
    parent = self()
    Req.Test.stub(__MODULE__, &provider(&1, revision, parent))
    Proposals.prepare()
    assert [%{"status" => "validation_failed"}] = Store.rows("SELECT status FROM proposals")
    assert File.exists?(Path.join(root, "state/audit-workspaces/proposal-2026-11-02-1/WORKFLOW.md"))
    refute_receive {:draft_pr, _}
  end

  test "retry preserves unexpected user edits", %{revision: revision, root: root} do
    parent = self()
    Req.Test.stub(__MODULE__, &provider(&1, revision, parent))
    Proposals.prepare()
    workspace = Path.join(root, "state/audit-workspaces/proposal-2026-11-02-1")
    File.write!(Path.join(workspace, "WORKFLOW.md"), "operator edits\n")
    Store.query!("UPDATE proposals SET status='proposed',url=NULL")
    Proposals.prepare()
    assert [%{"status" => "validation_failed"}] = Store.rows("SELECT status FROM proposals")
    assert File.read!(Path.join(workspace, "WORKFLOW.md")) == "operator edits\n"
  end

  defp provider(%{method: "POST", request_path: "/repos/example/project/pulls"} = conn, _revision, parent) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    send(parent, {:draft_pr, Jason.decode!(body)})
    Req.Test.json(conn, %{html_url: "https://github.com/example/project/pull/9"})
  end

  defp provider(conn, revision, _parent) do
    path = conn.request_path

    case {conn.method, path} do
      {"GET", "/repos/example/project"} ->
        Req.Test.json(conn, %{default_branch: "main"})

      {"GET", "/repos/example/project/git/ref/heads/main"} ->
        Req.Test.json(conn, %{object: %{sha: revision}})

      {"GET", "/repos/example/project/git/ref/heads/symphony/" <> _} ->
        Plug.Conn.send_resp(conn, 404, "missing")

      {"GET", "/repos/example/project/git/commits/" <> _} ->
        Req.Test.json(conn, %{tree: %{sha: "base-tree"}})

      {"GET", "/repos/example/project/pulls"} ->
        Req.Test.json(conn, [])

      {"POST", "/repos/example/project/git/trees"} ->
        Req.Test.json(conn, %{sha: "candidate-tree"})

      {"POST", "/repos/example/project/git/commits"} ->
        Req.Test.json(conn, %{sha: "candidate-commit"})

      {"POST", "/repos/example/project/git/refs"} ->
        Req.Test.json(conn, %{ref: "created"})
    end
  end

  test "proposal leases and symlink paths block competing or unsafe publication", %{revision: revision, root: root, recommendation: rec} do
    {:ok, lease} = Store.claim_job("proposal:2026-11-02-1", 120)
    Proposals.prepare()
    assert [%{"status" => "proposed"}] = Store.rows("SELECT status FROM proposals")
    Store.release_job("proposal:2026-11-02-1", lease)
    source = Path.join(root, "source")
    File.ln_s!("WORKFLOW.md", Path.join(source, "link.md"))
    assert {_, 0} = System.cmd("git", ["add", "link.md"], cd: source)
    assert {_, 0} = System.cmd("git", ["-c", "user.name=Test", "-c", "user.email=t@example.test", "commit", "-m", "link"], cd: source)
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: source)
    sha = String.trim(sha)
    policy = Application.get_env(:symphony_elixir, :management_policy)
    Application.put_env(:symphony_elixir, :management_policy, put_in(policy, ["audit", "proposal_paths"], ["*.md"]))
    changed = %{rec | "source_revision" => sha, "changes" => [%{"path" => "link.md", "content" => "unsafe"}]}
    Store.query!("UPDATE proposals SET data=?", [Jason.encode!(changed)])
    Req.Test.stub(__MODULE__, &provider(&1, sha, self()))
    Proposals.prepare()
    assert [%{"status" => "validation_failed"}] = Store.rows("SELECT status FROM proposals")
    assert revision != sha
  end

  test "a previously created ref is reused and an existing PR must match its exact tree and marker", %{revision: revision} do
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/repos/example/project/git/ref/heads/symphony/" <> _} -> Req.Test.json(conn, %{object: %{sha: "candidate-commit"}})
        {"GET", "/repos/example/project/git/commits/candidate-commit"} -> Req.Test.json(conn, %{tree: %{sha: "candidate-tree"}, parents: [%{sha: revision}]})
        _ -> provider(conn, revision, parent)
      end
    end)

    Proposals.prepare()
    assert_receive {:draft_pr, _}
    Store.query!("UPDATE proposals SET status='proposed',url=NULL")

    Req.Test.stub(__MODULE__, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/repos/example/project/pulls"} -> Req.Test.json(conn, [%{head: %{sha: "existing"}, body: "<!-- symphony-proposal:2026-11-02-1 -->", html_url: "https://example.test/pr"}])
        {"GET", "/repos/example/project/git/commits/existing"} -> Req.Test.json(conn, %{tree: %{sha: "candidate-tree"}})
        _ -> provider(conn, revision, parent)
      end
    end)

    Proposals.prepare()
    assert [%{"url" => "https://example.test/pr"}] = Store.rows("SELECT url FROM proposals")
    Store.query!("UPDATE proposals SET status='proposed',url=NULL")

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/repos/example/project/git/ref/heads/symphony/" <> _ -> Plug.Conn.send_resp(conn, 503, "private")
        _ -> provider(conn, revision, parent)
      end
    end)

    Proposals.prepare()
    assert [%{"status" => "validation_failed"}] = Store.rows("SELECT status FROM proposals")
  end
end
