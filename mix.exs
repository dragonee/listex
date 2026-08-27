defmodule Listex.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/dragonee/listex"
  @description "One process per list: concurrent list editing with stable ids, " <>
                 "arrival-order conflict resolution and idle shutdown."

  def project do
    [
      app: :listex,
      version: @version,
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      # Only for our own builds. Never as a dependency: a warning introduced by
      # a future Elixir would otherwise break someone else's compile.
      elixirc_options: [warnings_as_errors: strict?()],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: @description,
      package: package(),
      docs: docs(),
      name: "Listex",
      source_url: @source_url,
      homepage_url: @source_url
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

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => @source_url <> "/blob/main/CHANGELOG.md"
      },
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md", "LICENSE"],
      source_ref: "v#{@version}",
      source_url: @source_url,
      formatters: ["html"]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # `Mix.env()` is the *parent's* env when we are compiled as a dependency, so
  # it cannot tell us who is building. An explicit opt-in can: CI=1 mix compile.
  defp strict?, do: System.get_env("CI") in ~w(1 true)
end
