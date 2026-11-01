defmodule Tempo.SQL.Migration do
  @moduledoc """
  Ecto migration helpers for the Tempo PostgreSQL range types.

  These helpers wrap the underlying Postgres types — `tstzrange`
  and `tstzmultirange`, or `tsrange` and `tsmultirange` for a column
  on the floating frame — under Tempo-flavoured names, so a
  migration reads in the same vocabulary as the schema:

      import Tempo.SQL.Migration

      create table(:meetings) do
        add_interval :window
        add_interval_set :busy, null: false
        add_interval :opening_hours, frame: :floating
      end

      create_interval_index :meetings, :window

  All helpers are thin delegates to `Ecto.Migration.add/3` and
  `Ecto.Migration.index/3` — callers can also write the raw
  `add :window, :tstzrange` form if they prefer.

  """

  alias Ecto.Migration
  alias Tempo.SQL.Conversion

  @doc """
  Add a `tstzrange` column for a `Tempo.Ecto.Interval` field, or a
  `tsrange` column for one on the floating frame.

  ### Arguments

  * `field` is the column name as an atom.

  * `options` is a keyword list of options.

  ### Options

  * `:frame` is `:utc` (the default) for a `tstzrange` column or
    `:floating` for a `tsrange` column, as the field declares it.

  * Every other option is passed through to `Ecto.Migration.add/3` —
    for example `null: false`, `default: ...`.

  ### Returns

  * The column declaration, as `Ecto.Migration.add/3` returns it. Call
    it inside a `create table` block.

  ### Examples

      add_interval :window
      add_interval :window, null: false
      add_interval :opening_hours, frame: :floating

  """
  defmacro add_interval(field, options \\ []) do
    quote bind_quoted: [field: field, options: options] do
      {type, options} = Tempo.SQL.Migration.column_type(:interval, options)
      Migration.add(field, type, options)
    end
  end

  @doc """
  Add a `tstzmultirange` column for a `Tempo.Ecto.IntervalSet`
  field, or a `tsmultirange` column for one on the floating frame.

  Requires PostgreSQL 14 or later.

  ### Arguments

  * `field` is the column name as an atom.

  * `options` is a keyword list of options.

  ### Options

  * `:frame` is `:utc` (the default) for a `tstzmultirange` column or
    `:floating` for a `tsmultirange` column.

  * Every other option is passed through to `Ecto.Migration.add/3`.

  ### Returns

  * The column declaration, as `Ecto.Migration.add/3` returns it. Call
    it inside a `create table` block.

  ### Examples

      add_interval_set :busy_times
      add_interval_set :free_slots, null: false

  """
  defmacro add_interval_set(field, options \\ []) do
    quote bind_quoted: [field: field, options: options] do
      {type, options} = Tempo.SQL.Migration.column_type(:interval_set, options)
      Migration.add(field, type, options)
    end
  end

  @doc """
  Create a GiST index on a range or multirange column, of either frame.

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
  `Tempo.Ecto.TempoMultirange` on one frame.

  This should be run once for each frame a schema uses, in an early
  migration, before any schema declares a column of the types:

      defmodule MyApp.Repo.Migrations.CreateTempoTypes do
        use Ecto.Migration
        import Tempo.SQL.Migration

        def up do
          create_tempo_types()
          create_tempo_types(frame: :floating)
        end

        def down do
          drop_tempo_types(frame: :floating)
          drop_tempo_types()
        end
      end

  On the UTC frame it creates two PostgreSQL composite types:

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

  On the floating frame it creates `tempo_floating_range` and
  `tempo_floating_multirange`, the same with a `tsrange` and a
  `tsmultirange`.

  These are the round-trip-preserving counterparts to the plain range
  columns used by `Tempo.Ecto.Interval` and `Tempo.Ecto.IntervalSet`.

  ### Arguments

  * `options` is a keyword list of options.

  ### Options

  * `:frame` is `:utc` (the default) or `:floating`.

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
  @spec create_tempo_types(keyword()) :: :ok
  def create_tempo_types(options \\ []) do
    for {name, definition} <- composite_types(options) do
      Migration.execute(definition, "DROP TYPE IF EXISTS #{name}")
    end

    :ok
  end

  @doc """
  Drops the composite types created by `create_tempo_types/1` on one
  frame.

  Intended for use in `down/0` callbacks. Fails if any column still
  uses either type — drop those columns first.

  ### Arguments

  * `options` is a keyword list of options.

  ### Options

  * `:frame` is `:utc` (the default) or `:floating`.

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
  @spec drop_tempo_types(keyword()) :: :ok
  def drop_tempo_types(options \\ []) do
    for {name, definition} <- Enum.reverse(composite_types(options)) do
      Migration.execute("DROP TYPE IF EXISTS #{name}", definition)
    end

    :ok
  end

  # The composite types of a frame, each with the statement that creates it.
  defp composite_types(options) do
    frame =
      options
      |> Keyword.get(:frame, :utc)
      |> Conversion.validate_frame!()

    [
      composite_type(column(:tempo_range, frame), "range", column(:interval, frame)),
      composite_type(column(:tempo_multirange, frame), "ranges", column(:interval_set, frame))
    ]
  end

  defp composite_type(name, field, range_type) do
    definition = """
    CREATE TYPE #{name} AS (
      #{String.pad_trailing(field, 10)} #{range_type},
      resolution text,
      meta       jsonb
    )
    """

    {name, definition}
  end

  @doc """
  Adds a `tempo_range` column for a `Tempo.Ecto.TempoRange` field, or
  a `tempo_floating_range` column for one on the floating frame.

  Requires `create_tempo_types/1`, for the column's frame, to have
  been run in an earlier migration, or earlier in this one.

  ### Arguments

  * `field` is the column name as an atom.

  * `options` is a keyword list of options.

  ### Options

  * `:frame` is `:utc` (the default) for a `tempo_range` column or
    `:floating` for a `tempo_floating_range` column.

  * Every other option is passed through to `Ecto.Migration.add/3`.

  ### Returns

  * The column declaration, as `Ecto.Migration.add/3` returns it. Call
    it inside a `create table` block.

  ### Examples

      add_tempo_range :reporting_period
      add_tempo_range :reporting_period, null: false

  """
  defmacro add_tempo_range(field, options \\ []) do
    quote bind_quoted: [field: field, options: options] do
      {type, options} = Tempo.SQL.Migration.column_type(:tempo_range, options)
      Migration.add(field, type, options)
    end
  end

  @doc """
  Adds a `tempo_multirange` column for a `Tempo.Ecto.TempoMultirange`
  field, or a `tempo_floating_multirange` column for one on the
  floating frame.

  Requires `create_tempo_types/1`, for the column's frame, to have
  been run in an earlier migration, or earlier in this one.

  ### Arguments

  * `field` is the column name as an atom.

  * `options` is a keyword list of options.

  ### Options

  * `:frame` is `:utc` (the default) for a `tempo_multirange` column or
    `:floating` for a `tempo_floating_multirange` column.

  * Every other option is passed through to `Ecto.Migration.add/3`.

  ### Returns

  * The column declaration, as `Ecto.Migration.add/3` returns it. Call
    it inside a `create table` block.

  ### Examples

      add_tempo_multirange :busy_times
      add_tempo_multirange :busy_times, null: false

  """
  defmacro add_tempo_multirange(field, options \\ []) do
    quote bind_quoted: [field: field, options: options] do
      {type, options} = Tempo.SQL.Migration.column_type(:tempo_multirange, options)
      Migration.add(field, type, options)
    end
  end

  @doc false
  # The column type a helper adds, on the frame its options name, and
  # the options left for `Ecto.Migration.add/3`.
  @spec column_type(atom(), keyword()) :: {atom(), keyword()}
  def column_type(kind, options) do
    {frame, options} = Keyword.pop(options, :frame, :utc)
    {column(kind, Conversion.validate_frame!(frame)), options}
  end

  defp column(:interval, :utc) do
    :tstzrange
  end

  defp column(:interval, :floating) do
    :tsrange
  end

  defp column(:interval_set, :utc) do
    :tstzmultirange
  end

  defp column(:interval_set, :floating) do
    :tsmultirange
  end

  defp column(:tempo_range, :utc) do
    :tempo_range
  end

  defp column(:tempo_range, :floating) do
    :tempo_floating_range
  end

  defp column(:tempo_multirange, :utc) do
    :tempo_multirange
  end

  defp column(:tempo_multirange, :floating) do
    :tempo_floating_multirange
  end
end
