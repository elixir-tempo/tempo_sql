defmodule Tempo.SQL.Repo.Migrations.CreateIntervals do
  use Ecto.Migration

  import Tempo.SQL.Migration

  def change do
    create table(:meetings) do
      add(:name, :string)
      add(:window, :tstzrange)
    end

    create(index(:meetings, [:window], using: :gist))

    create table(:calendars) do
      add(:owner, :string)
      add(:busy_times, :tstzmultirange)
    end

    create(index(:calendars, [:busy_times], using: :gist))

    # Composite types — create once before any table uses them.
    create_tempo_types()

    create table(:fidelity_meetings) do
      add(:name, :string)
      add_tempo_range(:window)
    end

    create table(:fidelity_calendars) do
      add(:owner, :string)
      add_tempo_multirange(:busy_times)
    end

    # The floating frame: values with no zone and no time shift.
    create_tempo_types(frame: :floating)

    create table(:opening_hours) do
      add(:shop, :string)
      add_interval(:hours, frame: :floating)
      add_interval_set(:weekly, frame: :floating)
    end

    create(index(:opening_hours, [:hours], using: :gist))

    create table(:fidelity_opening_hours) do
      add(:shop, :string)
      add_tempo_range(:hours, frame: :floating)
      add_tempo_multirange(:weekly, frame: :floating)
    end
  end
end
