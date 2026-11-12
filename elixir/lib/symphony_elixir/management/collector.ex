defmodule SymphonyElixir.Management.Collector do
  @moduledoc "Tracker observations without modifying dispatch eligibility."
  alias SymphonyElixir.Management.{GitHub, Health, PullRequests, Repo, Settings, Store}

  @labels %{
    "ready" => "symphony-ready",
    "working" => "symphony-working",
    "review" => "symphony-review",
    "blocked" => "symphony-blocked",
    "audit" => "symphony-audit"
  }

  @spec collect() :: :ok
  def collect do
    Health.observe(Health.current())
    config = Settings.config()
    now = DateTime.utc_now()
    previous = Store.get("collector_at")
    if is_nil(Store.get("collection_started_at")), do: Store.put("collection_started_at", DateTime.to_iso8601(now))
    record_gap(previous, now)
    labels = Map.merge(@labels, get_in(config, ["workflow", "labels"]) || %{})

    case GitHub.pages(config, "/issues?state=all&sort=updated&direction=desc") do
      {:ok, issues} ->
        Repo.transaction(fn -> Enum.each(issues, &observe(&1, labels, now)) end)
        record_recovery(now)
        Store.put("github_health", %{"at" => DateTime.to_iso8601(now), "status" => "ok"})

      _ ->
        if is_nil(Store.get("github_gap_start")), do: Store.put("github_gap_start", DateTime.to_iso8601(now))

        Store.put("github_health", %{
          "at" => DateTime.to_iso8601(now),
          "status" => "unavailable; last successful observations retained"
        })
    end

    PullRequests.collect(config)
    Store.put("collector_at", DateTime.to_iso8601(now))
    :ok
  end

  defp record_recovery(now) do
    case Store.get("github_gap_start") do
      nil ->
        :ok

      gap ->
        Store.event("github-gap:" <> gap, "collection_gap", %{start: gap, end: DateTime.to_iso8601(now)}, nil, now)
        Store.put("github_gap_start", nil)
    end
  end

  defp record_gap(nil, _now), do: :ok

  defp record_gap(previous, now) do
    {:ok, at, _} = DateTime.from_iso8601(previous)

    if DateTime.diff(now, at) > 180,
      do:
        Store.event(
          "collection-gap:" <> DateTime.to_iso8601(now),
          "collection_gap",
          %{start: previous, end: DateTime.to_iso8601(now)},
          nil,
          now
        )
  end

  defp observe(%{"pull_request" => _}, _labels, _now), do: :ok

  defp observe(raw, labels, now) do
    tags = Enum.map(raw["labels"] || [], &String.downcase(&1["name"]))
    old = previous(raw["number"])

    if labels["audit"] not in tags and (old != %{} or Enum.any?(Map.values(labels), &(&1 in tags))) do
      issue =
        Map.take(raw, ~w(number title state updated_at)) |> Map.put("url", raw["html_url"]) |> Map.put("labels", tags)

      Store.query!("INSERT INTO issues(number,data) VALUES(?,?) ON CONFLICT(number) DO UPDATE SET data=excluded.data", [
        raw["number"],
        Jason.encode!(issue)
      ])

      transitions(raw, old, labels, tags, now)
    end
  end

  defp previous(number) do
    case Store.rows("SELECT data FROM issues WHERE number=?", [number]) do
      [row] -> Jason.decode!(row["data"])
      [] -> %{}
    end
  end

  defp transitions(raw, old, labels, tags, now) do
    if old["state"] == "closed" and raw["state"] == "open" do
      Store.event(
        "reopened:#{raw["number"]}:" <> raw["updated_at"],
        "reopened",
        %{"url" => raw["html_url"]},
        raw["number"],
        now
      )
    end

    if labels["ready"] in tags and labels["ready"] not in (old["labels"] || []) do
      Store.put("eligibility_episode:#{raw["number"]}", raw["updated_at"])
    end

    Enum.each([{labels["blocked"], "blocker"}, {labels["review"], "handoff"}], fn {label, kind} ->
      if newly_applied?(label, tags, old) and raw["state"] == "open", do: notification(raw, kind, now)
    end)
  end

  defp newly_applied?(label, tags, old), do: label in tags and label not in (old["labels"] || [])

  defp notification(raw, kind, now) do
    id = kind <> ":#{raw["number"]}:" <> raw["updated_at"]
    Store.event(id, kind, %{"url" => raw["html_url"]}, raw["number"], now)

    if kind == "handoff" do
      Store.put("pending_handoff:#{raw["number"]}", id)
    else
      body = raw["title"] <> "\n" <> raw["html_url"] <> "\nHuman action needed; read the persisted issue report."
      Enum.each(~w(slack email), &Store.enqueue(id, &1, "Symphony — blocked — ##{raw["number"]}", body))
    end
  end
end
