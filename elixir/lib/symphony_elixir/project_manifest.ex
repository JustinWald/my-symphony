defmodule SymphonyElixir.ProjectManifest do
  @moduledoc "Loads a private, static JSON project manifest and rejects overlapping durable/workspace roots."
  alias SymphonyElixir.{Config.Schema, Project, Workflow}

  @spec load(Path.t()) :: {:ok, [Project.t()]} | {:error, term()}
  def load(path) do
    with {:ok, text} <- File.read(path),
         {:ok, %{"projects" => entries}} when is_list(entries) <- Jason.decode(text) do
      parse(entries, Path.dirname(Path.expand(path)))
    else
      error -> {:error, {:invalid_project_manifest, error}}
    end
  end

  defp parse(entries, base) do
    projects = Enum.map(entries, &project(&1, base))
    ids = Enum.map(projects, & &1.id)
    roots = Enum.flat_map(projects, &[&1.state_dir, &1.workspace_root])

    cond do
      projects == [] or not Enum.any?(projects, & &1.enabled) ->
        {:error, :no_enabled_projects}

      length(ids) != length(Enum.uniq(ids)) ->
        {:error, :duplicate_project_id}

      workspace_contains_workflow?(projects) ->
        {:error, :workflow_inside_workspace}

      overlap?(roots) ->
        {:error, :overlapping_project_paths}

      true ->
        {:ok, projects}
    end
  rescue
    error -> {:error, {:invalid_project_manifest, Exception.message(error)}}
  end

  defp project(entry, base) do
    id = Map.fetch!(entry, "id")
    true = is_binary(id) and Regex.match?(~r/\A[a-z0-9][a-z0-9_-]{0,63}\z/, id)
    workflow = Path.expand(Map.fetch!(entry, "workflow_path"), base)
    {:ok, state} = SymphonyElixir.PathSafety.canonicalize(Path.expand(Map.fetch!(entry, "state_dir"), base))
    {:ok, loaded} = Workflow.load(workflow)
    {:ok, settings} = Schema.parse(loaded.config)
    {:ok, workspace} = SymphonyElixir.PathSafety.canonicalize(Path.expand(settings.workspace.root, Path.dirname(workflow)))
    true = is_boolean(Map.get(entry, "enabled", true))
    %Project{id: id, workflow_path: workflow, state_dir: state, workspace_root: workspace, enabled: Map.get(entry, "enabled", true)}
  end

  defp workspace_contains_workflow?(projects) do
    Enum.any?(projects, fn project ->
      {:ok, workflow} = SymphonyElixir.PathSafety.canonicalize(project.workflow_path)
      Enum.any?(projects, fn other -> String.starts_with?(workflow, other.workspace_root <> "/") end)
    end)
  end

  defp overlap?(roots) do
    Enum.with_index(roots)
    |> Enum.any?(fn {root, index} ->
      Enum.drop(roots, index + 1)
      |> Enum.any?(fn other -> root == other or String.starts_with?(other, root <> "/") or String.starts_with?(root, other <> "/") end)
    end)
  end
end
