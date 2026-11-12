defmodule SymphonyElixir.Management.Repo do
  @moduledoc "Durable local management state, independent of agent workspaces."
  use Ecto.Repo, otp_app: :symphony_elixir, adapter: Ecto.Adapters.SQLite3

  @impl true
  def init(_type, config) do
    directory = Keyword.get(config, :state_dir, SymphonyElixir.Config.management_state_dir())
    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)

    {:ok,
     Keyword.merge(config,
       database: Path.join(directory, "management.sqlite3"),
       pool_size: 1,
       journal_mode: :wal,
       busy_timeout: 5_000
     )}
  end
end
