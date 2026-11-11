defmodule SymphonyElixir.Management.Measurements do
  @moduledoc "Evidence-based weekly outcomes with explicit incomplete coverage."
  alias SymphonyElixir.Management.{Settings, Store, UsageHistory}

  @spec calculate(DateTime.t(), DateTime.t()) :: map()
  def calculate(from, until) do
    config = Settings.config()
    usage = UsageHistory.summary(from, until)

    events =
      Store.rows("SELECT * FROM events WHERE julianday(at)<julianday(?) ORDER BY julianday(at),id", [
        DateTime.to_iso8601(until)
      ])

    within = Enum.filter(events, &(DateTime.compare(parse(&1["at"]), from) != :lt))

    sessions =
      events
      |> Enum.filter(&(&1["kind"] in ~w(start thread startup_failure turn finish)))
      |> Enum.group_by(&Jason.decode!(&1["data"])["session"])
      |> Map.delete(nil)

    observed = Enum.map(sessions, fn {id, rows} -> session(id, rows, from, until) end) |> Enum.reject(&is_nil/1)
    durations = observed |> Enum.map(& &1.seconds) |> Enum.reject(&is_nil/1) |> Enum.sort()
    accepted = Enum.filter(within, &(&1["kind"] == "accepted"))
    issues = Store.rows("SELECT data FROM issues") |> Enum.map(&Jason.decode!(&1["data"]))
    first = Store.get("collection_started_at")
    last = Store.get("collector_at")
    complete = complete?(first, last, from, until, within)
    cost = usage.estimated_cost
    known_cost = not cost.incomplete and Enum.all?(observed, & &1.complete)
    range = if known_cost, do: [cost.minimum, cost.maximum], else: nil
    attempted = observed |> Enum.map(& &1.issue) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    %{
      start: DateTime.to_iso8601(from),
      end: DateTime.to_iso8601(until),
      input_tokens: usage.input,
      output_tokens: usage.output,
      cached_input_tokens: usage.cached,
      attempted_issues: length(attempted),
      attempts: length(observed),
      failed_attempts: Enum.count(observed, & &1.failed),
      incomplete_attempts: max(usage.incomplete_sessions, Enum.count(observed, &(not &1.complete))),
      audit_attempts: Enum.count(observed, &(&1.phase == "audit")),
      accepted: length(accepted),
      handoffs: Enum.count(within, &(&1["kind"] == "handoff")),
      reopens_observed: Enum.count(within, &(&1["kind"] == "reopened")),
      execution_seconds: Enum.sum(durations),
      median_attempt_seconds: percentile(durations, 0.5),
      p90_attempt_seconds: percentile(durations, 0.9),
      observed_human_wait_seconds: waiting(events, accepted),
      accepted_pr_ci_seconds: ci_seconds(accepted),
      cost_range: range,
      total_cost_range: if(complete, do: range),
      cost_per_accepted: cost_per_acceptance(complete, range, accepted),
      coverage: %{complete_week: complete, first_collection: first, last_collection: last},
      billing_basis: config["billing_basis"] || "subscription usage proxy; not an actual invoice",
      rate_card_version: cost.rate_card_version,
      repair_proxy: max(0, length(observed) - length(attempted)),
      groups:
        Enum.group_by(observed, &(&1.model || "unknown"))
        |> Map.new(fn {model, rows} ->
          {model,
           %{
             attempts: length(rows),
             execution_seconds: Enum.sum(Enum.map(rows, &(&1.seconds || 0))),
             failed_attempts: Enum.count(rows, & &1.failed)
           }}
        end),
      attention: Enum.filter(issues, &attention?(&1, config)),
      confirmed_regressions: Enum.filter(issues, &regression?(&1, config)),
      waiting_prs: Store.get("prs", %{}) |> Map.values() |> Enum.filter(&(&1["state"] == "open")),
      evidence: Store.get("prs", %{}) |> Map.values() |> Enum.map(& &1["url"])
    }
  end

  defp session(_id, rows, from, until) do
    start = Enum.find(rows, &(&1["kind"] == "start"))
    finish = Enum.find(rows, &(&1["kind"] == "finish"))

    if overlaps?(start, finish, from, until) do
      data = Jason.decode!(start["data"])
      final = if finish, do: Jason.decode!(finish["data"]), else: %{}
      left = max(DateTime.to_unix(parse(start["at"])), DateTime.to_unix(from))
      ended_at = if finish, do: parse(finish["at"]), else: DateTime.utc_now()
      right = min(DateTime.to_unix(ended_at), DateTime.to_unix(until))

      %{
        issue: start["issue"] || Enum.find_value(rows, & &1["issue"]),
        model: Enum.find_value(Enum.reverse(rows), &Jason.decode!(&1["data"])["model"]) || data["model"],
        phase: data["phase"],
        seconds: if(finish && is_nil(final["end_kind"]), do: max(0, right - left)),
        complete: complete_session?(finish, final),
        failed:
          final["returncode"] not in [nil, 0] or
            Enum.any?(rows, &(Jason.decode!(&1["data"])["status"] in ~w(failed interrupted)))
      }
    end
  end

  defp overlaps?(nil, _finish, _from, _until), do: false

  defp overlaps?(start, finish, from, until) do
    DateTime.compare(parse(start["at"]), until) == :lt and
      (is_nil(finish) or DateTime.compare(parse(finish["at"]), from) != :lt)
  end

  defp complete_session?(finish, final) do
    not is_nil(finish) and final["usage_missing"] != true and final["observation_gap"] != true and
      (final["dropped"] || 0) == 0
  end

  defp cost_per_acceptance(true, range, [_ | _] = accepted) when is_list(range),
    do: Enum.map(range, &(&1 / length(accepted)))

  defp cost_per_acceptance(_, _, _), do: nil

  defp complete?(nil, _last, _from, _until, _events), do: false
  defp complete?(_first, nil, _from, _until, _events), do: false

  defp complete?(first, last, from, until, events) do
    DateTime.compare(parse(first), from) != :gt and DateTime.compare(parse(last), until) != :lt and
      not Enum.any?(events, &(&1["kind"] == "collection_gap"))
  end

  defp percentile([], _), do: nil
  defp percentile(values, fraction), do: Enum.at(values, max(0, ceil(length(values) * fraction) - 1))
  defp parse(value), do: value |> DateTime.from_iso8601() |> elem(1)

  defp waiting(events, accepted) do
    values =
      Enum.map(accepted, fn event ->
        case events
             |> Enum.filter(
               &(&1["kind"] == "handoff" and &1["issue"] == event["issue"] and
                   DateTime.compare(parse(&1["at"]), parse(event["at"])) != :gt)
             )
             |> List.last() do
          nil -> nil
          handoff -> DateTime.diff(parse(event["at"]), parse(handoff["at"]))
        end
      end)
      |> Enum.reject(&is_nil/1)

    if values != [], do: Enum.sum(values)
  end

  defp ci_seconds(accepted) do
    values =
      Enum.map(accepted, fn row ->
        checks = Jason.decode!(row["data"])["checks"] || %{}

        if checks["started_at"] && checks["completed_at"],
          do: DateTime.diff(parse(checks["completed_at"]), parse(checks["started_at"]))
      end)
      |> Enum.reject(&is_nil/1)

    if values != [], do: Enum.sum(values)
  end

  defp attention?(issue, config) do
    labels = get_in(config, ["workflow", "labels"]) || %{}

    issue["state"] == "open" and
      Enum.any?(
        [labels["review"] || "symphony-review", labels["blocked"] || "symphony-blocked"],
        &(&1 in issue["labels"])
      )
  end

  defp regression?(issue, config) do
    label = get_in(config, ["workflow", "labels", "regression"]) || "symphony-regression"
    prefix = get_in(config, ["workflow", "regression_prefix"]) || "regression-of:"
    label in issue["labels"] and Enum.any?(issue["labels"], &String.starts_with?(&1, prefix))
  end
end
