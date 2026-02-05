defmodule SdkComplianceAdapter.MixProject do
  use Mix.Project

  def project do
    [
      app: :sdk_compliance_adapter,
      version: "1.0.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {SdkComplianceAdapter.Application, []}
    ]
  end

  defp deps do
    [
      {:plug_cowboy, "~> 2.7"},
      {:jason, "~> 1.4"},
      {:posthog, path: ".."}
    ]
  end

  defp releases do
    [
      sdk_compliance_adapter: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent]
      ]
    ]
  end
end
