defmodule Tempo.Ecto.QueryAPI.Composite do
  @moduledoc """
  Ecto query fragments for the `tempo_range` and
  `tempo_multirange` composite types — the same Allen-named
  macros as `Tempo.Ecto.QueryAPI`, but auto-unwrapping the
  `(column).range` / `(column).ranges` field so Postgres range
  operators can apply.

  Use these when the column is `Tempo.Ecto.TempoRange` or
  `Tempo.Ecto.TempoMultirange`. Mixing the plain-range macros
  with a composite column produces a SQL error because
  `@>` / `&&` etc. are not defined on composite types directly.

  ## Usage

      import Ecto.Query
      import Tempo.Ecto.QueryAPI.Composite

      from m in Meeting, where: overlaps(m.window, ^iv)

  Right-hand operands are still plain `%Postgrex.Range{}` /
  `%Postgrex.Multirange{}` values, produced by dumping a
  `Tempo.Ecto.Interval` or `Tempo.Ecto.IntervalSet` field.
  The *left* operand auto-unwraps.

  ## Macros

  Same names and semantics as `Tempo.Ecto.QueryAPI`:

    * `contains/2` — `@>`
    * `overlaps/2` — `&&`
    * `meets/2`    — `-|-`
    * `strictly_before/2` — `<<`
    * `strictly_after/2`  — `>>`

  """

  @doc """
  Matches rows whose span fully contains the given range.

  Expands to the PostgreSQL `@>` operator.

  The column's range component is unwrapped automatically, so the
  Postgres operator applies to the range rather than the composite.

  ### Arguments

  * `left` is the `range` component of a `tempo_range` / `tempo_multirange` column.

  * `right` is a `t:Postgrex.Range.t/0` or `t:Postgrex.Multirange.t/0`,
    typically produced by dumping a Tempo value and pinned with `^`.

  ### Returns

  * A query fragment usable anywhere Ecto accepts a boolean
    expression — `where`, `having`, `select`, a join condition.

  ### Semantics

  * Allen's `contains` and `finished_by`/`started_by` — every instant of
  the probe falls inside the column's span.

  ### Examples

      from(m in Meeting, where: contains(m.window, ^lunch_hour), select: m.name)

  > *"Which meetings run for the whole lunch hour?"*

  """
  defmacro contains(left, right) do
    quote do
      fragment("(?).range @> ?", unquote(left), unquote(right))
    end
  end

  @doc """
  Matches rows whose span shares any instant with the given range.

  Expands to the PostgreSQL `&&` operator.

  The column's range component is unwrapped automatically, so the
  Postgres operator applies to the range rather than the composite.

  ### Arguments

  * `left` is the `range` component of a `tempo_range` / `tempo_multirange` column.

  * `right` is a `t:Postgrex.Range.t/0` or `t:Postgrex.Multirange.t/0`,
    typically produced by dumping a Tempo value and pinned with `^`.

  ### Returns

  * A query fragment usable anywhere Ecto accepts a boolean
    expression — `where`, `having`, `select`, a join condition.

  ### Semantics

  * Any non-disjoint pair — Allen's `overlaps`, `overlapped_by`,
  `starts`, `started_by`, `during`, `contains`, `finishes`,
  `finished_by` and `equals`.

  ### Examples

      from(m in Meeting, where: overlaps(m.window, ^proposed), select: m.name)

  > *"What would clash with this proposed slot?"*

  """
  defmacro overlaps(left, right) do
    quote do
      fragment("(?).range && ?", unquote(left), unquote(right))
    end
  end

  @doc """
  Matches rows whose span is immediately adjacent to the given range.

  Expands to the PostgreSQL `-|-` operator.

  The column's range component is unwrapped automatically, so the
  Postgres operator applies to the range rather than the composite.

  ### Arguments

  * `left` is the `range` component of a `tempo_range` / `tempo_multirange` column.

  * `right` is a `t:Postgrex.Range.t/0` or `t:Postgrex.Multirange.t/0`,
    typically produced by dumping a Tempo value and pinned with `^`.

  ### Returns

  * A query fragment usable anywhere Ecto accepts a boolean
    expression — `where`, `having`, `select`, a join condition.

  ### Semantics

  * Allen's `meets` and `met_by` — no gap and no overlap. Under the
  half-open convention `09:00–10:00` meets `10:00–11:00` exactly.

  ### Examples

      from(m in Meeting, where: meets(m.window, ^next_slot), select: m.name)

  > *"What runs back-to-back with this one?"*

  """
  defmacro meets(left, right) do
    quote do
      fragment("(?).range -|- ?", unquote(left), unquote(right))
    end
  end

  @doc """
  Matches rows whose span lies entirely earlier than the given range.

  Expands to the PostgreSQL `<<` operator.

  The column's range component is unwrapped automatically, so the
  Postgres operator applies to the range rather than the composite.

  ### Arguments

  * `left` is the `range` component of a `tempo_range` / `tempo_multirange` column.

  * `right` is a `t:Postgrex.Range.t/0` or `t:Postgrex.Multirange.t/0`,
    typically produced by dumping a Tempo value and pinned with `^`.

  ### Returns

  * A query fragment usable anywhere Ecto accepts a boolean
    expression — `where`, `having`, `select`, a join condition.

  ### Semantics

  * Allen's `precedes` — the column's span ends before the probe
  begins, sharing no instant and not even touching.

  ### Examples

      from(m in Meeting, where: strictly_before(m.window, ^cutoff), select: m.name)

  > *"What finished before the cutoff?"*

  """
  defmacro strictly_before(left, right) do
    quote do
      fragment("(?).range << ?", unquote(left), unquote(right))
    end
  end

  @doc """
  Matches rows whose span lies entirely later than the given range.

  Expands to the PostgreSQL `>>` operator.

  The column's range component is unwrapped automatically, so the
  Postgres operator applies to the range rather than the composite.

  ### Arguments

  * `left` is the `range` component of a `tempo_range` / `tempo_multirange` column.

  * `right` is a `t:Postgrex.Range.t/0` or `t:Postgrex.Multirange.t/0`,
    typically produced by dumping a Tempo value and pinned with `^`.

  ### Returns

  * A query fragment usable anywhere Ecto accepts a boolean
    expression — `where`, `having`, `select`, a join condition.

  ### Semantics

  * Allen's `preceded_by` — the mirror of `strictly_before/2`.

  ### Examples

      from(m in Meeting, where: strictly_after(m.window, ^now), select: m.name)

  > *"What is still to come?"*

  """
  defmacro strictly_after(left, right) do
    quote do
      fragment("(?).range >> ?", unquote(left), unquote(right))
    end
  end
end
