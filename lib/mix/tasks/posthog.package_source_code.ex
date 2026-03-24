# Portions of this file are inspired from getsentry/sentry-elixir
# (lib/mix/tasks/sentry.package_source_code.ex) by Software, Inc. dba Sentry, used under the MIT License.

defmodule Mix.Tasks.Posthog.PackageSourceCode do
  @moduledoc """
  Packages source code into a binary file for source context in error tracking.

  This task reads all `.ex` source files from the configured root paths and
  writes a compressed binary into PostHog's own `priv/` directory. This file
  is then bundled into the release and loaded at runtime to provide source
  context in stack traces.

  Run this task before building a release:

      mix posthog.package_source_code
      mix release

  ## Options

    * `--output` - Custom output path (default: PostHog's priv dir)
    * `--root-path` - Root source code path(s). Can be specified multiple times.
      Defaults to the current working directory.

  ## Configuration

  This task reads the following from your application config:

      config :posthog,
        root_source_code_paths: [File.cwd!()],
        source_code_path_pattern: "**/*.ex",
        source_code_exclude_patterns: [~r"^_build/", ~r"^priv/", ~r"^test/"]

  CLI options override config values.
  """

  use Mix.Task

  alias PostHog.ErrorTracking.Sources

  @shortdoc "Packages source code for PostHog error tracking source context"

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [output: :string, root_path: [:string, :keep]],
        aliases: [o: :output]
      )

    output =
      Keyword.get(opts, :output, Path.join(:code.priv_dir(:posthog), "posthog_source.map"))

    root_paths =
      case Keyword.get_values(opts, :root_path) do
        [] ->
          Application.get_env(:posthog, :root_source_code_paths, [File.cwd!()])

        paths ->
          paths
      end

    source_opts =
      [
        root_source_code_paths: root_paths,
        source_code_path_pattern:
          Application.get_env(:posthog, :source_code_path_pattern, "**/*.ex"),
        source_code_exclude_patterns:
          Application.get_env(:posthog, :source_code_exclude_patterns, [
            ~r"^_build/",
            ~r"^priv/",
            ~r"^test/"
          ])
      ]

    Mix.shell().info("Reading source files from: #{inspect(root_paths)}")

    source_map = Sources.load_files(source_opts)
    file_count = map_size(source_map)

    binary = Sources.encode_source_map(source_map)

    output |> Path.dirname() |> File.mkdir_p!()
    File.write!(output, binary)

    Mix.shell().info(
      "Packaged #{file_count} source files (#{byte_size(binary)} bytes compressed) to #{output}"
    )
  end
end
