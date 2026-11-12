defmodule SymphonyElixir.RuntimeCheckpoint do
  @moduledoc "Versioned drain checkpoints contain scheduler data, never live processes or monitors."
  alias SymphonyElixir.Config

  @spec save(map()) :: :ok | {:error, term()}
  def save(state) do
    now = System.monotonic_time(:millisecond)
    wall = System.system_time(:millisecond)

    retries =
      Map.new(state.retry_attempts, fn {id, entry} ->
        {id, entry |> Map.drop([:timer_ref, :retry_token, :due_at_ms]) |> Map.put(:due_system_ms, wall + max(0, entry.due_at_ms - now))}
      end)

    data = Map.take(state, [:completed, :claimed, :blocked, :codex_totals, :codex_rate_limits])
    data = Map.put(data, :retry_attempts, retries)
    path = path()

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path <> ".tmp", :erlang.term_to_binary({1, data}), [:binary, :sync]),
         :ok <- File.chmod(path <> ".tmp", 0o600) do
      File.rename(path <> ".tmp", path)
    end
  end

  @spec restore(map()) :: map()
  def restore(state) do
    case File.read(path()) do
      {:error, :enoent} ->
        state

      {:ok, content} ->
        {1, data} = :erlang.binary_to_term(content, [:safe])

        retries =
          Map.new(data.retry_attempts, fn {id, entry} ->
            delay = max(0, entry.due_system_ms - System.system_time(:millisecond))
            token = make_ref()
            timer = Process.send_after(self(), {:retry_issue, id, token}, delay)
            {id, entry |> Map.delete(:due_system_ms) |> Map.merge(%{retry_token: token, timer_ref: timer, due_at_ms: System.monotonic_time(:millisecond) + delay})}
          end)

        File.rm!(path())
        struct!(state, Map.put(data, :retry_attempts, retries))

      {:error, reason} ->
        raise File.Error, reason: reason, action: "read checkpoint", path: path()
    end
  end

  defp path, do: Path.join(Config.management_state_dir(), "runtime-checkpoint.term")
end
