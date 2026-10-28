defmodule Tempo.Ecto.QueryAPI do
  @moduledoc """
  Ecto query fragments for PostgreSQL range operators, named after
  Allen's interval algebra so queries read as English sentences.

  Each macro expands to a `fragment/2` using the corresponding
  PostgreSQL operator. The macros are `require`-able from any
  Ecto query module:

      import Ecto.Query
      import Tempo.Ecto.QueryAPI

      from m in Meeting, where: overlaps(m.window, ^iv)

  The mapping to Postgres operators:

    * `contains/2` → `@>` — whether `a` fully contains `b`.

    * `overlaps/2` → `&&` — whether `a` and `b` share any instant.
      Matches Allen's `overlaps`, `overlapped_by`, `starts`,
      `started_by`, `during`, `contains`, `finishes`,
      `finished_by`, `equals` — i.e. any non-disjoint pair.

    * `meets/2` → `-|-` — whether `a` is immediately adjacent to `b`.
      Matches Allen's `meets` and `met_by`.

    * `strictly_before/2` → `<<` — Allen's `precedes`.

    * `strictly_after/2` → `>>` — Allen's `preceded_by`.

  The right-hand operand in each macro should be a `Postgrex.Range`
  or `Postgrex.Multirange` — i.e. either a range literal or a value
  produced by dumping a `Tempo.Ecto.Interval` /
  `Tempo.Ecto.IntervalSet` field. The Ecto field type on the left
  handles the conversion automatically when you pin a Tempo value
  via `^` in the query.

  """

  @doc """
  Matches rows whose span fully contains the given range.

  Expands to the PostgreSQL `@>` operator.

  ### Arguments

  * `left` is an interval column.

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
      fragment("? @> ?", unquote(left), unquote(right))
    end
  end

  @doc """
  Matches rows whose span shares any instant with the given range.

  Expands to the PostgreSQL `&&` operator.

  ### Arguments

  * `left` is an interval column.

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
      fragment("? && ?", unquote(left), unquote(right))
    end
  end

  @doc """
  Matches rows whose span is immediately adjacent to the given range.

  Expands to the PostgreSQL `-|-` operator.

  ### Arguments

  * `left` is an interval column.

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
      fragment("? -|- ?", unquote(left), unquote(right))
    end
  end

  @doc """
  Matches rows whose span lies entirely earlier than the given range.

  Expands to the PostgreSQL `<<` operator.

  ### Arguments

  * `left` is an interval column.

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
      fragment("? << ?", unquote(left), unquote(right))
    end
  end

  @doc """
  Matches rows whose span lies entirely later than the given range.

  Expands to the PostgreSQL `>>` operator.

  ### Arguments

  * `left` is an interval column.

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
      fragment("? >> ?", unquote(left), unquote(right))
    end
  end
end
