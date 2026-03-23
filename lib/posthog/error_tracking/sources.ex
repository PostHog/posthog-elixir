# Portions of this file are inspired from getsentry/sentry-elixir
# (lib/sentry/sources.ex) by Software, Inc. dba Sentry, used under the MIT License.

defmodule PostHog.ErrorTracking.Sources do
  @moduledoc false

  use GenServer

  @version 1

  defstruct [
    :supervisor_name,
    :root_source_code_paths,
    :source_code_path_pattern,
    :source_code_exclude_patterns,
    :source_code_map_path
  ]

  # Public API

  @doc """
  Returns the source line map for the given file path, or `nil` if not found.
  """
  @spec get_source_map_for_file(atom(), String.t()) :: %{pos_integer() => String.t()} | nil
  def get_source_map_for_file(supervisor_name, file) do
    table = table_name(supervisor_name)

    case :ets.lookup(table, file) do
      [{^file, lines}] -> lines
      [] -> nil
    end
  rescue
    # ArgumentError is raised when the ETS table does not exist yet (Sources not started)
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
    supervisor_name = Keyword.fetch!(opts, :supervisor_name)
    name = PostHog.Registry.via(supervisor_name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      supervisor_name: Keyword.fetch!(opts, :supervisor_name),
      root_source_code_paths: Keyword.fetch!(opts, :root_source_code_paths),
      source_code_path_pattern: Keyword.fetch!(opts, :source_code_path_pattern),
      source_code_exclude_patterns: Keyword.fetch!(opts, :source_code_exclude_patterns),
      source_code_map_path: Keyword.get(opts, :source_code_map_path)
    }

    _ =
      :ets.new(
        table_name(state.supervisor_name),
        [:public, :named_table, read_concurrency: true]
      )

    {:ok, state, {:continue, :load_source_map}}
  end

  @impl true
  def handle_continue(:load_source_map, state) do
    load_into_ets(state)
    {:noreply, state}
  end

  # Private

  defp table_name(supervisor_name), do: Module.concat(supervisor_name, "ErrorTracking.Sources")

  defp load_into_ets(state) do
    source_map = load_packaged_source_map(state) || load_from_disk(state)

    if source_map do
      table = table_name(state.supervisor_name)

      Enum.each(source_map, fn {path, lines_map} ->
        :ets.insert(table, {path, lines_map})
      end)
    end
  end

  defp load_packaged_source_map(state) do
    path =
      state.source_code_map_path ||
        Path.join(:code.priv_dir(:posthog), "posthog_source.map")

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

  defp load_from_disk(state) do
    case state.root_source_code_paths do
      [_ | _] ->
        load_files(
          root_source_code_paths: state.root_source_code_paths,
          source_code_path_pattern: state.source_code_path_pattern,
          source_code_exclude_patterns: state.source_code_exclude_patterns
        )

      _ ->
        nil
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
