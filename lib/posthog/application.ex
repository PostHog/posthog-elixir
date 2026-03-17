defmodule PostHog.Application do
  @moduledoc false

  use Application

  def start(_type, _args) do
    {conv_config, supervisor_config} = PostHog.Config.read!()

    children =
      if conv_config.enable do
        if conv_config.enable_error_tracking do
          :logger.add_handler(:posthog, PostHog.Handler, %{config: supervisor_config})
        end

        source_children =
          if supervisor_config && supervisor_config.enable_source_code_context do
            source_opts =
              [
                root_source_code_paths: supervisor_config.root_source_code_paths,
                source_code_path_pattern: supervisor_config.source_code_path_pattern,
                source_code_exclude_patterns: supervisor_config.source_code_exclude_patterns,
                context_lines: supervisor_config.context_lines
              ]
              |> then(fn opts ->
                if supervisor_config[:source_code_map_path] do
                  Keyword.put(opts, :source_code_map_path, supervisor_config.source_code_map_path)
                else
                  opts
                end
              end)

            [{PostHog.Sources, source_opts}]
          else
            []
          end

        [{PostHog.Supervisor, supervisor_config}] ++ source_children
      else
        []
      end

    ownership_children =
      if conv_config.test_mode do
        [{NimbleOwnership, name: PostHog.Ownership}]
      else
        []
      end

    Supervisor.start_link(children ++ ownership_children,
      strategy: :one_for_one,
      name: __MODULE__
    )
  end
end
