defmodule SymphonyElixir.Management.ImportTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.Management.{Import, Repo, Schema, Store}

  test "database import preserves delivery status and usage and refuses a second import" do
    root = Path.join(System.tmp_dir!(), "symphony-import-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    Application.put_env(:symphony_elixir, :management_state_dir, Path.join(root, "source"))
    {:ok, repo} = Repo.start_link()
    Schema.migrate()
    :ok = Store.enqueue("weekly:old", "email", "subject", "body")
    Store.query!("UPDATE deliveries SET status='accepted',attempts=2")

    Store.event(
      "old:1",
      "usage",
      %{"session" => "old", "input_tokens" => 100, "output_tokens" => 10},
      1,
      ~U[2026-11-11 00:00:00Z]
    )

    GenServer.stop(repo)
    Application.put_env(:symphony_elixir, :management_state_dir, Path.join(root, "destination"))
    {:ok, repo} = Repo.start_link()

    try do
      Schema.migrate()
      source = Path.join(root, "source/management.sqlite3")
      assert {:ok, %{"deliveries" => 1}} = Import.validate(source)
      assert {:ok, %{"deliveries" => 1}} = Import.run(source)
      assert [%{"status" => "accepted", "attempts" => 2}] = Store.rows("SELECT status,attempts FROM deliveries")
      assert [%{"input" => 100}] = Store.rows("SELECT input FROM usage_observations")
      assert {:error, :already_imported} = Import.run(source)
      telemetry = Path.join(root, "telemetry")
      File.mkdir_p!(telemetry)

      line =
        Jason.encode!(%{
          id: "late:1",
          kind: "usage",
          at: "2026-11-11T01:00:00Z",
          session: "late",
          issue: 2,
          data: %{input_tokens: 20, output_tokens: 5, prompt: "DO-NOT-IMPORT"}
        })

      path = Path.join(telemetry, "late.jsonl")
      File.write!(path, line)
      assert :ok = Import.telemetry(telemetry)
      assert Store.rows("SELECT id FROM events WHERE id='late:1'") == []
      File.write!(path, "\nmalformed\n", [:append])
      Import.telemetry(telemetry)
      Import.telemetry(telemetry)
      assert [%{"input" => 20}] = Store.rows("SELECT input FROM usage_observations WHERE session='late'")
      refute inspect(Store.rows("SELECT data FROM events WHERE id='late:1'")) =~ "DO-NOT-IMPORT"
      assert Store.get("telemetry_warning") =~ "Malformed"
      File.write!(path, String.duplicate("x", 32_769) <> "\n", [:append])
      Import.telemetry(telemetry)
      assert Store.get("telemetry_warning") =~ "Oversized"
    after
      GenServer.stop(repo)
      Application.delete_env(:symphony_elixir, :management_state_dir)
      File.rm_rf!(root)
    end
  end
end
