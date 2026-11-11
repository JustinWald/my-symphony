defmodule SymphonyElixir.Management.StoreTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.Management.{Repo, Store, UsageHistory}

  setup do
    root = Path.join(System.tmp_dir!(), "management-test-#{System.unique_integer([:positive])}")
    Application.put_env(:symphony_elixir, :management_state_dir, root)
    start_supervised!(SymphonyElixir.Management.Supervisor)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :management_state_dir)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "migrations, settings and duplicate queue operations persist correctly" do
    :ok = Store.put("key", %{"value" => 1})
    assert Store.get("key") == %{"value" => 1}
    :ok = Store.enqueue("weekly:1", "email", "subject", "body")
    :ok = Store.enqueue("weekly:1", "email", "subject", "body")
    assert [%{"n" => 1}] = Store.rows("SELECT COUNT(*) AS n FROM deliveries")
    assert Repo.aggregate("deliveries", :count, :id) == 1
  end

  test "usage observations are durable and idempotent" do
    at = ~U[2026-11-11 10:00:00Z]
    row = %{id: "usage-1", session: "thread", at: at, usage: %{input: 10, output: 3, cached: nil}}
    :ok = UsageHistory.record(row)
    :ok = UsageHistory.record(row)

    assert %{input: 10, output: 3, cached_unknown: true} =
             UsageHistory.summary(~U[2026-11-11 00:00:00Z], ~U[2026-11-12 00:00:00Z])

    assert [%{"session" => "thread"}] = UsageHistory.sessions(~U[2026-11-11 00:00:00Z], ~U[2026-11-12 00:00:00Z], 1)
  end

  test "rate changes preserve historical prices without double-counting cumulative counters" do
    alias SymphonyElixir.Management.Settings

    Settings.save(%{
      "rate_card" => %{"version" => "v1", "models" => %{"model" => %{"input" => 1, "output" => 1, "cached_input" => 1}}}
    })

    UsageHistory.record(%{
      id: "price-1",
      session: "thread",
      model: "model",
      at: ~U[2026-11-11 10:00:00Z],
      usage: %{input: 1_000_000, output: 0, cached: 0}
    })

    Settings.save(%{
      "rate_card" => %{"version" => "v2", "models" => %{"model" => %{"input" => 2, "output" => 1, "cached_input" => 1}}}
    })

    UsageHistory.record(%{
      id: "price-2",
      session: "thread",
      model: "model",
      at: ~U[2026-11-11 11:00:00Z],
      usage: %{input: 2_000_000, output: 0, cached: 0}
    })

    Store.event("priced:start", "start", %{session: "thread", model: "model"}, nil, ~U[2026-11-11 09:59:00Z])

    Store.event(
      "priced:finish",
      "finish",
      %{session: "thread", model: "model", usage_missing: false, returncode: 0},
      nil,
      ~U[2026-11-11 11:01:00Z]
    )

    cost = UsageHistory.summary(~U[2026-11-11 00:00:00Z], ~U[2026-11-12 00:00:00Z]).estimated_cost
    assert cost.minimum == 3.0
    assert cost.maximum == 3.0
    refute cost.incomplete
    assert cost.rate_card_version == "v1, v2"
  end

  test "repository operations and lease ownership remain compatible" do
    assert :ok = Repo.disconnect_all(0)
    assert Store.rows("SELECT 1 AS n") == [%{"n" => 1}]
    assert Repo.default_options(:all) == []
    assert {:ok, :committed} = Repo.transact(fn -> {:ok, :committed} end)
    assert Repo.prepare_query(:all, :synthetic, []) == {:synthetic, []}
    assert Repo.prepare_transaction(:synthetic, []) == {:synthetic, []}
  end
end
