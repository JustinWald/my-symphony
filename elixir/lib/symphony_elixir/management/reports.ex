defmodule SymphonyElixir.Management.Reports do
  @moduledoc "Weekly heartbeat independent of collection, audits and provider health."
  alias SymphonyElixir.Management.{GitHub, Health, Measurements, Repo, Settings, Store}

  @spec weekly(DateTime.t(), keyword()) :: :ok
  def weekly(now \\ DateTime.utc_now(), opts \\ []) do
    start =
      now
      |> DateTime.to_date()
      |> then(&Date.add(&1, -6 - Date.day_of_week(&1)))
      |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    week = Date.to_iso8601(DateTime.to_date(start))
    config = Settings.config()
    metrics = Measurements.calculate(start, DateTime.add(start, 7, :day))
    body = render(week, metrics)

    Repo.transaction(fn ->
      case Store.rows("SELECT notified FROM reports WHERE week=?", [week]) do
        [%{"notified" => value}] when is_binary(value) -> :ok
        _ -> write_report(week, body, metrics, config, now, Keyword.get(opts, :notify, true))
      end
    end)

    :ok
  end

  defp write_report(week, body, metrics, config, now, notify) do
    Store.query!(
      "INSERT INTO reports(week,body,metrics) VALUES(?,?,?) ON CONFLICT(week) DO UPDATE SET body=excluded.body,metrics=excluded.metrics",
      [week, body, Jason.encode!(metrics)]
    )

    if notify == true and get_in(config, ["weekly", "enabled"]) != false do
      audit = hd(Store.rows("SELECT audit FROM reports WHERE week=?", [week]))["audit"]
      notification = body <> if(is_binary(audit), do: "\n\n" <> audit, else: "")

      Enum.each(
        ~w(email slack),
        &Store.enqueue("weekly:" <> week, &1, "Symphony weekly heartbeat — " <> week, notification)
      )

      Store.query!("UPDATE reports SET notified=? WHERE week=?", [DateTime.to_iso8601(now), week])
    end
  end

  @spec preview(DateTime.t()) :: String.t()
  def preview(now \\ DateTime.utc_now()) do
    start =
      now
      |> DateTime.to_date()
      |> then(&Date.add(&1, -6 - Date.day_of_week(&1)))
      |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    week = Date.to_iso8601(DateTime.to_date(start))
    render(week, Measurements.calculate(start, DateTime.add(start, 7, :day)))
  end

  @spec render(String.t(), map()) :: String.t()
  def render(week, metrics) do
    health = Store.get("github_health", %{"status" => "never observed"})
    runtime = Health.current()

    overview = "Symphony weekly heartbeat — #{week}\n\nRuntime: #{runtime.api}\nTracker: #{health["status"]}"

    values =
      Enum.map_join(
        ~w(attempted_issues attempts failed_attempts incomplete_attempts audit_attempts accepted handoffs reopens_observed execution_seconds median_attempt_seconds p90_attempt_seconds observed_human_wait_seconds accepted_pr_ci_seconds input_tokens output_tokens cached_input_tokens repair_proxy)a,
        "\n",
        fn key ->
          "#{String.replace(to_string(key), "_", " ")}: #{display(metrics[key])}"
        end
      )

    coverage = if metrics.coverage.complete_week, do: "Complete collection window", else: "Incomplete collection window"
    evidence = Enum.map_join(metrics.evidence, "\n", &to_string/1)
    attention = Enum.map_join(metrics.attention, "\n", &"##{&1["number"]} #{&1["title"] || ""} #{&1["url"] || ""}")

    overview <>
      "\n\n" <>
      values <>
      "\n\n" <>
      coverage <>
      "\nCost range: #{display(metrics.total_cost_range)}; cost per accepted PR: #{display(metrics.cost_per_accepted)}." <>
      "\nRate card: #{metrics.rate_card_version}. Billing basis: subscription usage proxy; not an actual invoice." <>
      "\nMissing observations and model rates mean cost is unknown. Repair count is a proxy, not confirmed rework." <>
      "\n\nNeeds attention:\n" <> attention <> "\n\nPR evidence:\n" <> evidence
  end

  defp display(nil), do: "Unknown"
  defp display(value), do: inspect(value)

  @spec publish() :: :ok
  def publish do
    config = Settings.config()

    if config["publish_enabled"] == true do
      Enum.each(Store.rows("SELECT * FROM reports ORDER BY week DESC LIMIT 4"), &publish_report(config, &1))
    end

    :ok
  end

  defp publish_report(config, row) do
    body = row["body"] <> "\n\n" <> (row["audit"] || "") <> "\n\n" <> marker(row)
    version = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    if row["published"] != version, do: save_publication(upsert_issue(config, row, body), row, version)
  end

  defp save_publication({:ok, %{"html_url" => url}}, row, version) when is_binary(url) do
    Store.query!("UPDATE reports SET url=?,published=? WHERE week=?", [url, version, row["week"]])
  end

  defp save_publication(_, _row, _version), do: Store.put("publication_health", "unavailable; will retry")

  defp upsert_issue(config, %{"url" => url}, body) when is_binary(url) do
    GitHub.call(config, "/issues/" <> List.last(String.split(url, "/")), method: :patch, json: %{body: body})
  end

  defp upsert_issue(config, row, body) do
    label = get_in(config, ["workflow", "labels", "audit"]) || "symphony-audit"

    with {:ok, issues} <- GitHub.pages(config, "/issues?state=all&labels=" <> URI.encode_www_form(label)) do
      case Enum.find(issues, &String.contains?(&1["body"] || "", marker(row))) do
        nil ->
          GitHub.call(config, "/issues",
            method: :post,
            json: %{title: "Symphony weekly audit — " <> row["week"], body: body, labels: [label]}
          )

        issue ->
          GitHub.call(config, "/issues/#{issue["number"]}", method: :patch, json: %{body: body})
      end
    end
  end

  defp marker(row), do: "<!-- symphony-weekly:" <> row["week"] <> " -->"
end
