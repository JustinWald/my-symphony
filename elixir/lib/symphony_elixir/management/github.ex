defmodule SymphonyElixir.Management.GitHub do
  @moduledoc "GitHub reporting access using the configured repository credential."
  alias SymphonyElixir.Management.{HTTP, Settings}

  @spec call(map(), String.t(), keyword()) :: {:ok, term()} | {:error, integer(), non_neg_integer()}
  def call(config, path, options \\ []) do
    repo = config["repo"] || ""

    if Regex.match?(~r/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/, repo) and Settings.secret(config, "github_token") != "" do
      HTTP.request(
        "https://api.github.com/repos/" <> repo <> path,
        Keyword.merge(
          [
            headers: [
              {"authorization", "Bearer " <> Settings.secret(config, "github_token")},
              {"accept", "application/vnd.github+json"},
              {"x-github-api-version", "2022-11-28"}
            ]
          ],
          options
        )
      )
    else
      {:error, 401, 0}
    end
  end

  @spec pages(map(), String.t()) :: {:ok, list()} | {:error, integer(), non_neg_integer()}
  def pages(config, path), do: pages(config, path, 1, [])
  defp pages(_config, _path, 101, _acc), do: {:error, 413, 0}

  defp pages(config, path, page, acc) do
    separator = if String.contains?(path, "?"), do: "&", else: "?"

    case call(config, path <> separator <> "per_page=100&page=#{page}") do
      {:ok, rows} when is_list(rows) ->
        if length(rows) < 100, do: {:ok, acc ++ rows}, else: pages(config, path, page + 1, acc ++ rows)

      {:error, _, _} = error ->
        error

      _ ->
        {:error, 502, 0}
    end
  end
end
