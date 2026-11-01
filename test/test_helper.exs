{:ok, _} = Tempo.SQL.Repo.start_link()
{:ok, _} = Tempo.SQL.SQLiteRepo.start_link()

Ecto.Adapters.SQL.Sandbox.mode(Tempo.SQL.Repo, :manual)
Ecto.Adapters.SQL.Sandbox.mode(Tempo.SQL.SQLiteRepo, :manual)

ExUnit.start()
