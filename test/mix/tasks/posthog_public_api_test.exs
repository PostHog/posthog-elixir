defmodule Mix.Tasks.Posthog.PublicApiTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Posthog.PublicApi

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    on_exit(fn -> File.rm_rf!(dir) end)
  end

  test "committed snapshot matches the public API" do
    assert ExUnit.CaptureIO.capture_io(fn -> PublicApi.run(["--check"]) end) =~
             "Public API snapshot is up to date"
  end

  test "update creates parent directories and writes the committed contract", %{tmp_dir: dir} do
    path = Path.join([dir, "nested", "api.snapshot"])

    ExUnit.CaptureIO.capture_io(fn -> PublicApi.run(["--update", "--snapshot", path]) end)

    assert File.read!(path) == File.read!("public_api.snapshot")

    assert ExUnit.CaptureIO.capture_io(fn -> PublicApi.run(["--snapshot", path]) end) =~
             "Public API snapshot is up to date"
  end

  test "check rejects a stale snapshot without overwriting it", %{tmp_dir: dir} do
    path = Path.join(dir, "api.snapshot")
    File.write!(path, "obsolete API\n")

    error =
      assert_raise Mix.Error, fn -> PublicApi.run(["--check", "--snapshot", path]) end

    assert error.message =~ "Public API snapshot is out of date"
    assert error.message =~ "-obsolete API"
    assert error.message =~ "+PostHog"
    assert File.read!(path) == "obsolete API\n"
  end

  test "check reports a missing snapshot without creating it", %{tmp_dir: dir} do
    path = Path.join(dir, "missing.snapshot")

    assert_raise Mix.Error, ~r/Public API snapshot does not exist/, fn ->
      PublicApi.run(["--snapshot", path])
    end

    refute File.exists?(path)
  end

  test "check reports unreadable snapshot paths", %{tmp_dir: dir} do
    assert_raise Mix.Error, ~r/Could not read .*: :eisdir/, fn ->
      PublicApi.run(["--snapshot", dir])
    end
  end

  test "check and update cannot be combined", %{tmp_dir: dir} do
    path = Path.join(dir, "api.snapshot")

    assert_raise Mix.Error, "Pass only one of --check or --update", fn ->
      PublicApi.run(["--check", "--update", "--snapshot", path])
    end

    refute File.exists?(path)
  end
end
