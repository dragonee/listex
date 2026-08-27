defmodule Listex.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :listex,
      version: @version,
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      elixirc_options: [warnings_as_errors: true],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "One process per list: concurrent list editing with stable ids, " <>
          "arrival-order conflict resolution and idle shutdown.",
      package: [licenses: ["MIT"], files: ~w(lib mix.exs README.md LICENSE .formatter.exs)],
      docs: [main: "Listex", extras: ["README.md", "LICENSE"]]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Listex.Application, []}
    ]
  end

  # Nothing at runtime; ex_doc only builds the docs.
  defp deps do
    [{:ex_doc, "~> 0.40", only: :dev, runtime: false}]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]
end
