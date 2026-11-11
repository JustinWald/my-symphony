defmodule SymphonyElixir.Management.OperationsTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.Management.{Audit, Collector, Credentials, Delivery, HTTP, Reports, Scheduler, Settings, Store}

  setup do
    root = Path.join(System.tmp_dir!(), "management-operations-#{System.unique_integer([:positive])}")
    Application.put_env(:symphony_elixir, :management_state_dir, root)

    Application.put_env(:symphony_elixir, :management_policy, %{
      "repo" => "example/project",
      "github_auth_mode" => "separate",
      "delivery_enabled" => false
    })

    Application.put_env(:symphony_elixir, :management_http_options, plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared()
    start_supervised!(SymphonyElixir.Management.Supervisor)

    on_exit(fn ->
      for key <- [:management_state_dir, :management_policy, :management_http_options],
          do: Application.delete_env(:symphony_elixir, key)

      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "credentials are write-only, preserved on edits, and cannot override the host policy", %{root: root} do
    assert :ok = Settings.save(%{"email_recipients" => ["user@example.test"]}, %{"github_token" => "synthetic-token"})
    assert Settings.public()["credentials"]["github_token"]
    refute inspect(Settings.public()) =~ "synthetic-token"
    refute inspect(Settings.config()) =~ "synthetic-token"
    assert Settings.secret(Settings.config(), "github_token") == "synthetic-token"
    assert {:ok, %{mode: mode}} = File.stat(Path.join(root, Store.get("active_credentials_file")))
    assert Bitwise.band(mode, 0o777) == 0o600
    assert :ok = Settings.save(%{"github_auth_mode" => "symphony"})
    assert {:error, _} = Settings.save(%{}, %{"github_token" => "override"})
    assert {:error, _} = Settings.save(%{"audit" => %{"proposal_paths" => ["*"]}})
    assert {:error, _} = Settings.save(%{"source_repo" => "/"})
    assert {:error, _} = Settings.save(%{}, %{"unknown" => "x"})
    assert {:error, _} = Settings.save(%{}, %{"slack_webhook" => "line\nbreak"})
  end

  test "invalid schedule, notification and email settings are rejected" do
    for change <- [
          %{"weekly" => %{"day" => "Notaday"}},
          %{"weekly" => %{"time" => "25:00"}},
          %{"weekly" => %{"timezone" => "Not/AZone"}},
          %{"weekly" => %{"enabled" => "yes"}},
          %{"weekly" => %{"extra" => true}},
          %{"weekly" => "bad"},
          %{"audit" => "bad"},
          %{"email_recipients" => "bad"},
          %{"email_recipients" => ["bad"]},
          %{"email_sender" => "bad"},
          %{"delivery_enabled" => "yes"},
          %{"github_auth_mode" => "unknown"},
          %{"audit" => %{"max_calls_per_week" => 4}},
          %{"audit" => %{"timeout_seconds" => 1}},
          %{"audit" => %{"enabled" => "yes"}},
          %{"audit" => %{"effort" => "unknown"}},
          %{"notifications" => %{"slack" => %{"enabled" => "yes"}}},
          %{"notifications" => "bad"}
        ] do
      assert {:error, _} = Settings.save(change)
    end
  end

  test "provider failures retry without saving provider secrets" do
    Settings.save(%{"delivery_enabled" => true, "weekly" => %{"enabled" => false}}, %{
      "slack_webhook" => "https://hooks.slack.com/services/synthetic"
    })

    Store.enqueue("blocker:one", "slack", "Attention", "body")

    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_resp_header("retry-after", "120") |> Plug.Conn.send_resp(429, "private-provider-response")
    end)

    assert :ok = Delivery.drain()

    assert [%{"status" => "pending", "attempts" => 1, "error" => "HTTP 429"}] =
             Store.rows("SELECT status,attempts,error FROM deliveries")

    Store.query!("UPDATE deliveries SET due=0")
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 400, "private-provider-response") end)
    Delivery.drain()
    assert [%{"status" => "failed"}] = Store.rows("SELECT status FROM deliveries")
    Delivery.replay("blocker:one:slack")
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 200, "ok") end)
    Delivery.drain()
    assert [%{"status" => "accepted"}] = Store.rows("SELECT status FROM deliveries")
  end

  test "disabled delivery does not call providers and preference-disabled messages are suppressed" do
    Store.enqueue("weekly:test", "email", "subject", "body")
    Delivery.drain()
    assert [%{"status" => "pending"}] = Store.rows("SELECT status FROM deliveries")
    Settings.save(%{"weekly" => %{"enabled" => false}})
    Delivery.drain()
    assert [%{"status" => "suppressed"}] = Store.rows("SELECT status FROM deliveries")
  end

  test "weekly heartbeat queues once even when GitHub observations are unavailable" do
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 503, "private") end)
    Collector.collect()
    Reports.weekly(~U[2026-11-11 12:00:00Z])
    Reports.weekly(~U[2026-11-11 13:00:00Z])
    assert [%{"n" => 2}] = Store.rows("SELECT COUNT(*) AS n FROM deliveries")
    assert [%{"body" => body}] = Store.rows("SELECT body FROM reports")
    assert body =~ "unavailable"
    assert body =~ "not an actual invoice"
    Reports.publish()
    Audit.run()
  end

  test "weekly scheduling persists completion and honors timezone" do
    config = %{"weekly" => %{"enabled" => true, "day" => "Mon", "time" => "09:00", "timezone" => "America/Chicago"}}
    refute Scheduler.due?(config, ~U[2026-11-09 14:00:00Z])
    assert Scheduler.due?(config, ~U[2026-11-09 15:00:00Z])
    Store.put("weekly_schedule_last", "2026-11-09T15:00:00Z")
    refute Scheduler.due?(config, ~U[2026-11-10 15:00:00Z])
    refute Scheduler.due?(%{"weekly" => %{"enabled" => false}}, ~U[2026-11-11 15:00:00Z])
  end

  test "HTTP failures expose only status and bounded retry metadata" do
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 500, "secret") end)
    assert {:error, 500, 0} = HTTP.request("https://example.test")
  end

  test "audit paths and evidence fail closed" do
    assert Audit.allowed_path?("docs/new.md", ["docs/*"])

    for path <- ["../escape", "/absolute", ".git/config", "docs/private.env", "docs/key.pem", "docs/../WORKFLOW.md"] do
      refute Audit.allowed_path?(path, ["*"])
    end

    assert {:error, :invalid_analysis} = Audit.validate(%{"summary" => "x", "recommendations" => [%{}]}, %{})
    assert :ok = Audit.validate(%{"summary" => "Insufficient evidence", "recommendations" => []}, %{})
  end

  test "test sends are explicit, leased, rate limited and retain only redacted outcomes" do
    assert {:error, _} = Delivery.test("unknown")
    assert {:error, _} = Delivery.test("slack")
    assert :ok = Settings.save(%{}, %{"slack_webhook" => "https://hooks.slack.com/services/synthetic"})
    {:ok, lease} = Store.claim_job("test-delivery:slack", 120)
    assert :busy = Store.claim_job("test-delivery:slack", 120)
    Store.release_job("test-delivery:slack", "wrong-owner")
    assert {:error, _} = Delivery.test("slack")
    Store.release_job("test-delivery:slack", lease)
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 200, "ok") end)
    assert :ok = Delivery.test("slack")
    assert {:error, _} = Delivery.test("slack")
    Store.put("last_test:slack", 0)
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 401, "private") end)
    assert {:error, _} = Delivery.test("slack")
    assert [%{"status" => "accepted"}, %{"status" => "failed"}] = Store.rows("SELECT status FROM deliveries ORDER BY rowid")
    invalid = %{"_managed_secrets" => %Credentials{values: %{"slack_webhook" => "invalid"}}}
    assert {:error, 400, 0} = Delivery.send_message(invalid, %{"channel" => "slack"})
    assert {:error, 400, 0} = Delivery.send_message(%{}, %{"channel" => "unknown"})
  end

  test "Microsoft client credentials exchange and message use the configured sender and recipients" do
    config = %{"email_sender" => "sender@example.test", "email_recipients" => ["one@example.test"], "m365_tenant" => "tenant", "m365_client" => "client"}
    Settings.save(config, %{"m365_secret" => "synthetic-private"})
    row = %{"channel" => "email", "subject" => "Subject", "body" => "Body"}
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case conn.host do
        "login.microsoftonline.com" ->
          assert URI.decode_query(body)["client_secret"] == "synthetic-private"
          Req.Test.json(conn, %{access_token: "synthetic-access"})

        "graph.microsoft.com" ->
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer synthetic-access"]
          message = Jason.decode!(body)["message"]
          assert message["subject"] == "Subject"
          send(parent, :message_sent)
          Plug.Conn.send_resp(conn, 202, "")
      end
    end)

    assert {:ok, nil} = Delivery.send_message(Settings.config(), row)
    assert_receive :message_sent
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 401, "private") end)
    assert {:error, 401, 0} = Delivery.send_message(Settings.config(), row)
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, %{}) end)
    assert {:error, 400, 0} = Delivery.send_message(Settings.config(), row)
    assert :ok = Settings.save(%{"delivery_enabled" => true, "weekly" => %{"enabled" => false}})
    Store.enqueue("handoff:one", "email", "subject", "body")
    Store.put("active_credentials_file", "missing")
    Delivery.drain()
    assert [%{"attempts" => 0, "error" => "delivery unconfigured"}] = Store.rows("SELECT attempts,error FROM deliveries")
  end

  test "provider retry dates, transport exceptions and response limits fail closed" do
    for retry <- ["not-a-date", "Wed, 11 Nov 2037 12:00:00 GMT"] do
      Req.Test.stub(__MODULE__, fn conn -> conn |> Plug.Conn.put_resp_header("retry-after", retry) |> Plug.Conn.send_resp(503, "private") end)
      assert {:error, 503, seconds} = HTTP.request("https://example.test")
      assert is_integer(seconds)
    end

    Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :timeout) end)
    assert {:error, 0, 0} = HTTP.request("https://example.test")
    Req.Test.stub(__MODULE__, fn _ -> raise "synthetic-secret" end)
    assert {:error, 0, 0} = HTTP.request("https://example.test")
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 200, String.duplicate("x", 4_000_001)) end)
    assert {:error, 413, 0} = HTTP.request("https://example.test")
  end

  test "failure notices deduplicate until eligibility or completed progress changes" do
    alias SymphonyElixir.Management.Health
    issue = %{"title" => "Issue", "url" => "https://example.test/issues/1"}
    Store.query!("INSERT INTO issues(number,data) VALUES(?,?)", [1, Jason.encode!(issue)])
    entry = %{issue_id: "id-1", identifier: "RR-1", attempt: 3, has_error: true}
    Health.observe(%{retrying: [entry, %{entry | identifier: "not-an-issue"}, %{entry | identifier: "RR-2"}, %{entry | attempt: 1}]})
    Health.observe(%{retrying: [entry]})
    assert [%{"n" => 2}] = Store.rows("SELECT COUNT(*) AS n FROM deliveries")
    Store.put("eligibility_episode:1", "new")
    Store.event("progress", "turn", %{status: "completed"}, 1, DateTime.utc_now())
    Health.observe(%{retrying: [entry]})
    assert [%{"n" => 4}] = Store.rows("SELECT COUNT(*) AS n FROM deliveries")

    fake =
      spawn(fn ->
        receive do
          {:"$gen_call", from, :snapshot} -> GenServer.reply(from, :unavailable)
        end
      end)

    Process.register(fake, :native_fake_orchestrator)
    assert Health.current(:native_fake_orchestrator).api == "unavailable"
  end

  test "invalid rate cards and malformed credentials cannot become active", %{root: root} do
    for change <- [
          %{"rate_card" => "bad"},
          %{"rate_card" => %{"models" => %{"model" => "bad"}}},
          %{"notifications" => %{"slack" => false}},
          %{"audit" => %{"model" => "invalid model"}},
          %{"m365_client" => ["bad"]},
          %{"email_recipients" => List.duplicate("a@example.test", 26)}
        ] do
      assert {:error, _} = Settings.save(change)
    end

    refute Settings.ready?(%{}, "unknown")
    Store.put("active_credentials_file", "../../escape")
    assert Settings.secret(%{}, "github_token") == ""
    Store.put("active_credentials_file", "credentials.json")
    File.write!(Path.join(root, "credentials.json"), "invalid")
    assert Settings.secret(%{}, "github_token") == ""
    File.rm!(Path.join(root, "credentials.json"))
    File.mkdir!(Path.join(root, "credentials.json"))
    assert {:error, _} = Settings.save(%{}, %{"github_token" => "synthetic"}) |> fail_persistence(root)
  end

  defp fail_persistence(_result, root) do
    # The active settings pointer must survive a failed atomic credential write.
    File.rename!(root, root <> "-saved")
    File.write!(root, "blocked path")
    result = Settings.save(%{}, %{"github_token" => "synthetic"})
    File.rm!(root)
    File.rename!(root <> "-saved", root)
    result
  end

  test "collection preserves issue transitions and records recovery gaps" do
    Settings.save(%{}, %{"github_token" => "synthetic"})
    Store.put("collector_at", "2026-01-01T00:00:00Z")
    Store.put("github_gap_start", "2026-01-01T00:00:00Z")
    issue = %{"number" => 1, "title" => "Example", "state" => "closed", "updated_at" => "2026-11-01T00:00:00Z", "html_url" => "https://example.test/1", "labels" => [%{"name" => "symphony-blocked"}]}

    Req.Test.stub(__MODULE__, fn conn ->
      if String.ends_with?(conn.request_path, "/issues"), do: Req.Test.json(conn, [issue, %{"pull_request" => %{}}]), else: Req.Test.json(conn, [])
    end)

    Collector.collect()
    opened = %{issue | "state" => "open", "updated_at" => "2026-11-02T00:00:00Z", "labels" => [%{"name" => "symphony-ready"}]}

    Req.Test.stub(__MODULE__, fn conn ->
      if String.ends_with?(conn.request_path, "/issues"), do: Req.Test.json(conn, [opened]), else: Req.Test.json(conn, [])
    end)

    Collector.collect()
    blocked = %{opened | "updated_at" => "2026-11-03T00:00:00Z", "labels" => [%{"name" => "symphony-blocked"}]}

    Req.Test.stub(__MODULE__, fn conn ->
      if String.ends_with?(conn.request_path, "/issues"), do: Req.Test.json(conn, [blocked]), else: Req.Test.json(conn, [])
    end)

    Collector.collect()
    assert Store.get("github_gap_start") == nil
    assert Store.get("eligibility_episode:1") == opened["updated_at"]
    assert [%{"n" => 1}] = Store.rows("SELECT COUNT(*) AS n FROM events WHERE kind='reopened'")
    assert [%{"n" => 2}] = Store.rows("SELECT COUNT(*) AS n FROM deliveries")
  end

  test "weekly publication creates once, updates by saved URL, and retains failures for retry" do
    Settings.save(%{"publish_enabled" => true}, %{"github_token" => "synthetic"})
    Reports.weekly(~U[2026-11-11 00:00:00Z], notify: false)
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.method do
        "GET" ->
          Req.Test.json(conn, [])

        "POST" ->
          send(parent, :created)
          Req.Test.json(conn, %{html_url: "https://github.com/example/project/issues/9"})

        "PATCH" ->
          send(parent, :updated)
          Req.Test.json(conn, %{html_url: "https://github.com/example/project/issues/9"})
      end
    end)

    Reports.publish()
    assert_receive :created
    Reports.publish()
    refute_receive :created
    Store.query!("UPDATE reports SET audit='New evidence'")
    Reports.publish()
    assert_receive :updated
    Store.query!("UPDATE reports SET audit='More evidence'")
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 503, "private") end)
    Reports.publish()
    assert Store.get("publication_health") =~ "unavailable"
  end

  test "shared GitHub authentication never falls back to separate credentials, and enabling requires ready channels" do
    Settings.save(%{}, %{"github_token" => "separate"})
    Application.put_env(:symphony_elixir, :management_policy, %{"github_auth_mode" => "symphony", "symphony_github_token_env" => "NATIVE_TEST_SHARED"})
    System.put_env("NATIVE_TEST_SHARED", "shared")
    on_exit(fn -> System.delete_env("NATIVE_TEST_SHARED") end)
    assert Settings.secret(Settings.config(), "github_token") == "shared"
    assert Settings.ready?(Settings.config(), "github")
    assert {:error, _} = Settings.save(%{"delivery_enabled" => true})
    assert {:error, _} = Settings.save(%{"delivery_enabled" => true}, %{"slack_webhook" => "https://hooks.slack.com/services/synthetic"})
    assert :ok = Settings.save(%{"delivery_enabled" => true, "notifications" => %{"email" => %{"weekly" => false}}}, %{"slack_webhook" => "https://hooks.slack.com/services/synthetic"})
    Application.put_env(:symphony_elixir, :management_policy, %{"audit" => false})
    assert {:error, _} = Settings.validate(%{}, %{})
  end

  test "health exposes retry classifications without raw worker errors" do
    alias SymphonyElixir.Management.Health
    name = :native_health_orchestrator
    snapshot = %{running: [], retrying: [%{issue_id: "id", identifier: "RR-1", attempt: 3, error: "SYNTHETIC-PRIVATE"}], blocked: []}

    fake =
      spawn(fn ->
        receive do
          {:"$gen_call", from, :snapshot} -> GenServer.reply(from, snapshot)
        end
      end)

    Process.register(fake, name)
    health = Health.current(name)
    assert health.retrying == [%{issue_id: "id", identifier: "RR-1", attempt: 3, has_error: true}]
    refute inspect(health) =~ "SYNTHETIC-PRIVATE"
  end
end
