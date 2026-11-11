defmodule SymphonyElixir.Management.UITest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias SymphonyElixir.Management.{Settings, Store, UsageHistory}
  @endpoint SymphonyElixirWeb.Endpoint

  setup do
    root = Path.join(System.tmp_dir!(), "management-ui-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:symphony_elixir, @endpoint)
    Application.put_env(:symphony_elixir, :management_state_dir, root)
    Application.put_env(:symphony_elixir, :management_policy, %{"github_auth_mode" => "separate"})
    start_supervised!(SymphonyElixir.Management.Supervisor)
    Application.put_env(:symphony_elixir, @endpoint, Keyword.merge(previous, server: false))
    start_supervised!({@endpoint, []})

    on_exit(fn ->
      Application.put_env(:symphony_elixir, @endpoint, previous)
      Application.delete_env(:symphony_elixir, :management_state_dir)
      Application.delete_env(:symphony_elixir, :management_policy)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "usage view and API show durable observations and reject bad dates" do
    UsageHistory.record(%{
      id: "one",
      session: "session-1",
      at: ~U[2026-11-11 10:00:00Z],
      issue: "1",
      model: "example-model",
      effort: "high",
      usage: %{input: 100, output: 20, cached: nil}
    })

    {:ok, view, _} = live(%{build_conn() | host: "localhost"}, "/usage")
    html = render_submit(element(view, "form"), %{from: "2026-11-11", until: "2026-11-12"})
    assert html =~ "session-1"
    assert html =~ "example-model"
    assert html =~ "Incomplete"
    assert render_submit(element(view, "form"), %{from: "bad", until: "2026-11-12"}) =~ "valid date range"

    assert json_response(
             get(%{build_conn() | host: "localhost"}, "/api/v1/usage?from=2026-11-11&until=2026-11-12"),
             200
           )["data"]["input"] == 100

    assert [%{"session" => "session-1"}] =
             json_response(
               get(%{build_conn() | host: "localhost"}, "/api/v1/usage/sessions?from=2026-11-11&until=2026-11-12"),
               200
             )["data"]

    assert json_response(get(%{build_conn() | host: "localhost"}, "/api/v1/usage?from=bad"), 400)["error"] ==
             "invalid_range_or_page"
  end

  test "settings never render stored credentials and failed deliveries can be replayed" do
    Store.enqueue("blocker:1", "email", "Example blocker", "body")
    Store.query!("UPDATE deliveries SET status='failed'")
    {:ok, view, html} = live(%{build_conn() | host: "localhost"}, "/settings/notifications")
    assert html =~ "Example blocker"
    assert render_click(element(view, "button", "Retry")) =~ "Delivery queued for retry"
    assert [%{"status" => "pending"}] = Store.rows("SELECT status FROM deliveries")

    assert render_submit(element(view, "form[phx-submit=save]"), %{
             sender: "sender@example.test",
             recipients: "user@example.test",
             tenant: "tenant",
             client: "client",
             github_auth_mode: "separate",
             day: "Mon",
             time: "09:00",
             timezone: "UTC",
             slack_webhook: "https://hooks.slack.com/services/synthetic"
           }) =~ "Settings saved and applied"

    refute render(view) =~ "services/synthetic"
  end

  test "Phoenix request and LiveView logging redact every credential field" do
    params = %{
      "github_token" => "SYNTHETIC-GITHUB",
      "m365_secret" => "SYNTHETIC-M365",
      "slack_webhook" => "SYNTHETIC-SLACK",
      "email_sender" => "sender@example.test"
    }

    filtered = Phoenix.Logger.filter_values(params)
    assert filtered["email_sender"] == "sender@example.test"
    for key <- ~w(github_token m365_secret slack_webhook), do: assert(filtered[key] == "[FILTERED]")
  end

  test "preview, explicit test, audit and rate controls report their actual outcome" do
    Application.put_env(:symphony_elixir, :management_http_options, plug: {Req.Test, __MODULE__})
    on_exit(fn -> Application.delete_env(:symphony_elixir, :management_http_options) end)
    Req.Test.set_req_test_to_shared()
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 200, "ok") end)
    {:ok, view, _} = live(%{build_conn() | host: "localhost"}, "/settings/notifications")
    assert render_click(view, "preview") =~ "not an actual invoice"
    assert render_click(view, "audit_now") =~ "Enable analysis"
    assert render_click(view, "test", %{"channel" => "slack"}) =~ "Configure this channel"
    Settings.save(%{}, %{"slack_webhook" => "https://hooks.slack.com/services/synthetic"})
    assert render_click(view, "test", %{"channel" => "slack"}) =~ "Provider accepted"
    assert render_submit(view, "rates", %{"input" => "bad"}) =~ "Enter nonnegative"
    rates = %{"input" => "1", "output" => "2", "cached" => "0.2", "version" => "test", "model" => "example-model"}
    assert render_submit(view, "rates", rates) =~ "Rates saved"
    assert render_submit(view, "rates", Map.put(rates, "model", "bad model")) =~ "Invalid model rates"
    assert render_submit(view, "save", %{"sender" => "bad"}) =~ "Invalid"
    send(view.pid, :refresh)
    assert render(view) =~ "Reports and notifications"
    Application.put_env(:symphony_elixir, :management_policy, %{"audit" => %{"codex_binary" => "/bin/false"}})
    Settings.save(%{"audit" => %{"enabled" => true, "max_calls_per_week" => 1}})
    Store.put("audit_attempts:#{Date.utc_today() |> Date.add(-6 - Date.day_of_week(Date.utc_today()))}", 3)
    # A running audit's lease suppresses a second model invocation.
    {:ok, lease} = Store.claim_job("audit", 120)
    assert render_click(view, "audit_now") =~ "Audit requested"
    assert wait_until(fn -> Store.rows("SELECT COUNT(*) AS n FROM reports") == [%{"n" => 1}] end)
    assert wait_until(fn -> Task.Supervisor.children(SymphonyElixir.Management.Tasks) == [] end)
    Store.release_job("audit", lease)
    assert render_submit(view, "save", %{"audit_timeout" => "invalid"}) =~ "Invalid"
  end

  test "recommendation decisions require notes and preserve evaluation evidence" do
    recommendation = Map.new(~w(title hypothesis evidence evaluation quality_guardrails promotion rollback tradeoff), &{&1, "Example " <> &1})
    Store.query!("INSERT INTO proposals(id,week,status,data,url) VALUES(?,?,?,?,?)", ["p1", "2026-11-02", "proposed", Jason.encode!(recommendation), "https://example.test/pr/1"])
    {:ok, view, html} = live(%{build_conn() | host: "localhost"}, "/reports")
    assert html =~ "Example hypothesis"
    render_submit(view, "decision", %{"proposal_id" => "p1", "state" => "rejected", "note" => ""})
    assert [%{"status" => "proposed"}] = Store.rows("SELECT status FROM proposals")
    render_submit(view, "decision", %{"proposal_id" => "p1", "state" => "evaluating", "note" => "Measured evidence"})
    assert [%{"status" => "evaluating"}] = Store.rows("SELECT status FROM proposals")
    assert [%{"data" => evidence}] = Store.rows("SELECT data FROM events WHERE kind='recommendation'")
    assert evidence =~ "Measured evidence"
  end

  test "pagination and refresh retain usage filters and disabled management is explicit" do
    {:ok, view, _} = live(%{build_conn() | host: "localhost"}, "/usage")
    assert render_click(view, "next") =~ "Page 2"
    assert render_click(view, "previous") =~ "Page 1"
    send(view.pid, :refresh)
    assert render(view) =~ "Usage history"
    stop_supervised!(SymphonyElixir.Management.Supervisor)
    assert json_response(get(%{build_conn() | host: "localhost"}, "/api/v1/usage"), 503)["error"] == "management_unavailable"
    {:ok, _, html} = live(%{build_conn() | host: "localhost"}, "/usage")
    assert html =~ "not enabled"
    {:ok, _, html} = live(%{build_conn() | host: "localhost"}, "/settings/notifications")
    assert html =~ "not enabled"
  end

  defp wait_until(check, attempts \\ 100)
  defp wait_until(_check, 0), do: false

  defp wait_until(check, attempts) do
    if check.(),
      do: true,
      else:
        (
          Process.sleep(10)
          wait_until(check, attempts - 1)
        )
  end
end
