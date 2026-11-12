defmodule SymphonyElixir.RuntimeAssetsTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.RuntimeAssets

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-assets-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    paths = Map.new([:exqlite, :tzdata], &{&1, :code.lib_dir(&1) |> List.to_string() |> Path.join("ebin")})

    on_exit(fn ->
      Enum.each(paths, fn {app, path} -> :code.replace_path(app, String.to_charlist(path)) end)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "source execution needs no escript extraction" do
    assert :ok = RuntimeAssets.prepare()
  end

  test "escript assets are cached outside the executable and reused", %{root: root} do
    files = [
      {~c"exqlite/ebin/exqlite.app", "synthetic app"},
      {~c"exqlite/priv/library.so", "synthetic native library"},
      {~c"tzdata/ebin/tzdata.app", "synthetic app"},
      {~c"tzdata/priv/release_ets/fixture.ets", "synthetic timezone data"},
      {~c"unrelated/private.txt", "not materialized"}
    ]

    script = fixture(root, files)
    cache = Path.join(root, "cache")
    assert :ok = RuntimeAssets.prepare(script, cache)
    assert :ok = RuntimeAssets.prepare(script, cache)
    [directory] = Path.wildcard(Path.join(cache, "*"))
    assert File.read!(Path.join(directory, "exqlite/priv/library.so")) == "synthetic native library"
    assert File.regular?(Path.join(directory, ".ready"))
    refute File.exists?(Path.join(directory, "unrelated"))
    assert :code.lib_dir(:tzdata) |> List.to_string() == Path.join(directory, "tzdata")
  end

  test "asset archives cannot escape their cache directory", %{root: root} do
    script = fixture(root, [{~c"exqlite/../../escape", "unsafe"}])

    assert_raise ArgumentError, "Invalid runtime asset path", fn ->
      RuntimeAssets.prepare(script, Path.join(root, "cache"))
    end

    refute File.exists?(Path.join(root, "escape"))
  end

  defp fixture(root, files) do
    {:ok, {_name, archive}} = :zip.create(~c"fixture.zip", files, [:memory])
    path = Path.join(root, "fixture.escript")
    :ok = :escript.create(String.to_charlist(path), [{:shebang, :default}, {:archive, archive}])
    path
  end

  test "no script and interrupted cache installations have explicit outcomes", %{root: root} do
    assert :ok = RuntimeAssets.prepare(nil, Path.join(root, "unused"))
    files = [{~c"exqlite/ebin/app", "app"}, {~c"tzdata/ebin/app", "app"}]
    script = fixture(root, files)
    {:ok, parts} = :escript.extract(String.to_charlist(script), [])
    digest = :crypto.hash(:sha256, parts[:archive]) |> Base.encode16(case: :lower)
    cache = Path.join(root, "cache")
    target = Path.join(cache, digest)
    File.mkdir_p!(target)
    File.write!(Path.join(target, "partial"), "incomplete")
    assert_raise ArgumentError, "Incomplete runtime asset cache", fn -> RuntimeAssets.prepare(script, cache) end
    File.rm_rf!(target)
    File.write!(target, "wrong type")
    assert_raise ArgumentError, "Runtime assets could not be installed", fn -> RuntimeAssets.prepare(script, cache) end
  end
end
