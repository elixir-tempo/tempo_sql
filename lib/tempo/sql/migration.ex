defmodule Tempo.SQL.Migration do
  @moduledoc """
  Ecto migration helpers for the Tempo PostgreSQL range types.

  These helpers wrap the underlying Postgres types — `tstzrange`
  and `tstzmultirange` — under Tempo-flavoured names, so a
  migration reads in the same vocabulary as the schema:

      import Tempo.SQL.Migration

      create table(:meetings) do
        add_interval :window
        add_interval_set :busy, null: false
      end

      create_interval_index :meetings, :window

  All helpers are thin delegates to `Ecto.Migration.add/3` and
  `Ecto.Migration.index/3` — callers can also write the raw
  `add :window, :tstzrange` form if they prefer.

  """

  alias Ecto.Migration

  @doc """
  Add a `tstzrange` column for a `Tempo.Ecto.Interval` field.

  ### Arguments

  * `field` is the column name as an atom.

  * `options` are passed through to `Ecto.Migration.add/3` — for
    example `null: false`, `default: ...`.

  ### Returns

  * The column declaration, as `Ecto.Migration.add/3` returns it. Call
    it inside a `create table` block.

  ### Examples

      add_interval :window
      add_interval :window, null: false

  """
  defmacro add_interval(field, options \\ []) do
    quote bind_quoted: [field: field, options: options] do
      Migration.add(field, :tstzrange, options)
    end
  end

  @doc """
  Add a `tstzmultirange` column for a `Tempo.Ecto.IntervalSet`
  field.

  Requires PostgreSQL 14 or later.

  ### Arguments

  * `field` is the column name as an atom.

  * `options` are passed through to `Ecto.Migration.add/3`.

  ### Returns

  * The column declaration, as `Ecto.Migration.add/3` returns it. Call
    it inside a `create table` block.

  ### Examples

      add_interval_set :busy_times
      add_interval_set :free_slots, null: false

  """
  defmacro add_interval_set(field, options \\ []) do
    quote bind_quoted: [field: field, options: options] do
      Migration.add(field, :tstzmultirange, options)
    end
  end

  @doc """
  Create a GiST index on a `tstzrange` or `tstzmultirange` column.

  Range-operator queries (`@>`, `&&`, `-|-`) are only fast under a
  GiST index — this helper wraps `create index(..., using: :gist)`.

  ### Arguments

  * `table` is the table name.

  * `column` is the range column to index.

  * `options` are passed through to `Ecto.Migration.index/3`. The
    `:using` option defaults to `:gist`.

  ### Returns

  * The index creation, as `Ecto.Migration.create/1` returns it.

  ### Examples

      create_interval_index :meetings, :window
      create_interval_index :calendars, :busy_times, name: "calendars_busy_gist"

  """
  defmacro create_interval_index(table, column, options \\ []) do
    quote bind_quoted: [table: table, column: column, options: options] do
      options = Keyword.put_new(options, :using, :gist)
      Migration.create(Migration.index(table, [column], options))
    end
  end

  @doc """
  Create the composite types used by `Tempo.Ecto.TempoRange` and
  `Tempo.Ecto.TempoMultirange`.

  This should be run once, in an early migration, before any
  schema declares a `tempo_range` or `tempo_multirange` column:

      defmodule MyApp.Repo.Migrations.CreateTempoTypes do
        use Ecto.Migration
        import Tempo.SQL.Migration

        def up do
          create_tempo_types()
        end

        def down do
          drop_tempo_types()
        end
      end

  Creates two PostgreSQL composite types:

      CREATE TYPE tempo_range AS (
        range      tstzrange,
        resolution text,
        meta       jsonb
      );

      CREATE TYPE tempo_multirange AS (
        ranges     tstzmultirange,
        resolution text,
        meta       jsonb
      );

  These are the round-trip-preserving counterparts to the plain
  `tstzrange` / `tstzmultirange` columns used by
  `Tempo.Ecto.Interval` and `Tempo.Ecto.IntervalSet`.

  ### Returns

  * The two `CREATE TYPE` statements, as `Ecto.Migration.execute/2`
    returns them. Both are reversible, so a `change/0` that calls this
    rolls back cleanly.

  ### Examples

      def change do
        create_tempo_types()

        create table(:meetings) do
          add_tempo_range :window
        end
      end

  """
  def create_tempo_types do
    Migration.execute(
      """
      CREATE TYPE tempo_range AS (
        range      tstzrange,
        resolution text,
        meta       jsonb
      )
      """,
      "DROP TYPE IF EXISTS tempo_range"
    )

    Migration.execute(
      """
      CREATE TYPE tempo_multirange AS (
        ranges     tstzmultirange,
        resolution text,
        meta       jsonb
      )
      """,
      "DROP TYPE IF EXISTS tempo_multirange"
    )
  end

  @doc """
  Drops the composite types created by `create_tempo_types/0`.

  Intended for use in `down/0` callbacks. Fails if any column still
  uses either type — drop those columns first.

  ### Returns

  * The two `DROP TYPE` statements, as `Ecto.Migration.execute/2`
    returns them.

  ### Examples

      def up do
        create_tempo_types()
      end

      def down do
        drop_tempo_types()
      end

  """
  def drop_tempo_types do
    Migration.execute(
      "DROP TYPE IF EXISTS tempo_multirange",
      """
      CREATE TYPE tempo_multirange AS (
        ranges     tstzmultirange,
        resolution text,
        meta       jsonb
      )
      """
    )

    Migration.execute(
      "DROP TYPE IF EXISTS tempo_range",
      """
      CREATE TYPE tempo_range AS (
        range      tstzrange,
        resolution text,
        meta       jsonb
      )
      """
    )
  end

  @doc """
  Adds a `tempo_range` column for a `Tempo.Ecto.TempoRange` field.

  Requires `create_tempo_types/0` to have been run in an earlier
  migration, or earlier in this one.

  ### Arguments

  * `field` is the column name as an atom.

  * `options` are passed through to `Ecto.Migration.add/3`.

  ### Returns

  * The column declaration, as `Ecto.Migration.add/3` returns it. Call
    it inside a `create table` block.

  ### Examples

      add_tempo_range :reporting_period
      add_tempo_range :reporting_period, null: false

  """
  defmacro add_tempo_range(field, options \\ []) do
    quote bind_quoted: [field: field, options: options] do
      Migration.add(field, :tempo_range, options)
    end
  end

  @doc """
  Adds a `tempo_multirange` column for a `Tempo.Ecto.TempoMultirange`
  field.

  Requires `create_tempo_types/0` to have been run in an earlier
  migration, or earlier in this one.

  ### Arguments

  * `field` is the column name as an atom.

  * `options` are passed through to `Ecto.Migration.add/3`.

  ### Returns

  * The column declaration, as `Ecto.Migration.add/3` returns it. Call
    it inside a `create table` block.

  ### Examples

      add_tempo_multirange :busy_times
      add_tempo_multirange :busy_times, null: false

  """
  defmacro add_tempo_multirange(field, options \\ []) do
    quote bind_quoted: [field: field, options: options] do
      Migration.add(field, :tempo_multirange, options)
    end
  end
end
