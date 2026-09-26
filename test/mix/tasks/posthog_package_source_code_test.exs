defmodule Mix.Tasks.Posthog.PackageSourceCodeTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Posthog.PackageSourceCode
  alias PostHog.ErrorTracking.Sources

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    on_exit(fn -> File.rm_rf!(dir) end)
    keys = [:root_source_code_paths, :source_code_path_pattern, :source_code_exclude_patterns]
    original = Map.new(keys, &{&1, Application.fetch_env(:posthog, &1)})
    Enum.each(keys, &Application.delete_env(:posthog, &1))

    on_exit(fn ->
      Enum.each(original, fn
        {key, {:ok, value}} -> Application.put_env(:posthog, key, value)
        {key, :error} -> Application.delete_env(:posthog, key)
      end)
    end)
  end

  test "CLI roots override config and package multiple roots with default exclusions", %{
    tmp_dir: dir
  } do
    first = Path.join(dir, "first")
    second = Path.join(dir, "second")
    output = Path.join([dir, "output", "source.map"])
    File.mkdir_p!(Path.join(first, "lib"))
    File.mkdir_p!(second)
    File.write!(Path.join(first, "lib/one.ex"), "first line\nsecond line\n")
    File.write!(Path.join(second, "two.ex"), "other root\n")
    File.write!(Path.join(second, "ignored.exs"), "not production source")

    for excluded <- ["_build", "priv", "test"] do
      File.mkdir_p!(Path.join(first, excluded))
      File.write!(Path.join([first, excluded, "ignored.ex"]), "excluded source")
    end

    Application.put_env(:posthog, :root_source_code_paths, [Path.join(dir, "unused")])

    ExUnit.CaptureIO.capture_io(fn ->
      PackageSourceCode.run(["--root-path", first, "--root-path", second, "--output", output])
    end)

    assert {:ok,
            %{
              "lib/one.ex" => %{1 => "first line", 2 => "second line"},
              "two.ex" => %{1 => "other root"}
            }} == Sources.decode_source_map(File.read!(output))
  end

  test "uses configured roots, pattern and exclusions when no CLI root is supplied", %{
    tmp_dir: dir
  } do
    File.write!(Path.join(dir, "keep.exs"), "included\n")
    File.write!(Path.join(dir, "skip.exs"), "excluded\n")
    File.write!(Path.join(dir, "other.ex"), "wrong extension\n")
    Application.put_env(:posthog, :root_source_code_paths, [dir])
    Application.put_env(:posthog, :source_code_path_pattern, "*.exs")
    Application.put_env(:posthog, :source_code_exclude_patterns, [~r/^skip/])
    output = Path.join(dir, "source.map")

    ExUnit.CaptureIO.capture_io(fn -> PackageSourceCode.run(["-o", output]) end)

    assert {:ok, %{"keep.exs" => %{1 => "included"}}} ==
             Sources.decode_source_map(File.read!(output))
  end
end
