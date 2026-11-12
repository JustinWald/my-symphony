defmodule SymphonyElixir.Management.Store do
  @moduledoc "Transactional management storage; all values use bound SQL parameters."
  alias Ecto.Adapters.SQL
  alias SymphonyElixir.Management.Repo

  @spec query!(String.t(), list()) :: map()
  def query!(sql, params \\ []), do: SQL.query!(repo(), sql, params, log: false)

  @spec repo() :: pid() | atom()
  def repo do
    case SymphonyElixir.Project.current() do
      nil ->
        Repo

      project ->
        SymphonyElixir.Project.whereis(SymphonyElixir.Project.name(Repo, project)) ||
          raise "Project storage unavailable: #{project.id}"
    end
  end

  @spec transaction((-> term())) :: {:ok, term()} | {:error, term()}
  def transaction(fun) do
    previous = Repo.put_dynamic_repo(repo())

    try do
      Repo.transaction(fun)
    after
      Repo.put_dynamic_repo(previous)
    end
  end

  @spec get(String.t(), term()) :: term()
  def get(key, default \\ nil) do
    case query!("SELECT value FROM kv WHERE key=?", [key]).rows do
      [[value]] -> Jason.decode!(value)
      [] -> default
    end
  end

  @spec put(String.t(), term()) :: :ok
  def put(key, value) do
    query!("INSERT INTO kv(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [
      key,
      Jason.encode!(value)
    ])

    :ok
  end

  @spec enqueue(String.t(), String.t(), String.t(), String.t()) :: :ok
  def enqueue(id, channel, subject, body) when channel in ["slack", "email"] do
    query!("INSERT OR IGNORE INTO deliveries(id,channel,subject,body) VALUES(?,?,?,?)", [
      id <> ":" <> channel,
      channel,
      subject,
      body
    ])

    :ok
  end

  @spec event(String.t(), String.t(), map(), term(), DateTime.t()) :: :ok
  def event(id, kind, data, issue, at) do
    query!("INSERT OR IGNORE INTO events(id,at,kind,issue,data) VALUES(?,?,?,?,?)", [
      id,
      DateTime.to_iso8601(at),
      kind,
      issue,
      Jason.encode!(data)
    ])

    :ok
  end

  @spec claim_job(String.t(), pos_integer()) :: {:ok, String.t()} | :busy
  def claim_job(name, ttl) do
    {:ok, result} =
      transaction(fn ->
        key = "native_job:" <> name
        now = System.system_time(:second)

        if lease_active?(get(key), now) do
          :busy
        else
          token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
          put(key, %{token: token, expires: now + ttl})
          {:ok, token}
        end
      end)

    result
  end

  @spec release_job(String.t(), String.t()) :: :ok
  def release_job(name, token) do
    transaction(fn ->
      key = "native_job:" <> name

      case get(key) do
        %{"token" => ^token} -> put(key, %{})
        _ -> :ok
      end
    end)

    :ok
  end

  defp lease_active?(%{"expires" => expires}, now) when is_integer(expires), do: expires > now
  defp lease_active?(_, _), do: false

  @spec rows(String.t(), list()) :: [map()]
  def rows(sql, params \\ []) do
    %{columns: columns, rows: rows} = query!(sql, params)
    Enum.map(rows, &Map.new(Enum.zip(columns, &1)))
  end
end
