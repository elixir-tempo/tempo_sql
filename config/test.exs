import Config

config :ex_tempo_sql, ecto_repos: [Tempo.SQL.Repo]

config :ex_tempo_sql, Tempo.SQL.Repo,
  adapter: Ecto.Adapters.Postgres,
  database: "tempo_sql_test",
  username: System.get_env("PGUSER") || System.get_env("USER"),
  password: System.get_env("PGPASSWORD") || "",
  hostname: System.get_env("PGHOST") || "localhost",
  pool: Ecto.Adapters.SQL.Sandbox,
  types: Tempo.SQL.PostgresTypes,
  priv: "test/support"

config :logger, level: :warning

# A value in a named zone is stored as the UTC instants it is. Tempo 2.1.0
# converts it to those instants with Elixir's time zone database, so one that
# knows the zones is configured here, as an application storing them does.
config :elixir, :time_zone_database, Tz.TimeZoneDatabase
