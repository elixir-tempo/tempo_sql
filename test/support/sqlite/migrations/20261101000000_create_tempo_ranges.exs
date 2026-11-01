defmodule Tempo.SQL.SQLiteRepo.Migrations.CreateTempoRanges do
  use Ecto.Migration

  import Tempo.SQL.SQLite.Migration

  def change do
    create table(:meetings) do
      add(:name, :string)
      add_tempo_range(:window)
    end

    create_tempo_range_index(:meetings, :window)

    create table(:shops) do
      add(:name, :string)
      add_tempo_range(:hours, frame: :floating, null: false)
    end

    create_tempo_range_index(:shops, :hours)
  end
end
