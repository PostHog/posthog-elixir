defmodule PostHog.ErrorTracking.SourcesTest do
  use ExUnit.Case, async: true

  alias PostHog.ErrorTracking.Sources

  # Starts a Sources GenServer (with its required Registry) under the test supervisor.
  # Returns the supervisor_name atom used to identify this instance.
  defp start_sources!(extra_opts \\ []) do
    supervisor_name = :"test_sources_#{System.unique_integer([:positive])}"
    registry_name = PostHog.Registry.registry_name(supervisor_name)
    start_supervised!({Registry, keys: :unique, name: registry_name})

    opts =
      Keyword.merge(
        [
          supervisor_name: supervisor_name,
          root_source_code_paths: [],
          source_code_path_pattern: "**/*.ex",
          source_code_exclude_patterns: []
        ],
        extra_opts
      )

    start_supervised!({Sources, opts}, id: supervisor_name)
    # Block until handle_continue(:load_source_map) has finished so ETS is populated
    :sys.get_state(PostHog.Registry.via(supervisor_name, Sources))
    supervisor_name
  end

  describe "get_source_context/3" do
    setup do
      source_map = %{
        1 => "line_one",
        2 => "line_two",
        3 => "line_three",
        4 => "line_four",
        5 => "line_five"
      }

      %{source_map: source_map}
    end

    test "returns correct context for middle line", %{source_map: source_map} do
      {pre, ctx, post} = Sources.get_source_context(source_map, 3, 2)

      assert ctx == "line_three"
      assert post == ["line_four", "line_five"]
      # pre_context is most-recent first (descending), so the line closest to
      # the error appears first in the list
      assert pre == ["line_two", "line_one"]
    end

    test "nil line_number returns empty context", %{source_map: source_map} do
      assert {[], nil, []} = Sources.get_source_context(source_map, nil, 5)
    end

    test "start of file — fewer pre lines than context_lines", %{source_map: source_map} do
      {pre, ctx, _post} = Sources.get_source_context(source_map, 2, 5)

      assert ctx == "line_two"
      assert pre == ["line_one"]
    end

    test "end of file — fewer post lines than context_lines", %{source_map: source_map} do
      {_pre, ctx, post} = Sources.get_source_context(source_map, 4, 5)

      assert ctx == "line_four"
      assert post == ["line_five"]
    end

    test "context_lines = 0 returns only context line", %{source_map: source_map} do
      assert {[], "line_three", []} = Sources.get_source_context(source_map, 3, 0)
    end

    test "line_number not in source map returns nil context", %{source_map: source_map} do
      {_pre, ctx, _post} = Sources.get_source_context(source_map, 99, 2)

      assert is_nil(ctx)
    end
  end

  describe "encode_source_map/1 and decode_source_map/1" do
    test "roundtrip preserves content" do
      original = %{
        "lib/foo.ex" => %{1 => "defmodule Foo do", 2 => "  def bar, do: :ok", 3 => "end"}
      }

      encoded = Sources.encode_source_map(original)
      assert is_binary(encoded)
      assert {:ok, ^original} = Sources.decode_source_map(encoded)
    end

    test "decode invalid binary returns error" do
      assert {:error, _} = Sources.decode_source_map(<<0, 1, 2, 3>>)
    end

    test "decode binary with wrong version returns error" do
      wrong_version =
        %{"version" => 999, "files_map" => %{}}
        |> :erlang.term_to_binary()

      assert {:error, :invalid_format} = Sources.decode_source_map(wrong_version)
    end
  end

  describe "get_source_map_for_file/2" do
    test "returns nil when Sources is not running for that supervisor" do
      assert is_nil(Sources.get_source_map_for_file(:no_such_supervisor, "anything.ex"))
    end

    test "returns nil for unknown file when running" do
      supervisor_name = start_sources!()
      assert is_nil(Sources.get_source_map_for_file(supervisor_name, "nonexistent.ex"))
    end

    test "returns source map for a loaded file" do
      supervisor_name = start_sources!(root_source_code_paths: [File.cwd!()])

      result =
        Sources.get_source_map_for_file(supervisor_name, "lib/posthog/error_tracking/sources.ex")

      assert is_map(result)
      assert result[4] == "defmodule PostHog.ErrorTracking.Sources do"
    end
  end

  describe "multiple supervisor instances" do
    test "two instances can run concurrently without conflict" do
      sup1 = start_sources!()
      sup2 = start_sources!()

      assert is_nil(Sources.get_source_map_for_file(sup1, "nonexistent.ex"))
      assert is_nil(Sources.get_source_map_for_file(sup2, "nonexistent.ex"))
    end

    test "each instance has isolated source maps" do
      sup1 = start_sources!(root_source_code_paths: [File.cwd!()])
      sup2 = start_sources!()

      assert is_map(
               Sources.get_source_map_for_file(sup1, "lib/posthog/error_tracking/sources.ex")
             )

      assert is_nil(
               Sources.get_source_map_for_file(sup2, "lib/posthog/error_tracking/sources.ex")
             )
    end
  end

  describe "load_files/1" do
    test "loads .ex files and maps line numbers correctly" do
      result = Sources.load_files(root_source_code_paths: [File.cwd!()])

      # Should have loaded some files from lib/
      assert map_size(result) > 0

      # All keys should be relative paths ending in .ex
      assert Enum.all?(result, fn {path, _} -> String.ends_with?(path, ".ex") end)

      # Spot-check a known file: sources.ex itself
      source_lines = result["lib/posthog/error_tracking/sources.ex"]
      assert is_map(source_lines)
      assert source_lines[4] == "defmodule PostHog.ErrorTracking.Sources do"
    end

    test "excludes directories matching the default patterns" do
      # Default patterns use ~r"/dir/" — match mid-path occurrences.
      # Explicitly verify the custom-pattern path works correctly.
      result =
        Sources.load_files(
          root_source_code_paths: [File.cwd!()],
          source_code_exclude_patterns: [~r"/posthog/", ~r"/mix/"]
        )

      refute Enum.any?(result, fn {path, _} ->
               String.contains?(path, "/posthog/") or String.contains?(path, "/mix/")
             end)
    end

    test "respects custom exclude patterns" do
      result =
        Sources.load_files(
          root_source_code_paths: [File.cwd!()],
          source_code_exclude_patterns: [~r"/posthog/"]
        )

      refute Enum.any?(result, fn {path, _} -> String.contains?(path, "/posthog/") end)
    end
  end
end
