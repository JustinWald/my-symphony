defmodule SymphonyElixir.Management.GitHubTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.Management.{Collector, GitHub, PullRequests, Reports, Settings, Store}

  setup do
    root = Path.join(System.tmp_dir!(), "management-github-#{System.unique_integer([:positive])}")
    Application.put_env(:symphony_elixir, :management_state_dir, root)

    Application.put_env(:symphony_elixir, :management_policy, %{
      "repo" => "example/project",
      "github_auth_mode" => "separate",
      "workflow" => %{"required_checks" => ["validate"], "required_workflows" => ["CI"]}
    })

    Application.put_env(:symphony_elixir, :management_http_options, plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared()
    start_supervised!(SymphonyElixir.Management.Supervisor)
    Settings.save(%{}, %{"github_token" => "synthetic-token"})

    on_exit(fn ->
      for key <- [:management_state_dir, :management_policy, :management_http_options],
          do: Application.delete_env(:symphony_elixir, key)

      File.rm_rf!(root)
    end)

    :ok
  end

  test "handoff waits for a non-draft PR and acceptance uses passing exact-head checks" do
    Req.Test.stub(__MODULE__, &provider(&1, false, nil))
    Collector.collect()
    assert [%{"channel" => "slack"}] = Store.rows("SELECT channel FROM deliveries")
    Collector.collect()
    assert [%{"n" => 1}] = Store.rows("SELECT COUNT(*) AS n FROM deliveries")
    Req.Test.stub(__MODULE__, &provider(&1, false, "2026-11-11T12:00:00Z"))
    Collector.collect()
    assert [%{"kind" => "accepted"}] = Store.rows("SELECT kind FROM events WHERE kind='accepted'")
  end

  test "draft PRs do not trigger a handoff" do
    Req.Test.stub(__MODULE__, &provider(&1, true, nil))
    Collector.collect()
    assert Store.rows("SELECT * FROM deliveries") == []
    assert Store.get("pending_handoff:1") != nil
  end

  test "wrong-head, failed and unconfigured CI cannot count as accepted" do
    check = %{
      "name" => "validate",
      "head_sha" => "head",
      "app" => %{"slug" => "github-actions"},
      "status" => "completed",
      "conclusion" => "success"
    }

    runs = %{
      "total_count" => 1,
      "workflow_runs" => [
        %{
          "name" => "CI",
          "head_sha" => "head",
          "status" => "completed",
          "conclusion" => "success",
          "run_number" => 1,
          "run_attempt" => 1
        }
      ]
    }

    checks = %{"total_count" => 1, "check_runs" => [check]}
    statuses = %{"statuses" => [], "state" => "pending"}
    policy = %{"required_checks" => ["validate"], "required_workflows" => ["CI"]}
    assert PullRequests.checks_pass?(policy, checks, statuses, runs, "head")
    refute PullRequests.checks_pass?(%{}, checks, statuses, runs, "head")
    refute PullRequests.checks_pass?(policy, checks, statuses, runs, "other")

    refute PullRequests.checks_pass?(
             policy,
             %{checks | "check_runs" => [check, %{check | "conclusion" => "failure"}]},
             statuses,
             runs,
             "head"
           )

    refute PullRequests.checks_pass?(policy, %{checks | "total_count" => 101}, statuses, runs, "head")
  end

  test "weekly publication reuses a remote marker after interrupted local persistence" do
    Settings.save(%{"publish_enabled" => true})
    Reports.weekly(~U[2026-11-11 12:00:00Z])

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.method do
        "GET" ->
          Req.Test.json(conn, [
            %{
              "number" => 99,
              "body" => "<!-- symphony-weekly:2026-11-02 -->",
              "html_url" => "https://github.com/example/project/issues/99"
            }
          ])

        "PATCH" ->
          Req.Test.json(conn, %{"number" => 99, "html_url" => "https://github.com/example/project/issues/99"})
      end
    end)

    Reports.publish()

    assert [%{"url" => "https://github.com/example/project/issues/99", "published" => version}] =
             Store.rows("SELECT url,published FROM reports")

    assert is_binary(version)
    Reports.publish()
  end

  test "GitHub pagination and malformed provider responses fail closed" do
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, %{}) end)
    assert {:error, 502, 0} = GitHub.pages(Settings.config(), "/issues")
    assert {:error, 401, 0} = GitHub.call(%{"repo" => "bad/repo/extra"}, "")
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, List.duplicate(%{}, 100)) end)
    assert {:error, 413, 0} = GitHub.pages(Settings.config(), "/issues")
  end

  test "unavailable checks preserve the PR but never accept it" do
    Req.Test.stub(__MODULE__, fn conn ->
      if String.ends_with?(conn.request_path, "/check-runs") do
        Plug.Conn.send_resp(conn, 503, "private")
      else
        provider(conn, false, "2026-11-11T12:00:00Z")
      end
    end)

    Collector.collect()
    assert Store.rows("SELECT * FROM events WHERE kind='accepted'") == []
    assert Store.get("prs")["2"]["checks"] == %{"passed" => false}
  end

  defp provider(conn, draft, merged) do
    payload =
      cond do
        String.ends_with?(conn.request_path, "/issues") ->
          [
            %{
              "number" => 1,
              "title" => "Synthetic task",
              "html_url" => "https://github.com/example/project/issues/1",
              "state" => "open",
              "updated_at" => "2026-11-11T10:00:00Z",
              "labels" => [%{"name" => "symphony-review"}]
            }
          ]

        String.ends_with?(conn.request_path, "/pulls") ->
          [
            %{
              "number" => 2,
              "html_url" => "https://github.com/example/project/pull/2",
              "state" => if(merged, do: "closed", else: "open"),
              "draft" => draft,
              "merged_at" => merged,
              "head" => %{"ref" => "symphony/issue-1", "sha" => "head", "repo" => %{"full_name" => "example/project"}}
            }
          ]

        String.ends_with?(conn.request_path, "/check-runs") ->
          %{
            "total_count" => 1,
            "check_runs" => [
              %{
                "name" => "validate",
                "head_sha" => "head",
                "app" => %{"slug" => "github-actions"},
                "status" => "completed",
                "conclusion" => "success"
              }
            ]
          }

        String.ends_with?(conn.request_path, "/status") ->
          %{"statuses" => []}

        String.ends_with?(conn.request_path, "/actions/runs") ->
          %{
            "total_count" => 1,
            "workflow_runs" => [
              %{
                "name" => "CI",
                "head_sha" => "head",
                "status" => "completed",
                "conclusion" => "success",
                "run_number" => 1,
                "run_attempt" => 1
              }
            ]
          }
      end

    Req.Test.json(conn, payload)
  end
end
