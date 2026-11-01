defmodule Tempo.SQL.SQLite.Migration do
  @moduledoc """
  Ecto migration helpers for `Tempo.Ecto.SQLite.TempoRange` columns.

      import Tempo.SQL.SQLite.Migration

      create table(:meetings) do
        add_tempo_range :window
      end

      create_tempo_range_index :meetings, :window

  The column is `TEXT`, holding the JSON document
  `Tempo.SQL.SQLite.Document` writes, whichever frame the field is on.
  The index is a pair of expression indexes on the document's lower and
  upper bounds, which the comparisons `Tempo.Ecto.SQLite.QueryAPI`
  writes are answered from.

  """

  alias Ecto.Migration
  alias Tempo.SQL.Conversion

  @doc """
  Adds a `TEXT` column for a `Tempo.Ecto.SQLite.TempoRange` field.

  ### Arguments

  * `field` is the column name as an atom.

  * `options` is a keyword list of options.

  ### Options

  * `:frame` is the field's frame, `:utc` (the default) or `:floating`.
    The column is `TEXT` on either; the option is checked and taken out.

  * Every other option is passed through to `Ecto.Migration.add/3`.

  ### Returns

  * The column declaration, as `Ecto.Migration.add/3` returns it. Call
    it inside a `create table` block.

  ### Examples

      add_tempo_range :window
      add_tempo_range :opening_hours, frame: :floating, null: false

  """
  defmacro add_tempo_range(field, options \\ []) do
    quote bind_quoted: [field: field, options: options] do
      Migration.add(field, :text, Tempo.SQL.SQLite.Migration.column_options(options))
    end
  end

  @doc """
  Creates the expression indexes on the bounds of a
  `Tempo.Ecto.SQLite.TempoRange` column.

  Two indexes are created, `<table>_<column>_lo_index` on the lower
  bound and `<table>_<column>_hi_index` on the upper, so that a query
  bounding either end of the column's spans is answered by an index.

  ### Arguments

  * `table` is the table name as an atom.

  * `column` is the column name as an atom.

  ### Returns

  * The two `CREATE INDEX` statements, as `Ecto.Migration.execute/2`
    returns them. Both are reversible.

  ### Examples

      create_tempo_range_index :meetings, :window

  """
  @spec create_tempo_range_index(atom(), atom()) :: :ok
  def create_tempo_range_index(table, column) when is_atom(table) and is_atom(column) do
    for bound <- ["lo", "hi"] do
      name = "#{table}_#{column}_#{bound}_index"

      Migration.execute(
        ~s|CREATE INDEX "#{name}" ON "#{table}" (json_extract("#{column}", '$.#{bound}'))|,
        ~s|DROP INDEX IF EXISTS "#{name}"|
      )
    end

    :ok
  end

  @doc false
  # The options of `add_tempo_range/2` left for `Ecto.Migration.add/3`,
  # once its frame is checked.
  @spec column_options(keyword()) :: keyword()
  def column_options(options) do
    {frame, options} = Keyword.pop(options, :frame, :utc)
    Conversion.validate_frame!(frame)
    options
  end
end
