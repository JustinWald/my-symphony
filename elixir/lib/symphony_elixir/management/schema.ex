defmodule SymphonyElixir.Management.Migrations.CreateManagement do
  @moduledoc false
  use Ecto.Migration

  @spec change() :: term()
  def change do
    # Legacy columns and primary keys are deliberately preserved for lossless import.
    execute("CREATE TABLE kv(key TEXT PRIMARY KEY, value TEXT NOT NULL)", "DROP TABLE kv")

    execute(
      "CREATE TABLE events(id TEXT PRIMARY KEY, at TEXT NOT NULL, kind TEXT NOT NULL, issue INTEGER, data TEXT NOT NULL)",
      "DROP TABLE events"
    )

    execute("CREATE TABLE issues(number INTEGER PRIMARY KEY, data TEXT NOT NULL)", "DROP TABLE issues")

    execute(
      "CREATE TABLE reports(week TEXT PRIMARY KEY, body TEXT NOT NULL, metrics TEXT NOT NULL, audit TEXT, url TEXT, published TEXT, notified TEXT)",
      "DROP TABLE reports"
    )

    execute(
      "CREATE TABLE deliveries(id TEXT PRIMARY KEY, channel TEXT NOT NULL, subject TEXT NOT NULL, body TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending', attempts INTEGER NOT NULL DEFAULT 0, due REAL NOT NULL DEFAULT 0, error TEXT, lease REAL NOT NULL DEFAULT 0)",
      "DROP TABLE deliveries"
    )

    execute(
      "CREATE TABLE proposals(id TEXT PRIMARY KEY, week TEXT NOT NULL, status TEXT NOT NULL, data TEXT NOT NULL, url TEXT)",
      "DROP TABLE proposals"
    )

    execute(
      "CREATE TABLE usage_observations(id TEXT PRIMARY KEY, session TEXT NOT NULL, at TEXT NOT NULL, issue TEXT, model TEXT, effort TEXT, input INTEGER NOT NULL, output INTEGER NOT NULL, cached INTEGER, rate_version TEXT)",
      "DROP TABLE usage_observations"
    )

    execute("CREATE INDEX usage_session_at ON usage_observations(session, at)", "DROP INDEX usage_session_at")
    execute("CREATE INDEX usage_at ON usage_observations(at)", "DROP INDEX usage_at")

    execute(
      "CREATE TABLE imports(source TEXT PRIMARY KEY, imported_at TEXT NOT NULL, counts TEXT NOT NULL)",
      "DROP TABLE imports"
    )
  end
end

defmodule SymphonyElixir.Management.Schema do
  @moduledoc "Compiled migrations work in releases without runtime source files."
  alias SymphonyElixir.Management.{Migrations.CreateManagement, Repo, Store}

  @spec migrate() :: [integer()]
  def migrate do
    previous = Repo.put_dynamic_repo(Store.repo())

    try do
      Ecto.Migrator.run(Repo, [{20_261_111_000_000, CreateManagement}], :up, all: true, log: false)
    after
      Repo.put_dynamic_repo(previous)
    end
  end
end
