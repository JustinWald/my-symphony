defmodule SymphonyElixir.Management.UsageHistory do
  @moduledoc "Durable allowlisted usage observations and bounded session queries."
  alias SymphonyElixir.Management.{Settings, Store, Usage}

  @spec record(map()) :: :ok
  def record(row) do
    card = Settings.config()["rate_card"] || %{}
    version = :crypto.hash(:sha256, Jason.encode!(card)) |> Base.encode16(case: :lower)
    Store.put("rate_card:" <> version, card)

    Store.query!(
      "INSERT OR IGNORE INTO usage_observations(id,session,at,issue,model,effort,input,output,cached,rate_version) VALUES(?,?,?,?,?,?,?,?,?,?)",
      [
        row.id,
        row.session,
        DateTime.to_iso8601(row.at),
        row[:issue],
        row[:model],
        row[:effort],
        row.usage.input,
        row.usage.output,
        row.usage.cached,
        version
      ]
    )

    :ok
  end

  @spec summary(DateTime.t(), DateTime.t()) :: map()
  def summary(from, until) do
    # Include baseline observations before the requested window so cumulative
    # counters are not attributed entirely to the first observation inside it.
    Store.rows(
      "SELECT id,session,at,issue,model,input,output,cached FROM usage_observations WHERE julianday(at)<julianday(?) ORDER BY julianday(at),id",
      [DateTime.to_iso8601(until)]
    )
    |> Enum.map(&observation/1)
    |> Usage.summarize(from, until)
    |> enrich(from, until)
  end

  defp observation(row) do
    {:ok, at, _} = DateTime.from_iso8601(row["at"])
    usage = %{input: row["input"], output: row["output"], cached: row["cached"]}
    %{id: row["id"], session: row["session"], at: at, issue: row["issue"], model: row["model"], usage: usage}
  end

  @session_query """
  WITH observations AS (
    SELECT session, MAX(issue) AS issue, MAX(model) AS model, MAX(effort) AS effort,
      MAX(input) AS input_tokens, MAX(output) AS output_tokens, MAX(cached) AS cached_input_tokens,
      MAX(at) AS observed_at
    FROM usage_observations WHERE julianday(at)<julianday(?) GROUP BY session
  ), metadata AS (
    SELECT json_extract(data,'$.session') AS session, MAX(issue) AS issue,
      MAX(json_extract(data,'$.model')) AS model, MAX(json_extract(data,'$.effort')) AS effort,
      MIN(CASE WHEN kind='start' THEN julianday(at) END) AS started,
      MAX(CASE WHEN kind='finish' THEN julianday(at) END) AS finished,
      MAX(COALESCE(json_extract(data,'$.dropped'),0)) AS dropped,
      MAX(COALESCE(json_extract(data,'$.usage_missing'),0)) AS usage_missing,
      MAX(COALESCE(json_extract(data,'$.observation_gap'),0)) AS observation_gap,
      MAX(json_extract(data,'$.end_kind')) AS end_kind,
      MAX(CASE WHEN kind='finish' AND json_extract(data,'$.returncode')!=0 THEN 1 ELSE 0 END) AS finish_failed,
      SUM(CASE WHEN json_extract(data,'$.status') IN ('failed','interrupted') THEN 1 ELSE 0 END) AS failures,
      MAX(at) AS observed_at
    FROM events WHERE julianday(at)<julianday(?) AND json_extract(data,'$.session') IS NOT NULL GROUP BY session
  ), selected AS (
    SELECT session FROM usage_observations WHERE julianday(at)>=julianday(?) AND julianday(at)<julianday(?)
    UNION
    SELECT session FROM metadata WHERE (finished IS NULL OR finished>=julianday(?))
      AND (started IS NOT NULL OR julianday(observed_at)>=julianday(?))
  )
  SELECT s.session, COALESCE(o.issue,m.issue) AS issue, COALESCE(o.model,m.model) AS model,
    COALESCE(o.effort,m.effort) AS effort, COALESCE(o.observed_at,m.observed_at) AS observed_at,
    o.input_tokens, o.output_tokens, o.cached_input_tokens,
    m.started, m.finished, m.dropped, m.usage_missing, m.observation_gap, m.end_kind, MAX(COALESCE(m.failures,0),COALESCE(m.finish_failed,0)) AS failures
  FROM selected s LEFT JOIN observations o ON o.session=s.session LEFT JOIN metadata m ON m.session=s.session
  ORDER BY observed_at DESC,s.session
  """

  @spec sessions(DateTime.t(), DateTime.t(), pos_integer()) :: [map()]
  def sessions(from, until, page) when is_integer(page) and page > 0 do
    session_rows(from, until, " LIMIT 50 OFFSET ?", [(page - 1) * 50])
  end

  defp session_rows(from, until, suffix, extra) do
    left = DateTime.to_iso8601(from)
    right = DateTime.to_iso8601(until)
    Store.rows(@session_query <> suffix, [right, right, left, right, left, left] ++ extra) |> Enum.map(&details/1)
  end

  defp details(row) do
    seconds =
      if row["started"] && row["finished"] && is_nil(row["end_kind"]),
        do: max(0, (row["finished"] - row["started"]) * 86_400),
        else: nil

    incomplete = incomplete?(row)

    row
    |> Map.drop(~w(started finished dropped usage_missing observation_gap end_kind))
    |> Map.put("runtime_seconds", seconds)
    |> Map.put("incomplete", incomplete)
  end

  defp incomplete?(row) do
    Enum.any?(~w(started finished input_tokens), &is_nil(row[&1])) or
      Enum.any?(~w(usage_missing observation_gap), &(row[&1] == 1)) or (row["dropped"] || 0) > 0
  end

  defp enrich(totals, from, until) do
    rows = session_rows(from, until, "", [])
    incomplete = Enum.count(rows, & &1["incomplete"])
    cost = estimate(from, until) |> Map.update!(:incomplete, &(&1 or incomplete > 0))
    totals |> Map.put(:estimated_cost, cost) |> Map.put(:incomplete_sessions, incomplete)
  end

  defp estimate(from, until) do
    rows =
      Store.rows(
        "SELECT session,at,model,input,output,cached,rate_version FROM usage_observations WHERE julianday(at)<julianday(?) ORDER BY julianday(at),id",
        [DateTime.to_iso8601(until)]
      )

    initial = %{minimum: 0.0, maximum: 0.0, incomplete: rows == [], versions: MapSet.new(), sessions: %{}}
    result = Enum.reduce(rows, initial, &cost_observation(&1, &2, from))

    result
    |> Map.drop([:sessions, :versions])
    |> Map.put(:rate_card_version, result.versions |> Enum.sort() |> Enum.join(", "))
  end

  defp cost_observation(row, acc, from) do
    previous = Map.get(acc.sessions, row["session"], %{input: 0, output: 0, cached: nil})
    {current, delta} = Usage.advance(previous, %{input: row["input"], output: row["output"], cached: row["cached"]})
    acc = put_in(acc, [:sessions, row["session"]], current)
    {:ok, at, _} = DateTime.from_iso8601(row["at"])
    if DateTime.compare(at, from) == :lt, do: acc, else: price_delta(row, delta, acc)
  end

  defp price_delta(row, delta, acc) do
    card = Store.get("rate_card:" <> (row["rate_version"] || ""), %{})
    rates = get_in(card, ["models", row["model"]])

    rate =
      if is_map(rates),
        do: %{input: rates["input"], output: rates["output"], cached_input: rates["cached_input"]},
        else: nil

    acc = %{acc | versions: MapSet.put(acc.versions, card["version"] || "unconfigured")}

    case Usage.cost(delta, rate) do
      :unknown ->
        %{acc | incomplete: true}

      {low, high} ->
        %{
          acc
          | minimum: acc.minimum + low,
            maximum: acc.maximum + high,
            incomplete: acc.incomplete or is_nil(delta.cached)
        }
    end
  end
end
