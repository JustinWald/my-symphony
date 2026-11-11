defmodule SymphonyElixir.Management.Proposals do
  @moduledoc "Validated draft PR preparation; never merges or deploys proposed changes."
  alias SymphonyElixir.Management.{Audit, Command, GitHub, Settings, Store}

  @spec prepare() :: :ok
  def prepare do
    config = Settings.config()

    if config["publish_enabled"] == true and get_in(config, ["audit", "enabled"]) == true and
         get_in(config, ["audit", "draft_prs"]) == true do
      Enum.each(
        Store.rows("SELECT * FROM proposals WHERE status IN ('proposed','validation_failed') AND url IS NULL"),
        &prepare_row(config, &1)
      )
    end

    :ok
  end

  defp prepare_row(config, row) do
    rec = Jason.decode!(row["data"])
    if rec["changes"] != [], do: prepare_with_lease(config, row, rec)
  end

  defp prepare_with_lease(config, row, rec) do
    name = "proposal:" <> row["id"]
    ttl = length(get_in(config, ["audit", "validation_commands"]) || []) * 900 + 900

    case Store.claim_job(name, ttl) do
      {:ok, token} ->
        try do
          prepare_one(config, row, rec)
        after
          Store.release_job(name, token)
        end

      :busy ->
        :ok
    end
  end

  defp prepare_one(config, row, rec) do
    result =
      with :ok <- Audit.validate(%{"summary" => "proposal", "recommendations" => [rec]}, config["audit"]),
           {:ok, repository} <- GitHub.call(config, ""),
           base = repository["default_branch"],
           {:ok, ref} <- GitHub.call(config, "/git/ref/heads/" <> base),
           revision = ref["object"]["sha"],
           true <- revision == rec["source_revision"],
           {:ok, workspace} <- workspace(config, row, revision),
           :ok <- write_changes(workspace, rec["changes"]),
           {:ok, _} <- Command.run("git", ["add", "--"] ++ Enum.map(rec["changes"], & &1["path"]), workspace, 30_000),
           :ok <- validate_workspace(config, workspace),
           :ok <- verify_candidate(workspace, rec["changes"]),
           {:ok, url} <- publish(config, row, rec, base, revision) do
        Store.query!("UPDATE proposals SET status='evaluating',url=? WHERE id=?", [url, row["id"]])
        :ok
      end

    if result != :ok,
      do:
        Store.query!("UPDATE proposals SET status=? WHERE id=?", [
          if(result == false, do: "needs_rebase", else: "validation_failed"),
          row["id"]
        ])
  end

  defp workspace(config, row, revision) do
    path = Path.join(SymphonyElixir.Config.management_state_dir(), "audit-workspaces/proposal-" <> row["id"])
    marker = Path.join(path, ".git/symphony-native-revision")

    if File.exists?(path) do
      if File.regular?(marker) and File.read!(marker) == revision,
        do: {:ok, path},
        else: {:error, :preserved_workspace_changed}
    else
      File.mkdir_p!(Path.dirname(path))

      with {:ok, _} <-
             Command.run(
               "git",
               ["clone", "--no-local", "--no-checkout", config["source_repo"], path],
               Path.dirname(path),
               60_000
             ),
           {:ok, _} <- Command.run("git", ["checkout", "--detach", revision], path, 30_000) do
        File.write!(marker, revision)
        {:ok, path}
      end
    end
  end

  defp write_changes(workspace, changes) do
    Enum.reduce_while(changes, :ok, fn change, _ ->
      case write_change(workspace, change) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp write_change(workspace, change) do
    path = Path.join(workspace, change["path"])

    with true <- safe_path?(workspace, change["path"]),
         {:ok, dirty} <- Command.run("git", ["status", "--porcelain", "--", change["path"]], workspace, 30_000),
         true <- dirty == "" or (File.regular?(path) and File.read!(path) == change["content"]) do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, change["content"])
      :ok
    else
      _ -> {:error, :unsafe_or_dirty_path}
    end
  end

  defp safe_path?(workspace, name) do
    Path.split(name) |> Enum.scan(workspace, &Path.join(&2, &1)) |> Enum.all?(&not_symlink?/1)
  end

  defp not_symlink?(path) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} -> false
      _ -> true
    end
  end

  defp verify_candidate(workspace, changes) do
    unchanged =
      Enum.all?(changes, fn change ->
        path = Path.join(workspace, change["path"])
        safe_path?(workspace, change["path"]) and File.regular?(path) and File.read!(path) == change["content"]
      end)

    with true <- unchanged,
         {:ok, _} <-
           Command.run("git", ["diff", "--no-ext-diff", "--no-textconv", "--cached", "--check"], workspace, 30_000),
         {:ok, _} <- Command.run("git", ["diff", "--no-ext-diff", "--no-textconv", "--exit-code"], workspace, 30_000) do
      :ok
    else
      _ -> {:error, :validated_candidate_changed}
    end
  end

  defp validate_workspace(config, workspace) do
    commands = get_in(config, ["audit", "validation_commands"]) || []
    binary = get_in(config, ["audit", "codex_binary"]) || "codex"
    reads = get_in(config, ["audit", "validation_readable_paths"]) || []
    executable = System.find_executable(binary) || binary
    reads = Enum.uniq(reads ++ [Path.dirname(Path.expand(executable))])

    if commands == [] or Enum.any?(reads, &(Path.type(&1) != :absolute)) do
      {:error, :missing_validation_policy}
    else
      grants = Enum.map_join(reads, ",", &(Jason.encode!(&1) <> "=\"read\""))
      grants = if grants == "", do: "", else: "," <> grants

      profile =
        ~s(permissions.validation={filesystem={":minimal"="read",":workspace_roots"="write",":tmpdir"="write",":slash_tmp"="write") <>
          grants <> "},network={enabled=true}}"

      validation_home = Path.join(workspace, ".validation-home")
      File.mkdir_p!(validation_home)

      run_validations(commands, binary, profile, workspace, validation_home)
    end
  end

  defp run_validations(commands, binary, profile, workspace, validation_home) do
    Enum.reduce_while(commands, :ok, fn argv, _ ->
      args = ["sandbox", "-c", profile, "--permission-profile", "validation", "-C", workspace, "--" | argv]

      case Command.run(binary, args, workspace, 900_000, %{"HOME" => validation_home}) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp publish(config, row, rec, base, revision) do
    branch = "symphony/audit-" <> row["id"]
    marker = "<!-- symphony-proposal:" <> row["id"] <> " -->"

    body =
      Enum.map_join(
        ~w(hypothesis evidence evaluation quality_guardrails promotion rollback tradeoff),
        "\n\n",
        &(&1 <> ": " <> rec[&1])
      ) <>
        "\n\nValidation passed in a disposable sandbox. Remote checks and human review required. No deployment performed.\n\n" <>
        marker

    with {:ok, commit} <- GitHub.call(config, "/git/commits/" <> revision),
         {:ok, tree} <-
           GitHub.call(config, "/git/trees",
             method: :post,
             json: %{
               base_tree: commit["tree"]["sha"],
               tree: Enum.map(rec["changes"], &%{path: &1["path"], mode: "100644", type: "blob", content: &1["content"]})
             }
           ),
         {:ok, existing} <-
           GitHub.pages(
             config,
             "/pulls?state=all&head=" <> URI.encode_www_form(hd(String.split(config["repo"], "/")) <> ":" <> branch)
           ) do
      publish_candidate(config, existing, tree["sha"], %{
        branch: branch,
        marker: marker,
        body: body,
        base: base,
        revision: revision,
        title: rec["title"]
      })
    end
  end

  defp publish_candidate(config, [pr | _], tree, candidate) do
    with {:ok, current} <- GitHub.call(config, "/git/commits/" <> pr["head"]["sha"]),
         true <- current["tree"]["sha"] == tree and String.contains?(pr["body"] || "", candidate.marker) do
      {:ok, pr["html_url"]}
    else
      _ -> {:error, :existing_proposal_differs}
    end
  end

  defp publish_candidate(config, [], tree, candidate) do
    request = %{
      title: "Symphony audit: " <> candidate.title,
      head: candidate.branch,
      base: candidate.base,
      body: candidate.body,
      draft: true
    }

    with :ok <- create_ref(config, candidate.branch, candidate.title, tree, candidate.revision),
         {:ok, pr} <- GitHub.call(config, "/pulls", method: :post, json: request) do
      {:ok, pr["html_url"]}
    end
  end

  defp create_ref(config, branch, title, tree, revision) do
    case GitHub.call(config, "/git/ref/heads/" <> branch) do
      {:error, 404, _} ->
        with {:ok, commit} <-
               GitHub.call(config, "/git/commits",
                 method: :post,
                 json: %{message: title, tree: tree, parents: [revision]}
               ),
             {:ok, _} <-
               GitHub.call(config, "/git/refs",
                 method: :post,
                 json: %{ref: "refs/heads/" <> branch, sha: commit["sha"]}
               ),
             do: :ok

      {:ok, ref} ->
        with {:ok, commit} <- GitHub.call(config, "/git/commits/" <> ref["object"]["sha"]),
             true <- commit["tree"]["sha"] == tree and Enum.map(commit["parents"], & &1["sha"]) == [revision],
             do: :ok

      error ->
        error
    end
  end
end
