defmodule SymphonyElixir.Management.Import do
  @moduledoc "Explicit import into an empty native store. Never opens legacy state for writing."
  alias SymphonyElixir.Management.{Repo, Store, UsageHistory}
  @tables ~w(kv events issues reports deliveries proposals)

  @spec validate(Path.t()) :: {:ok, map()} | {:error, term()}
  def validate(source) do
    if File.regular?(source) do
      # A dedicated read-only connection avoids modifying journal mode or creating state.
      with {:ok, db} <- Exqlite.Sqlite3.open(source, mode: :readonly) do
        try do
          counts = Map.new(@tables, fn table -> {table, count(db, table)} end)
          {:ok, counts}
        after
          Exqlite.Sqlite3.close(db)
        end
      end
    else
      {:error, :source_missing}
    end
  end

  @spec run(Path.t()) :: {:ok, map()} | {:error, term()}
  def run(source) do
    with {:ok, counts} <- validate(source) do
      # Read from a standalone read-only connection, then commit the entire import
      # transaction. Operators must stop legacy writers and use a backup snapshot.
      {:ok, db} = Exqlite.Sqlite3.open(source, mode: :readonly)

      try do
        Store.transaction(fn ->
          already = Store.rows("SELECT counts FROM imports WHERE source=?", [Path.expand(source)])
          if already != [], do: Repo.rollback(:already_imported)

          if Enum.any?(@tables, &(Store.rows("SELECT COUNT(*) AS n FROM " <> &1) != [%{"n" => 0}])),
            do: Repo.rollback(:destination_not_empty)

          Enum.each(@tables, fn table ->
            {:ok, statement} = Exqlite.Sqlite3.prepare(db, "SELECT * FROM " <> table)

            try do
              {:ok, columns} = Exqlite.Sqlite3.columns(db, statement)
              import_rows(db, statement, table, columns)
            after
              Exqlite.Sqlite3.release(db, statement)
            end
          end)

          import_usage()

          Store.query!("INSERT INTO imports(source,imported_at,counts) VALUES(?,?,?)", [
            Path.expand(source),
            DateTime.to_iso8601(DateTime.utc_now()),
            Jason.encode!(counts)
          ])

          counts
        end)
      after
        Exqlite.Sqlite3.close(db)
      end
    end
  end

  @spec import_usage() :: :ok
  def import_usage do
    Store.rows("SELECT id,at,issue,data FROM events WHERE kind IN ('usage','finish') ORDER BY at,id")
    |> Enum.each(fn row ->
      data = Jason.decode!(row["data"])

      with session when is_binary(session) <- data["session"],
           input when is_integer(input) and input >= 0 <- data["input_tokens"],
           output when is_integer(output) and output >= 0 <- data["output_tokens"],
           {:ok, at, _} <- DateTime.from_iso8601(row["at"]) do
        UsageHistory.record(%{
          id: row["id"],
          session: session,
          at: at,
          issue: if(row["issue"], do: to_string(row["issue"])),
          model: data["model"],
          effort: data["effort"],
          usage: %{input: input, output: output, cached: data["cached_input_tokens"]}
        })
      else
        _ -> :ok
      end
    end)

    :ok
  end

  @spec telemetry(Path.t()) :: :ok
  def telemetry(directory) do
    Path.wildcard(Path.join(directory, "*.jsonl"))
    |> Enum.each(fn path ->
      key = "offset:" <> Path.basename(path)
      {:ok, file} = File.open(path, [:read, :binary])

      try do
        Store.transaction(fn ->
          {:ok, _} = :file.position(file, Store.get(key, 0))
          consume_telemetry(file)
          {:ok, offset} = :file.position(file, :cur)
          Store.put(key, offset)
          import_usage()
        end)
      after
        File.close(file)
      end
    end)

    :ok
  end

  defp consume_telemetry(file) do
    {:ok, offset} = :file.position(file, :cur)

    case IO.binread(file, :line) do
      :eof ->
        :ok

      line ->
        if String.ends_with?(line, "\n") do
          ingest_line(line)
          consume_telemetry(file)
        else
          :file.position(file, offset)
          :ok
        end
    end
  end

  defp ingest_line(line) when byte_size(line) <= 32_768 do
    with {:ok, event} <- Jason.decode(line),
         kind when kind in ~w(start thread usage turn finish) <- event["kind"],
         id when is_binary(id) <- event["id"],
         session when is_binary(session) <- event["session"],
         data when is_map(data) <- event["data"],
         {:ok, at, _} <- DateTime.from_iso8601(event["at"] || "") do
      allowed =
        Map.take(
          data,
          ~w(thread model effort revision workflow bridge input_tokens output_tokens cached_input_tokens seconds returncode dropped completed_turns failed_turns usage_missing status)
        )
        |> Map.put("session", session)

      Store.event(id, kind, allowed, event["issue"], at)
    else
      _ -> Store.put("telemetry_warning", "Malformed metadata record; history incomplete")
    end
  end

  defp ingest_line(_), do: Store.put("telemetry_warning", "Oversized metadata record; history incomplete")

  defp count(db, table) do
    {:ok, statement} = Exqlite.Sqlite3.prepare(db, "SELECT COUNT(*) FROM " <> table)

    try do
      {:row, [count]} = Exqlite.Sqlite3.step(db, statement)
      count
    after
      Exqlite.Sqlite3.release(db, statement)
    end
  end

  defp import_rows(db, statement, table, columns) do
    case Exqlite.Sqlite3.step(db, statement) do
      :done ->
        :ok

      row ->
        {:row, values} = row
        placeholders = Enum.map_join(columns, ",", fn _ -> "?" end)
        Store.query!("INSERT INTO " <> table <> " VALUES(" <> placeholders <> ")", values)
        import_rows(db, statement, table, columns)
    end
  end
end
