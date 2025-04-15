defmodule Posthog.MixProject do
  use Mix.Project

  @version "0.4.4"

  def project do
    [
      app: :posthog,
      deps: deps(),
      description: description(),
      elixir: "~> 1.12",
      elixirc_paths: elixirc_paths(Mix.env()),
      package: package(),
      docs: docs(),
      start_permanent: Mix.env() == :prod,
      version: @version
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp description do
    """
    Official PostHog Elixir HTTP client.
    """
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp package do
    [
      name: :posthog,
      files: ["lib", "mix.exs", "README.md", "LICENSE"],
      maintainers: ["PostHog"],
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/posthog/posthog-elixir"}
    ]
  end

  defp docs do
    [
      favicon: "docs/favicon.svg",
      logo: "docs/favicon.svg",
      source_ref: "v#{@version}",
      source_url: "https://github.com/posthog/posthog-elixir",
      extras: ["README.md"]
    ]
  end

  defp deps do
    [
      {:dialyxir, "~> 1.3", only: [:dev, :test], runtime: false},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:hackney, "~> 1.20"},
      {:jason, "~> 1.4", optional: true},
      {:mimic, "~> 1.11", only: :test},
      {:uuidv7, "~> 1.0"}
    ]
  end
end
