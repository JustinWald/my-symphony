defmodule SymphonyElixir.Management.UsageTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Management.Usage

  test "only cumulative usage is accepted and payload content is discarded" do
    message = %{
      "params" => %{"tokenUsage" => %{"total" => %{"inputTokens" => 12, "outputTokens" => 3}}, "prompt" => "private"}
    }

    assert {:ok, %{input: 12, output: 3, cached: nil}} = Usage.normalize(message)

    assert :missing =
             Usage.normalize(%{"params" => %{"last_token_usage" => %{"input_tokens" => 12, "output_tokens" => 3}}})

    assert :missing =
             Usage.normalize(%{"params" => %{"total_token_usage" => %{"input_tokens" => -1, "output_tokens" => 3}}})
  end

  test "malformed protocol shapes are treated as missing" do
    for params <- [nil, [], %{"msg" => nil}, %{"tokenUsage" => false}, %{"msg" => %{"payload" => false}}] do
      assert :missing = Usage.normalize(%{"params" => params})
    end
  end

  test "duplicate and stale observations never inflate totals" do
    initial = %{input: 100, output: 20, cached: 50}
    assert {^initial, %{input: 0, output: 0, cached: 0}} = Usage.advance(initial, initial)

    assert {^initial, %{input: 0, output: 0, cached: nil}} =
             Usage.advance(initial, %{input: 10, output: 2, cached: nil})
  end

  test "unknown cache discounts yield ordered bounds even for unusual rate cards" do
    assert {1.0, 2.0} = Usage.cost(%{input: 1_000_000, output: 0, cached: nil}, %{input: 1, output: 1, cached_input: 2})
    assert :unknown = Usage.cost(%{input: 1, output: 1, cached: 0}, %{})
  end

  test "window increments use the previous baseline and exclude the end boundary" do
    from = ~U[2026-11-01 00:00:00Z]
    until = ~U[2026-11-08 00:00:00Z]

    observations = [
      %{id: "a", session: "thread", at: ~U[2026-10-31 23:59:00Z], usage: %{input: 10, output: 2, cached: nil}},
      %{id: "b", session: "thread", at: from, usage: %{input: 30, output: 6, cached: nil}},
      %{id: "c", session: "thread", at: from, usage: %{input: 30, output: 6, cached: nil}},
      %{id: "d", session: "thread", at: until, usage: %{input: 100, output: 20, cached: nil}}
    ]

    assert %{input: 20, output: 4, cached: 0, cached_unknown: true} =
             Usage.summarize(Enum.reverse(observations), from, until)
  end
end
