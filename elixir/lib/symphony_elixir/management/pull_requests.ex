defmodule SymphonyElixir.Management.PullRequests do
  @moduledoc "PR handoffs and acceptance require repository, branch and exact-head CI evidence."
  alias SymphonyElixir.Management.{GitHub, Store}

  @spec collect(map()) :: :ok | {:error, term()}
  def collect(config) do
    case GitHub.pages(config, "/pulls?state=all&sort=updated&direction=desc") do
      {:ok, prs} -> collect_rows(config, prs)
      error -> {:error, error}
    end
  end

  defp collect_rows(config, prs) do
    pattern = get_in(config, ["workflow", "branch_pattern"]) || "symphony/issue-(?P<issue>\\d+)"
    regex = Regex.compile!("\\A(?:" <> pattern <> ")\\z")
    Enum.each(prs, &observe(config, regex, &1))
    :ok
  end

  @spec checks_pass?(map(), map(), map(), map(), String.t()) :: boolean()
  def checks_pass?(policy, checks, statuses, workflows, sha) do
    names = policy["required_checks"] || []
    required_workflows = policy["required_workflows"] || []
    configured = configured?(names, required_workflows)
    bounded = bounded?(checks, workflows)

    configured and bounded and statuses_pass?(statuses) and
      Enum.all?(names, &named_check_pass?(checks, &1, sha, policy["check_app"] || "github-actions")) and
      Enum.all?(required_workflows, &workflow_pass?(workflows, &1, sha))
  end

  defp configured?(names, workflows), do: names != [] or workflows != []
  defp bounded?(checks, workflows), do: (checks["total_count"] || 0) <= 100 and (workflows["total_count"] || 0) <= 100

  defp named_check_pass?(checks, name, sha, app) do
    matching =
      Enum.filter(checks["check_runs"] || [], fn check ->
        check["name"] == name and check["head_sha"] == sha and get_in(check, ["app", "slug"]) == app
      end)

    matching != [] and Enum.all?(matching, &successful?/1)
  end

  defp successful?(check), do: check["status"] == "completed" and check["conclusion"] == "success"
  defp statuses_pass?(statuses), do: (statuses["statuses"] || []) == [] or statuses["state"] == "success"

  defp workflow_pass?(workflows, name, sha) do
    latest =
      workflows["workflow_runs"]
      |> Enum.filter(&(&1["name"] == name and &1["head_sha"] == sha))
      |> Enum.max_by(&{&1["run_number"], &1["run_attempt"]}, fn -> %{} end)

    latest["status"] == "completed" and latest["conclusion"] == "success"
  end

  defp observe(config, regex, raw) do
    captures = Regex.named_captures(regex, raw["head"]["ref"])

    if captures && get_in(raw, ["head", "repo", "full_name"]) == config["repo"] do
      number = String.to_integer(captures["issue"])
      sha = raw["head"]["sha"]

      checks = fetch_checks(config, sha)
      passed = checks.passed

      pr =
        Map.take(raw, ~w(number state draft merged_at))
        |> Map.merge(%{"issue" => number, "sha" => sha, "url" => raw["html_url"], "checks" => checks})

      Store.put("prs", Map.put(Store.get("prs", %{}), to_string(raw["number"]), pr))

      if passed and raw["merged_at"] do
        {:ok, at, _} = DateTime.from_iso8601(raw["merged_at"])
        Store.event("accepted:#{raw["number"]}", "accepted", pr, number, at)
      end

      handoff(config, raw, number, passed)
    end
  end

  defp fetch_checks(config, sha) do
    with {:ok, checks} <- GitHub.call(config, "/commits/#{sha}/check-runs?per_page=100"),
         {:ok, statuses} <- GitHub.call(config, "/commits/#{sha}/status"),
         {:ok, workflows} <- GitHub.call(config, "/actions/runs?head_sha=#{sha}&per_page=100") do
      policy = config["workflow"] || %{}

      latest =
        (workflows["workflow_runs"] || [])
        |> Enum.filter(&(&1["name"] in (policy["required_workflows"] || []) and &1["head_sha"] == sha))
        |> Enum.max_by(&{&1["run_number"], &1["run_attempt"]}, fn -> %{} end)

      %{
        passed: checks_pass?(policy, checks, statuses, workflows, sha),
        started_at: latest["run_started_at"],
        completed_at: latest["updated_at"],
        workflow_status: latest["status"] || "missing",
        workflow_conclusion: latest["conclusion"]
      }
    else
      _ -> %{passed: false}
    end
  end

  defp handoff(config, raw, number, passed) do
    id = Store.get("pending_handoff:#{number}")
    rows = Store.rows("SELECT data FROM issues WHERE number=?", [number])
    if id && rows != [] && reviewable?(raw), do: maybe_notify(config, raw, number, passed, id, hd(rows))
  end

  defp reviewable?(raw), do: raw["state"] == "open" and raw["draft"] == false

  defp maybe_notify(config, raw, number, passed, id, row) do
    issue = Jason.decode!(row["data"])
    labels = get_in(config, ["workflow", "labels"]) || %{}
    if handed_off?(issue["labels"], labels), do: notify(raw, number, passed, id, issue)
  end

  defp handed_off?(tags, labels) do
    (labels["review"] || "symphony-review") in tags and
      (labels["ready"] || "symphony-ready") not in tags and (labels["working"] || "symphony-working") not in tags
  end

  defp notify(raw, number, passed, id, issue) do
    checks = if passed, do: "Passing", else: "NOT verified passing"

    body =
      issue["title"] <>
        "\n" <> raw["html_url"] <> "\nHead: " <> raw["head"]["sha"] <> "\nRequired validation: " <> checks

    Store.enqueue(id, "slack", "Symphony — ready for review — ##{number}", body)
    Store.put("pending_handoff:#{number}", nil)
  end
end
