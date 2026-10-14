defmodule Tempo.SQL do
  @moduledoc """
  Top-level namespace for `ex_tempo_sql` — Ecto types and migration
  helpers that persist Tempo values as PostgreSQL range types.

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

    * `Tempo.SQL.Migration` — `add :window, Tempo.Interval` helper
      for Ecto migrations.

    * `Tempo.Ecto.QueryAPI` — Allen-named query fragments
      (`contains/2`, `overlaps/2`, `meets/2`) backed by Postgres
      range operators.

  """
end
