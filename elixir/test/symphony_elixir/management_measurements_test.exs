defmodule SymphonyElixir.Management.MeasurementsTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.Management.{Measurements, Store, UsageHistory}

  setup do
    root = Path.join(System.tmp_dir!(), "management-metrics-#{System.unique_integer([:positive])}")
    Application.put_env(:symphony_elixir, :management_state_dir, root)
    Application.put_env(:symphony_elixir, :management_policy, %{})
    start_supervised!(SymphonyElixir.Management.Supervisor)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :management_state_dir)
      Application.delete_env(:symphony_elixir, :management_policy)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "outcome metrics distinguish accepted work, observed failures, waiting and incomplete coverage" do
    from = ~U[2026-11-02 00:00:00Z]
    until = ~U[2026-11-09 00:00:00Z]
    Store.put("collection_started_at", "2026-11-01T00:00:00Z")
    Store.put("collector_at", "2026-11-09T00:00:00Z")
    Store.event("start", "start", %{session: "s", model: "m"}, 1, DateTime.add(from, 60))
    Store.event("failed", "turn", %{session: "s", status: "failed"}, 1, DateTime.add(from, 90))
    Store.event("finish", "finish", %{session: "s", seconds: 120, returncode: 1}, 1, DateTime.add(from, 180))
    Store.event("handoff", "handoff", %{url: "https://example.test/issue/1"}, 1, DateTime.add(from, 200))

    Store.event(
      "accepted",
      "accepted",
      %{checks: %{started_at: "2026-11-02T00:00:00Z", completed_at: "2026-11-02T00:01:00Z"}},
      1,
      DateTime.add(from, 300)
    )

    Store.event("reopened", "reopened", %{}, 1, DateTime.add(from, 400))

    UsageHistory.record(%{
      id: "u",
      session: "s",
      at: DateTime.add(from, 180),
      model: "m",
      usage: %{input: 100, output: 20, cached: 10}
    })

    Store.query!("INSERT INTO issues(number,data) VALUES(?,?)", [
      1,
      Jason.encode!(%{
        number: 1,
        url: "https://example.test/issue/1",
        state: "open",
        labels: ["symphony-review", "symphony-regression", "regression-of:2"]
      })
    ])

    Store.put("prs", %{"1" => %{state: "open", url: "https://example.test/pr/1"}})
    metrics = Measurements.calculate(from, until)
    assert metrics.attempts == 1
    assert metrics.failed_attempts == 1
    assert metrics.accepted == 1
    assert metrics.handoffs == 1
    assert metrics.execution_seconds == 120
    assert metrics.observed_human_wait_seconds == 100
    assert metrics.accepted_pr_ci_seconds == 60
    assert metrics.reopens_observed == 1
    assert length(metrics.attention) == 1
    assert length(metrics.confirmed_regressions) == 1
    assert metrics.total_cost_range == nil
    assert metrics.coverage.complete_week
    Store.event("gap", "collection_gap", %{}, nil, DateTime.add(from, 100))
    refute Measurements.calculate(from, until).coverage.complete_week
  end

  test "missing finish and missing collection coverage remain unknown" do
    from = ~U[2026-11-02 00:00:00Z]
    Store.event("start", "start", %{session: "missing", phase: "audit"}, nil, DateTime.add(from, 60))
    metrics = Measurements.calculate(from, ~U[2026-11-09 00:00:00Z])
    assert metrics.incomplete_attempts == 1
    assert metrics.audit_attempts == 1
    refute metrics.coverage.complete_week
    assert metrics.observed_human_wait_seconds == nil
    Store.put("collection_started_at", "2026-11-01T00:00:00Z")
    refute Measurements.calculate(from, ~U[2026-11-09 00:00:00Z]).coverage.complete_week
  end

  test "orphan observations stay incomplete while fully observed accepted work has a configured cost" do
    alias SymphonyElixir.Management.Settings
    from = ~U[2026-11-02 00:00:00Z]
    until = ~U[2026-11-09 00:00:00Z]
    Settings.save(%{"rate_card" => %{"version" => "v1", "models" => %{"m" => %{"input" => 1, "output" => 1, "cached_input" => 1}}}})
    Store.put("collection_started_at", "2026-11-01T00:00:00Z")
    Store.put("collector_at", "2026-11-09T00:00:00Z")
    Store.event("start", "start", %{session: "s", model: "m"}, 1, DateTime.add(from, 1))
    Store.event("finish", "finish", %{session: "s", returncode: 0}, 1, DateTime.add(from, 5))
    UsageHistory.record(%{id: "u", session: "s", model: "m", at: DateTime.add(from, 4), usage: %{input: 1_000_000, output: 0, cached: 0}})
    Store.event("accepted", "accepted", %{}, 1, DateTime.add(from, 6))
    assert Measurements.calculate(from, until).cost_per_accepted == [1.0, 1.0]
    Store.event("orphan", "turn", %{session: "orphan", status: "failed"}, 2, DateTime.add(from, 2))
    assert Measurements.calculate(from, until).incomplete_attempts == 1
  end
end
