defmodule Tempo.Ecto.SQLite.QueryAPI do
  @moduledoc """
  Ecto query fragments for `Tempo.Ecto.SQLite.TempoRange` columns, named
  after Allen's interval algebra as `Tempo.Ecto.QueryAPI` names the
  PostgreSQL range operators.

      import Ecto.Query
      import Tempo.Ecto.SQLite.QueryAPI

      {:ok, morning} = Tempo.Ecto.SQLite.QueryAPI.probe(~o"2026-06-15T09:00Z/2026-06-15T12:00Z")
      from m in Meeting, where: overlaps(m.window, ^morning)

  The right-hand operand is a probe, the integer bounds of an expression
  `probe/2` makes on the column's frame, pinned with `^`. Each macro
  compares those bounds with the bounds the column's document holds:

    * `overlaps/2` — whether a span of the column shares any second with
      the probe.

    * `contains/2` — whether a span of the column holds every second of
      the probe.

    * `meets/2` — whether the column's stretch ends where the probe
      begins, or begins where it ends.

    * `strictly_before/2` — whether the column's stretch ends at or
      before the probe begins: Allen's `precedes` and `meets`.

    * `strictly_after/2` — whether the column's stretch begins at or
      after the probe ends.

  `overlaps/2` and `contains/2` test each span the column holds, so the
  gaps between a set's members match nothing, and first compare the
  stretch, which the indexes `Tempo.SQL.SQLite.Migration.create_tempo_range_index/2`
  creates answer. The bounds are whole seconds.

  """

  alias Tempo.SQL.SQLite.Document

  @typedoc "The bounds of an expression, in whole seconds on a frame, for a query."
  @type probe() :: %{lo: integer(), hi: integer()}

  @doc """
  Makes the probe a query compares a column with: the bounds of an
  expression, in whole seconds on the column's frame.

  ### Arguments

  * `expression` is a `t:Tempo.t/0` with a place on the time line.

  * `frame` is the column's frame, `:utc` (the default) or `:floating`.

  ### Returns

  * `{:ok, probe}`, a map of `:lo` and `:hi`, to pin with `^`.

  * `{:error, exception}` for an expression with no place on the time
    line, or of the other frame.

  ### Examples

      iex> Tempo.Ecto.SQLite.QueryAPI.probe(~o"2026-06-15T09:00Z/2026-06-15T10:00Z")
      {:ok, %{lo: 1781514000, hi: 1781517600}}

      iex> {:error, error} = Tempo.Ecto.SQLite.QueryAPI.probe(~o"2026-06-15T09:00/2026-06-15T10:00")
      iex> error.reason
      :frame

  """
  @spec probe(Tempo.t(), Tempo.SQL.Conversion.frame()) :: {:ok, probe()} | {:error, Exception.t()}
  def probe(expression, frame \\ :utc) do
    with {:ok, {lower, upper}} <- Document.bounds(expression, frame) do
      {:ok, %{lo: lower, hi: upper}}
    end
  end

  @doc """
  Matches rows with a span that shares any second with the probe.

  ### Arguments

  * `column` is a `Tempo.Ecto.SQLite.TempoRange` column.

  * `probe` is a probe from `probe/2`, pinned with `^`.

  ### Returns

  * A query fragment usable anywhere Ecto accepts a boolean expression.

  ### Examples

      from m in Meeting, where: overlaps(m.window, ^morning)

  """
  defmacro overlaps(column, probe) do
    probe = pinned!(probe, :overlaps)

    quote do
      fragment(
        "(json_extract(?, '$.lo') < ? AND json_extract(?, '$.hi') > ? AND EXISTS (SELECT 1 FROM json_each(?, '$.spans') WHERE json_extract(value, '$[0]') < ? AND json_extract(value, '$[1]') > ?))",
        unquote(column),
        ^unquote(probe).hi,
        unquote(column),
        ^unquote(probe).lo,
        unquote(column),
        ^unquote(probe).hi,
        ^unquote(probe).lo
      )
    end
  end

  @doc """
  Matches rows with a span that holds every second of the probe.

  ### Arguments

  * `column` is a `Tempo.Ecto.SQLite.TempoRange` column.

  * `probe` is a probe from `probe/2`, pinned with `^`.

  ### Returns

  * A query fragment usable anywhere Ecto accepts a boolean expression.

  ### Examples

      from s in Shop, where: contains(s.opening_hours, ^half_past_nine)

  """
  defmacro contains(column, probe) do
    probe = pinned!(probe, :contains)

    quote do
      fragment(
        "(json_extract(?, '$.lo') <= ? AND json_extract(?, '$.hi') >= ? AND EXISTS (SELECT 1 FROM json_each(?, '$.spans') WHERE json_extract(value, '$[0]') <= ? AND json_extract(value, '$[1]') >= ?))",
        unquote(column),
        ^unquote(probe).lo,
        unquote(column),
        ^unquote(probe).hi,
        unquote(column),
        ^unquote(probe).lo,
        ^unquote(probe).hi
      )
    end
  end

  @doc """
  Matches rows whose stretch ends where the probe begins, or begins
  where it ends.

  ### Arguments

  * `column` is a `Tempo.Ecto.SQLite.TempoRange` column.

  * `probe` is a probe from `probe/2`, pinned with `^`.

  ### Returns

  * A query fragment usable anywhere Ecto accepts a boolean expression.

  ### Examples

      from m in Meeting, where: meets(m.window, ^lunch)

  """
  defmacro meets(column, probe) do
    probe = pinned!(probe, :meets)

    quote do
      fragment(
        "(json_extract(?, '$.hi') = ? OR json_extract(?, '$.lo') = ?)",
        unquote(column),
        ^unquote(probe).lo,
        unquote(column),
        ^unquote(probe).hi
      )
    end
  end

  @doc """
  Matches rows whose stretch ends at or before the probe begins.

  ### Arguments

  * `column` is a `Tempo.Ecto.SQLite.TempoRange` column.

  * `probe` is a probe from `probe/2`, pinned with `^`.

  ### Returns

  * A query fragment usable anywhere Ecto accepts a boolean expression.

  ### Examples

      from m in Meeting, where: strictly_before(m.window, ^lunch)

  """
  defmacro strictly_before(column, probe) do
    probe = pinned!(probe, :strictly_before)

    quote do
      fragment("json_extract(?, '$.hi') <= ?", unquote(column), ^unquote(probe).lo)
    end
  end

  @doc """
  Matches rows whose stretch begins at or after the probe ends.

  ### Arguments

  * `column` is a `Tempo.Ecto.SQLite.TempoRange` column.

  * `probe` is a probe from `probe/2`, pinned with `^`.

  ### Returns

  * A query fragment usable anywhere Ecto accepts a boolean expression.

  ### Examples

      from m in Meeting, where: strictly_after(m.window, ^lunch)

  """
  defmacro strictly_after(column, probe) do
    probe = pinned!(probe, :strictly_after)

    quote do
      fragment("json_extract(?, '$.lo') >= ?", unquote(column), ^unquote(probe).hi)
    end
  end

  # A probe is written pinned, `^morning`, as a range is for
  # `Tempo.Ecto.QueryAPI`; the macro reads its two bounds from it.
  defp pinned!({:^, _meta, [probe]}, _macro) do
    probe
  end

  defp pinned!(other, macro) do
    raise ArgumentError,
          "#{macro}/2 takes a probe pinned with ^, as from Tempo.Ecto.SQLite.QueryAPI.probe/2, " <>
            "not #{Macro.to_string(other)}"
  end
end
