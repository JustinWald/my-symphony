defmodule SymphonyElixir.Management.Usage do
  @moduledoc """
  Pure accounting for absolute Codex usage observations.

  Callers persist observations before aggregation. Session keys identify a Codex
  thread (not a turn); absolute counters from successive turns must not be added.
  Only allowlisted metadata is returned. Absent cached usage remains unknown.
  """

  @type counters :: %{input: non_neg_integer(), output: non_neg_integer(), cached: non_neg_integer() | nil}

  @doc "Decode supported cumulative usage shapes; ignore delta-only observations."
  @spec normalize(map()) :: {:ok, counters()} | :missing
  def normalize(message) do
    params = object(Map.get(message, "params"))
    msg = object(Map.get(params, "msg"))

    candidates =
      [object(params["tokenUsage"])["total"]] ++
        Enum.map(
          [params, msg, object(msg["info"]), object(params["info"]), object(object(msg["payload"])["info"])],
          &Map.get(&1, "total_token_usage")
        )

    Enum.find_value(candidates, :missing, &decode/1)
  end

  @doc "Advance a session high-water mark, returning nonnegative increments."
  @spec advance(counters(), counters()) :: {counters(), counters()}
  def advance(previous, observed) do
    current = %{
      input: max(previous.input, observed.input),
      output: max(previous.output, observed.output),
      cached: high_water(previous.cached, observed.cached)
    }

    delta = %{
      input: current.input - previous.input,
      output: current.output - previous.output,
      cached: if(is_nil(observed.cached), do: nil, else: max(0, observed.cached - (previous.cached || 0)))
    }

    {current, delta}
  end

  @doc "Estimate cost bounds from configured per-million rates; never imply an invoice."
  @spec cost(counters(), map() | nil) :: {number(), number()} | :unknown
  def cost(usage, rates) when is_map(rates) do
    if Enum.all?([:input, :output, :cached_input], &(is_number(rates[&1]) and rates[&1] >= 0)) do
      cached = min(usage.input, usage.cached || 0)

      known_cost =
        ((usage.input - cached) * rates.input + cached * rates.cached_input + usage.output * rates.output) / 1_000_000

      if is_nil(usage.cached) do
        low = (usage.input * min(rates.input, rates.cached_input) + usage.output * rates.output) / 1_000_000
        high = (usage.input * max(rates.input, rates.cached_input) + usage.output * rates.output) / 1_000_000
        {low, high}
      else
        {known_cost, known_cost}
      end
    else
      :unknown
    end
  end

  def cost(_usage, _rates), do: :unknown

  @doc "Aggregate timestamped observations in a half-open UTC range, retaining earlier baselines."
  @spec summarize([map()], DateTime.t(), DateTime.t()) :: map()
  def summarize(observations, from, until) do
    observations
    |> Enum.sort_by(&{DateTime.to_unix(&1.at, :microsecond), &1.id})
    |> Enum.reduce(
      %{sessions: %{}, input: 0, output: 0, cached: 0, cached_unknown: false, by_model: %{}, by_issue: %{}},
      fn row, acc ->
        previous = Map.get(acc.sessions, row.session, %{input: 0, output: 0, cached: nil})
        {current, delta} = advance(previous, row.usage)
        acc = put_in(acc, [:sessions, row.session], current)

        if DateTime.compare(row.at, from) != :lt and DateTime.compare(row.at, until) == :lt do
          acc
          |> add_delta(delta)
          |> add_group(:by_model, row[:model] || "Unknown", delta)
          |> add_group(:by_issue, to_string(row[:issue] || "Unknown"), delta)
        else
          acc
        end
      end
    )
    |> Map.delete(:sessions)
  end

  defp add_delta(acc, delta) do
    %{
      acc
      | input: acc.input + delta.input,
        output: acc.output + delta.output,
        cached: acc.cached + (delta.cached || 0),
        cached_unknown: acc.cached_unknown or (is_nil(delta.cached) and delta.input > 0)
    }
  end

  defp add_group(acc, field, key, delta) do
    empty = %{input: 0, output: 0, cached: 0, cached_unknown: false}
    Map.update!(acc, field, &Map.update(&1, key, add_delta(empty, delta), fn value -> add_delta(value, delta) end))
  end

  defp object(value) when is_map(value), do: value
  defp object(_value), do: %{}

  defp decode(value) when is_map(value) do
    input = Map.get(value, "input_tokens", value["inputTokens"])
    output = Map.get(value, "output_tokens", value["outputTokens"])
    cached = Map.get(value, "cached_input_tokens", value["cachedInputTokens"])

    if valid?(input) and valid?(output) do
      {:ok, %{input: input, output: output, cached: if(valid?(cached), do: min(input, cached))}}
    end
  end

  defp decode(_value), do: nil
  defp valid?(value), do: is_integer(value) and value >= 0
  defp high_water(nil, value), do: value
  defp high_water(value, nil), do: value
  defp high_water(left, right), do: max(left, right)
end
