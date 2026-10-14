defmodule Tempo.Sql.MixProject do
  use Mix.Project

  @version "0.2.0"

  def project do
    [
      app: :ex_tempo_sql,
      version: @version,
      # Excluded from coverage:
      #  * `~r/Error$/` — exception structs, whose uncovered lines are
      #    `message/1` formatting on rare error paths, not logic.
      #  * `~r/^Tempo\.SQL\.Test\./` — test-support schemas and case
      #    templates. They are test scaffolding, and counting them at
      #    100% flatters the real figure.
      #  * `Tempo.SQL.Repo` — the Ecto repo, which is configuration.
      #  * `Tempo.SQL.PostgresTypes` — generated in full by
      #    `Postgrex.Types.define/3`; none of its lines are ours.
      test_coverage: [
        ignore_modules: [
          ~r/Error$/,
          ~r/^Tempo\.SQL\.Test\./,
          Tempo.SQL.Repo,
          Tempo.SQL.PostgresTypes
        ]
      ],
      elixir: "~> 1.17",
      name: "Tempo SQL",
      source_url: "https://github.com/elixir-tempo/tempo_sql",
      docs: docs(),
      deps: deps(),
      description: description(),
      package: package(),
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      dialyzer: [
        plt_add_apps: ~w(ecto ecto_sql postgrex ex_tempo)a
      ]
    ]
  end

  def description do
    "Ecto types and migration helpers for persisting Tempo intervals " <>
      "and interval sets as PostgreSQL tstzrange/tstzmultirange values."
  end

  def package do
    [
      maintainers: ["Kip Cole"],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => "https://github.com/elixir-tempo/tempo_sql",
        "Readme" => "https://github.com/elixir-tempo/tempo_sql/blob/v#{@version}/README.md",
        "Changelog" => "https://github.com/elixir-tempo/tempo_sql/blob/v#{@version}/CHANGELOG.md"
      },
      files: [
        "lib",
        "guides",
        "mix.exs",
        "README.md",
        "CHANGELOG.md",
        "LICENSE.md"
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  def docs do
    [
      source_ref: "v#{@version}",
      main: "readme",
      extras: [
        "README.md",
        "guides/storage-contract.md",
        "CHANGELOG.md",
        "LICENSE.md"
      ],
      formatters: ["html", "markdown"]
    ]
  end

  defp aliases do
    [
      test: ["ecto.drop --quiet", "ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end

  defp deps do
    [
      # Tempo 2.0, built beside it until it is published.
      {:ex_tempo, path: "../tempo"},
      {:ecto, "~> 3.13"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, "~> 0.19"},
      {:ex_doc, "~> 0.38", only: [:dev, :test, :release], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ] ++ maybe_json_polyfill()
  end

  defp maybe_json_polyfill do
    if Code.ensure_loaded?(:json) do
      []
    else
      [{:json_polyfill, "~> 0.2 or ~> 1.0"}]
    end
  end

  defp elixirc_paths(:test), do: ["lib", "mix", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "mix"]
  defp elixirc_paths(_), do: ["lib"]
end
