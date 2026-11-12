defmodule SymphonyElixir.Management.Health do
  @moduledoc "Allowlisted native health and progress-aware repeated-failure notifications."
  alias SymphonyElixir.Management.Store
  alias SymphonyElixir.Orchestrator

  @spec current(GenServer.server()) :: map()
  def current(server \\ Orchestrator) do
    base = %{checked_at: DateTime.to_iso8601(DateTime.utc_now()), api: "unavailable"}

    case Orchestrator.snapshot(server, 1_000) do
      %{} = snapshot ->
        retries =
          Enum.map(snapshot.retrying, fn row ->
            %{
              issue_id: row.issue_id,
              identifier: row.identifier,
              attempt: row.attempt,
              has_error: row.error not in [nil, "", false]
            }
          end)

        Map.merge(base, %{
          api: "responding",
          counts: %{
            running: length(snapshot.running),
            retrying: length(retries),
            blocked: length(snapshot[:blocked] || [])
          },
          retrying: retries
        })

      _ ->
        base
    end
  end

  @spec observe(map()) :: :ok
  def observe(health) do
    Store.put("runtime", health)
    Enum.each(health[:retrying] || [], &retry_notice/1)
    :ok
  end

  defp retry_notice(%{attempt: attempt, has_error: true} = entry) when attempt >= 3 do
    case Regex.run(~r/(\d+)\z/, entry.identifier || "") do
      [_, number] -> notify_issue(entry, String.to_integer(number))
      _ -> :ok
    end
  end

  defp retry_notice(_), do: :ok

  defp notify_issue(entry, number) do
    case Store.rows("SELECT data FROM issues WHERE number=?", [number]) do
      [row] ->
        issue = Jason.decode!(row["data"])

        progress =
          hd(
            Store.rows(
              "SELECT MAX(at) AS at FROM events WHERE issue=? AND kind='turn' AND json_extract(data,'$.status')='completed'",
              [number]
            )
          )["at"]

        episode = Store.get("eligibility_episode:#{number}")
        key = "repeated-failure:" <> to_string(entry.issue_id) <> ":" <> identity(episode) <> ":" <> identity(progress)

        body =
          issue["title"] <>
            "\n" <> issue["url"] <> "\nAt least three failed attempts; inspect issue state and preserved host work."

        Enum.each(~w(slack email), &Store.enqueue(key, &1, "Symphony — repeated failures — ##{number}", body))
        Store.event(key, "repeated_failure", %{attempt: entry.attempt}, number, DateTime.utc_now())

      [] ->
        :ok
    end
  end

  defp identity(nil), do: "None"
  defp identity(value), do: to_string(value)
end
