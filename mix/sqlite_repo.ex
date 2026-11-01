defmodule Tempo.SQL.SQLiteRepo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :ex_tempo_sql,
    adapter: Ecto.Adapters.SQLite3
end
