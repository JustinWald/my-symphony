defmodule SymphonyElixir.RuntimeAssets do
  @moduledoc "Materialize native libraries and timezone data when running an escript."
  alias SymphonyElixir.Config
  @apps [:exqlite, :tzdata]

  @spec prepare() :: :ok
  def prepare do
    script = List.first(:init.get_plain_arguments())
    prepare(if(script, do: List.to_string(script)), Config.runtime_assets_dir())
  end

  @spec prepare(Path.t() | nil, Path.t()) :: :ok
  def prepare(nil, _cache), do: :ok

  def prepare(script, cache) do
    {:ok, parts} = :escript.extract(String.to_charlist(script), [])

    case Keyword.fetch(parts, :archive) do
      {:ok, archive} -> prepare_archive(archive, cache)
      :error -> :ok
    end
  end

  defp prepare_archive(archive, cache) do
    digest = :crypto.hash(:sha256, archive) |> Base.encode16(case: :lower)
    target = Path.join(cache, digest)
    if not File.regular?(Path.join(target, ".ready")), do: materialize(archive, cache, target)

    Enum.each(@apps, fn app ->
      path = Path.join([target, Atom.to_string(app), "ebin"])
      true = :code.replace_path(app, String.to_charlist(path))
    end)

    :ok
  end

  defp materialize(archive, cache, target) do
    File.mkdir_p!(cache)
    File.chmod!(cache, 0o700)
    temporary = target <> "." <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    File.mkdir!(temporary)
    File.chmod!(temporary, 0o700)

    try do
      names = archive_members(archive)
      {:ok, _} = :zip.extract(archive, file_list: names, cwd: String.to_charlist(temporary))
      File.write!(Path.join(temporary, ".ready"), "ready\n")
      publish(temporary, target)
    after
      File.rm_rf(temporary)
    end
  end

  defp archive_members(archive) do
    {:ok, entries} = :zip.list_dir(archive)

    Enum.flat_map(entries, fn
      {:zip_file, name, _info, _comment, _offset, _size} -> select_member(name)
      _ -> []
    end)
  end

  defp select_member(name) do
    path = List.to_string(name)

    if String.starts_with?(path, ["exqlite/", "tzdata/"]) do
      if Path.type(path) != :relative or ".." in Path.split(path),
        do: raise(ArgumentError, "Invalid runtime asset path")

      [name]
    else
      []
    end
  end

  defp publish(temporary, target) do
    case File.rename(temporary, target) do
      :ok ->
        :ok

      {:error, reason} when reason in [:eexist, :enotempty] ->
        unless File.regular?(Path.join(target, ".ready")), do: raise(ArgumentError, "Incomplete runtime asset cache")

      {:error, _} ->
        raise ArgumentError, "Runtime assets could not be installed"
    end
  end
end
