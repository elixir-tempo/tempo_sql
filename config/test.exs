import Config

config :ex_tempo_sql, ecto_repos: [Tempo.SQL.Repo, Tempo.SQL.SQLiteRepo]

config :ex_tempo_sql, Tempo.SQL.Repo,
  adapter: Ecto.Adapters.Postgres,
  database: "tempo_sql_test",
  username: System.get_env("PGUSER") || System.get_env("USER"),
  password: System.get_env("PGPASSWORD") || "",
  hostname: System.get_env("PGHOST") || "localhost",
  pool: Ecto.Adapters.SQL.Sandbox,
  types: Tempo.SQL.PostgresTypes,
  priv: "test/support"

# SQLite needs no server: the test database is a file in the system's
# temporary directory, dropped and created again by `mix test`. SQLite
# takes one writer at a time, so the pool is one connection, and the test
# file keeps SQLite's rollback journal: switching a file to WAL as the repo
# connects races the connection that created it.
config :ex_tempo_sql, Tempo.SQL.SQLiteRepo,
  database: Path.join(System.tmp_dir!(), "tempo_sql_test.sqlite3"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 1,
  journal_mode: :delete,
  priv: "test/support/sqlite"

config :logger, level: :warning

# A value in a named zone is stored as the UTC instants it is. Tempo 2.1.0
# converts it to those instants with Elixir's time zone database, so one that
# knows the zones is configured here, as an application storing them does.
config :elixir, :time_zone_database, Tz.TimeZoneDatabase
