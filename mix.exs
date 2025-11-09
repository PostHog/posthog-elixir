defmodule PostHog.MixProject do
  use Mix.Project

  @version "2.1.0"
  @source_url "https://github.com/posthog/posthog-elixir"

  def project do
    [
      app: :posthog,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      package: package()
    ]
  end

  def application do
    [
      mod: {PostHog.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp package do
    [
      name: :posthog,
      maintainers: ["PostHog"],
      licenses: ["MIT"],
      description: "Official PostHog Elixir SDK",
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      favicon: "docs/favicon.svg",
      logo: "docs/favicon.svg",
      source_ref: "v#{@version}",
      source_url: @source_url,
      assets: %{
        "assets" => "assets"
      },
      extras: ["README.md", "CHANGELOG.md", "MIGRATION.md", "guides/advanced-configuration.md"],
      groups_for_modules: [
        Integrations: [PostHog.Integrations.Plug],
        Testing: [PostHog.Test]
      ],
      skip_code_autolink_to: &String.starts_with?(&1, "Posthog"),
      before_closing_body_tag: &before_closing_body_tag/1
    ]
  end

  defp deps do
    [
      {:nimble_options, "~> 1.1"},
      {:req, "~> 0.5.10"},
      {:logger_json, "~> 7.0"},
      {:nimble_ownership, "~> 1.0"},
      {:uuid_v7, "~> 0.6.0"},
      # Development tools
      {:ex_doc, "~> 0.37", only: :dev, runtime: false},
      {:logger_handler_kit, "~> 0.4", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mox, "~> 1.1", only: :test}
    ]
  end
  
  defp before_closing_body_tag(:html) do
    # https://hexdocs.pm/ex_doc/readme.html#rendering-mermaid-graphs
    """
    <script defer src="https://cdn.jsdelivr.net/npm/mermaid@11.12.1/dist/mermaid.min.js"></script>
    <script>
      let initialized = false;
    
      window.addEventListener("exdoc:loaded", () => {
        if (!initialized) {
          mermaid.initialize({
            startOnLoad: false,
            theme: document.body.className.includes("dark") ? "dark" : "default"
          });
          initialized = true;
        }
    
        let id = 0;
        for (const codeEl of document.querySelectorAll("pre code.mermaid")) {
          const preEl = codeEl.parentElement;
          const graphDefinition = codeEl.textContent;
          const graphEl = document.createElement("div");
          const graphId = "mermaid-graph-" + id++;
          mermaid.render(graphId, graphDefinition).then(({svg, bindFunctions}) => {
            graphEl.innerHTML = svg;
            bindFunctions?.(graphEl);
            preEl.insertAdjacentElement("afterend", graphEl);
            preEl.remove();
          });
        }
      });
    </script>
    """
  end
  
  defp before_closing_body_tag(:epub), do: ""
end
