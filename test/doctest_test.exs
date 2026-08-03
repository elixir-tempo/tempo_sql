defmodule Tempo.SQL.DoctestTest do
  @moduledoc """
  Runs the documented examples. Every `### Examples` section that can
  execute without a database is a doctest, so the documentation is
  checked against the code on every run rather than drifting from it.

  The Ecto callbacks (`cast/2`, `load/3`, `dump/3`, …) are documented
  by the `Ecto.ParameterizedType` behaviour and hidden by ex_doc, so
  they carry no examples of their own; the query-API and migration
  macros need a repo or a migration runner and are documented with
  illustrative snippets instead.
  """

  use ExUnit.Case, async: true

  import Tempo.Sigils

  doctest Tempo.SQL
  doctest Tempo.SQL.Conversion
  doctest Tempo.SQL.JSON
  doctest Tempo.SQL.Meta
  doctest Tempo.Ecto.Interval
  doctest Tempo.Ecto.IntervalSet
  doctest Tempo.Ecto.Tempo
  doctest Tempo.Ecto.TempoRange
  doctest Tempo.Ecto.TempoMultirange
end
