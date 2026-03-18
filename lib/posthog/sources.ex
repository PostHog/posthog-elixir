defmodule PostHog.Sources do
  @moduledoc """
  Loads and serves source code context for error tracking stack frames.

  Source code is packaged at build time using `mix posthog.package_source_code`
  and loaded into an ETS table at application startup for fast concurrent lookups.

  ## Configuration

      config :posthog,
        enable_source_code_context: true,
        root_source_code_paths: [File.cwd!()],
        context_lines: 5

  ## Packaging source code

  Before building a release, run:

      mix posthog.package_source_code
      mix release

  In development, source files are read directly from disk if available.
  """

  # Part of this approach is inspired by getsentry/sentry-elixir by Software, Inc. dba Sentry
  # Licensed under the MIT License
  # - sentry-elixir/lib/sentry/sources.ex
  # - sentry-elixir/lib/mix/tasks/sentry.package_source_code.ex

  # 💖 open source (under MIT License)

  use GenServer

  @table __MODULE__
  @version 1

  # Public API

  @doc """
  Returns the source line map for the given file path, or `nil` if not found.
  """
  @spec get_source_map_for_file(String.t()) :: %{pos_integer() => String.t()} | nil
  def get_source_map_for_file(file) do
    case :ets.lookup(@table, file) do
      [{^file, lines}] -> lines
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  Extracts source context (pre_context, context_line, post_context) for a given
  file's line map and line number.
  """
  @spec get_source_context(%{pos_integer() => String.t()}, pos_integer(), non_neg_integer()) ::
          {[String.t()], String.t() | nil, [String.t()]}
  def get_source_context(source_map_for_file, line_number, context_lines \\ 5)

  def get_source_context(_source_map, nil, _context_lines), do: {[], nil, []}

  def get_source_context(source_map_for_file, line_number, context_lines) do
    Enum.reduce(0..(2 * context_lines), {[], nil, []}, fn i, {pre, ctx, post} ->
      ctx_line_number = line_number - context_lines + i
      source = Map.get(source_map_for_file, ctx_line_number)

      cond do
        is_nil(source) -> {pre, ctx, post}
        ctx_line_number < line_number -> {[source | pre], ctx, post}
        ctx_line_number == line_number -> {pre, source, post}
        ctx_line_number > line_number -> {pre, ctx, post ++ [source]}
      end
    end)
  end

  @doc """
  Reads source files from the given root paths and returns a source map.

  Each file is read, split into lines, and stored as a map of
  `%{line_number => line_content}` (1-indexed).
  """
  @spec load_files(keyword()) :: %{String.t() => %{pos_integer() => String.t()}}
  def load_files(opts) do
    root_paths = Keyword.fetch!(opts, :root_source_code_paths)
    pattern = Keyword.get(opts, :source_code_path_pattern, "**/*.ex")

    exclude_patterns =
      Keyword.get(opts, :source_code_exclude_patterns, [
        ~r"/_build/",
        ~r"/deps/",
        ~r"/priv/",
        ~r"/test/"
      ])

    root_paths
    |> Enum.flat_map(fn root ->
      root
      |> Path.join(pattern)
      |> Path.wildcard()
      |> Enum.map(fn abs_path -> {Path.relative_to(abs_path, root), abs_path} end)
    end)
    |> Enum.reject(fn {rel_path, _abs_path} ->
      Enum.any?(exclude_patterns, &Regex.match?(&1, rel_path))
    end)
    |> Map.new(fn {rel_path, abs_path} ->
      {rel_path, source_to_lines(File.read!(abs_path))}
    end)
  end

  @doc """
  Encodes a source map into a compressed binary for packaging.
  """
  @spec encode_source_map(%{String.t() => %{pos_integer() => String.t()}}) :: binary()
  def encode_source_map(source_map) do
    %{"version" => @version, "files_map" => source_map}
    |> :erlang.term_to_binary(compressed: 9)
  end

  @doc """
  Decodes a source map binary back into a map.
  """
  @spec decode_source_map(binary()) ::
          {:ok, %{String.t() => %{pos_integer() => String.t()}}} | {:error, term()}
  def decode_source_map(binary) do
    case :erlang.binary_to_term(binary, [:safe]) do
      %{"version" => @version, "files_map" => files_map} -> {:ok, files_map}
      _ -> {:error, :invalid_format}
    end
  rescue
    e -> {:error, e}
  end

  # GenServer callbacks

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    _ = :ets.new(@table, [:public, :named_table, read_concurrency: true])
    {:ok, opts, {:continue, :load_source_map}}
  end

  @impl true
  def handle_continue(:load_source_map, opts) do
    load_into_ets(opts)
    {:noreply, :no_state}
  end

  # Private

  defp load_into_ets(opts) do
    source_map = load_packaged_source_map(opts) || load_from_disk(opts)

    if source_map do
      Enum.each(source_map, fn {path, lines_map} ->
        :ets.insert(@table, {path, lines_map})
      end)
    end
  end

  defp load_packaged_source_map(opts) do
    path =
      Keyword.get(opts, :source_code_map_path) ||
        Application.app_dir(:posthog, "priv/posthog_source.map")

    case File.read(path) do
      {:ok, binary} ->
        case decode_source_map(binary) do
          {:ok, source_map} -> source_map
          {:error, _} -> nil
        end

      {:error, _} ->
        nil
    end
  rescue
    _ -> nil
  end

  defp load_from_disk(opts) do
    case Keyword.get(opts, :root_source_code_paths) do
      [_ | _] = _paths -> load_files(opts)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp source_to_lines(source) do
    source
    |> String.replace_suffix("\n", "")
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Map.new(fn {line, number} -> {number, line} end)
  end
end
