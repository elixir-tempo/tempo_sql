defmodule Tempo.SQL do
  @moduledoc """
  Top-level namespace for `ex_tempo_sql` — Ecto types, query macros and
  migration helpers that store Tempo expressions as PostgreSQL ranges and
  multiranges.

  See the README for the installation walkthrough and the storage
  contract that spells out which Tempo values round-trip cleanly.

  The entry-point modules are:

    * `Tempo.Ecto.Interval` — stores an expression of one span (a
      value, or an interval) as `tstzrange`.

    * `Tempo.Ecto.IntervalSet` — stores an expression with a last span
      (a set, a bounded recurrence, a value that names several) as
      `tstzmultirange`, one range a span.

    * `Tempo.Ecto.Tempo` — `Tempo.Ecto.Interval` under the name it had
      for a bare value, kept so that schemas naming it go on working.

    * `Tempo.Ecto.TempoRange` and `Tempo.Ecto.TempoMultirange` — store
      any expression losslessly, as the span it covers (or the spans)
      beside its ISO 8601 text.

    * `Tempo.SQL.Migration` — `add_interval/2`, `add_interval_set/2`,
      the composite columns and their types, for Ecto migrations.

    * `Tempo.SQL.PostgresTypes` — the Postgrex types a repository with
      composite columns names, encoding `jsonb` with Erlang's `:json`.

    * `Tempo.Ecto.QueryAPI` and `Tempo.Ecto.QueryAPI.Composite` —
      Allen-named query fragments (`contains/2`, `overlaps/2`, `meets/2`,
      `strictly_before/2`, `strictly_after/2`) backed by Postgres range
      operators.

  """
end
