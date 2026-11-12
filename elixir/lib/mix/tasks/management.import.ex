defmodule Mix.Tasks.Management.Import do
  @moduledoc "Validate or import stopped legacy state into a separate native state directory."
  use Mix.Task
  alias SymphonyElixir.Management.{Import, Repo, Schema, Settings}
  @shortdoc "Import legacy Symphony management state"

  @impl true
  def run(args) do
    {opts, _, invalid} = OptionParser.parse(args, strict: [database: :string, config: :string, telemetry: :string, state_dir: :string, check: :boolean])
    if invalid != [] or is_nil(opts[:database]), do: Mix.raise("Use --database PATH [--config PATH] [--telemetry PATH] [--state-dir PATH] [--check]")
    Application.ensure_all_started(:ecto_sqlite3)
    if opts[:check], do: check(opts), else: perform_import(opts)
  end

  defp check(opts) do
    case Import.validate(opts[:database]) do
      {:ok, counts} -> Mix.shell().info("Legacy database validated: " <> inspect(counts))
      _ -> Mix.raise("Legacy database validation failed")
    end
  end

  defp perform_import(opts) do
    if is_nil(opts[:state_dir]), do: Mix.raise("An explicit separate --state-dir is required")
    Application.put_env(:symphony_elixir, :management_state_dir, Path.expand(opts[:state_dir]))
    {:ok, repo} = Repo.start_link()

    try do
      Schema.migrate()
      finish(Import.run(opts[:database]), opts)
    after
      GenServer.stop(repo)
    end
  end

  defp finish({:ok, counts}, opts) do
    finish_configuration(opts)
    Mix.shell().info("Legacy database imported: " <> inspect(counts))
  end

  defp finish({:error, :already_imported}, opts) do
    finish_configuration(opts)
    Mix.shell().info("Already imported; database records preserved")
  end

  defp finish(_, _opts), do: Mix.raise("Import failed; original state preserved")

  defp finish_configuration(opts) do
    if opts[:telemetry], do: Import.telemetry(opts[:telemetry])
    policy_path = Path.join(opts[:state_dir], "policy.json")

    if not is_nil(opts[:config]) and not File.exists?(policy_path) do
      config = Jason.decode!(File.read!(opts[:config]))
      Settings.atomic_write(policy_path, Jason.encode!(config))
    end
  end
end
