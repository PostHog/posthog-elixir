defmodule Posthog.MixProject do
  use Mix.Project

  def project do
    [
      app: :posthog,
      deps: deps(),
      description: description(),
      elixir: "~> 1.12",
      elixirc_paths: elixirc_paths(Mix.env()),
      package: package(),
      start_permanent: Mix.env() == :prod,
      version: "0.4.0"
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

  defp deps do
    [
      {:hackney, "~> 1.20"},
      {:dialyxir, "~> 1.3", only: [:dev, :test], runtime: false},
      {:ex_doc, ">= 0.0.0", only: [:doc]},
      {:jason, "~> 1.4", optional: true},
      {:mimic, "~> 1.11", only: :test}
    ]
  end
end
