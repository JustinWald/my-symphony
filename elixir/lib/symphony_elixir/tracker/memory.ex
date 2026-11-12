defmodule SymphonyElixir.Tracker.Memory do
  @moduledoc """
  In-memory tracker adapter used for tests and local development.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Tracker.Issue

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) do
    normalized_states =
      state_names
      |> Enum.map(&normalize_state/1)
      |> MapSet.new()

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{state: state} ->
       MapSet.member?(normalized_states, normalize_state(state))
     end)}
  end

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids) do
    wanted_ids = MapSet.new(issue_ids)

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{id: id} ->
       MapSet.member?(wanted_ids, id)
     end)}
  end

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(_tracker_settings), do: []

  defp configured_issues do
    case SymphonyElixir.Config.settings!().tracker.provider["issues_file"] do
      nil ->
        Application.get_env(:symphony_elixir, :memory_tracker_issues, [])

      path ->
        directory = SymphonyElixir.Workflow.workflow_file_path() |> Path.dirname()

        path
        |> Path.expand(directory)
        |> File.read!()
        |> Jason.decode!()
        |> Enum.map(&fixture_issue/1)
    end
  end

  defp fixture_issue(row) do
    defaults = Map.from_struct(%Issue{})
    values = Map.new(defaults, fn {field, default} -> {field, Map.get(row, Atom.to_string(field), default)} end)
    struct!(Issue, values)
  end

  defp issue_entries do
    Enum.filter(configured_issues(), &match?(%Issue{}, &1))
  end

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state), do: ""
end
