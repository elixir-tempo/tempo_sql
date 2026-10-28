# `Postgrex.Types.define/3` defines the module itself, so it is not wrapped in
# a `defmodule`.
Postgrex.Types.define(
  Tempo.SQL.PostgresTypes,
  [],
  json: Tempo.SQL.JSON,
  moduledoc: """
  The Postgrex types for a repository that stores the composite
  `tempo_range` and `tempo_multirange` columns.

  A composite keeps its expression in a `jsonb` field, and Postgrex
  encodes `jsonb` with the JSON library its types name, Jason unless
  told otherwise. These types name `Tempo.SQL.JSON`, which uses
  Erlang's built-in `:json`, so no JSON dependency is needed. Name them
  in the repository's configuration:

      config :my_app, MyApp.Repo, types: Tempo.SQL.PostgresTypes

  An application that needs other Postgrex extensions defines its own
  types with the same JSON library:

      Postgrex.Types.define(MyApp.PostgresTypes, [MyApp.SomeExtension], json: Tempo.SQL.JSON)

  """
)
