defmodule Tempo.SQL.StorageContractTest do
  @moduledoc """
  The plain-range types promise to refuse what a `tstzrange` cannot
  hold rather than store a lossy approximation of it. These are the
  teeth of that promise: the shapes that are turned away, and the ones
  that look like they should be turned away but are not.
  """

  use ExUnit.Case, async: true

  import Tempo.Sigils

  alias Tempo.SQL.Conversion
  alias Tempo.SQL.UnsupportedValueError

  defp stored(expression) do
    {:ok, range} = Conversion.interval_to_range(expression)
    {range.lower, range.upper}
  end

  describe "what a tstzrange refuses to hold" do
    test "a qualified end, because the doubt cannot be stored" do
      # `1984?` means "1984, uncertain". A range has nowhere to put the
      # question mark, so storing it would silently assert certainty.
      assert {:error, %UnsupportedValueError{}} = Conversion.interval_to_range(~o"1984?/2004")
    end

    test "an approximate end, for the same reason" do
      assert {:error, %UnsupportedValueError{}} = Conversion.interval_to_range(~o"1984/2004~")
    end

    test "a non-Gregorian calendar, because the range is Gregorian" do
      assert {:error, %UnsupportedValueError{}} =
               Conversion.interval_to_range(~o"5786-01-01/5786-06-01[u-ca=hebrew]")
    end

    test "a time of day with no date, because a range bound is an instant" do
      assert {:error, %UnsupportedValueError{}} = Conversion.interval_to_range(~o"T09/T17")
    end

    test "a value that names several, because a range is one span" do
      assert {:error, %UnsupportedValueError{}} = Conversion.interval_to_range(~o"2026Y{6,8}M")
    end

    test "the error says why, and keeps the value it refused" do
      {:error, exception} = Conversion.interval_to_range(~o"1984?/2004")

      assert exception.reason == :qualification
      assert exception.value == ~o"1984?/2004"
      assert Exception.message(exception) =~ "uncertain"
    end

    test "each refusal carries its own reason" do
      refusals = [
        {~o"5786-01-01/5786-06-01[u-ca=hebrew]", :non_gregorian_calendar},
        {~o"T09/T17", :partial_resolution},
        {~o"2026Y{6,8}M", :multi_valued_slot},
        {~o"../..", :fully_unbounded}
      ]

      for {expression, reason} <- refusals do
        assert {:error, %UnsupportedValueError{reason: ^reason}} =
                 Conversion.interval_to_range(expression)
      end
    end
  end

  describe "what looks refusable but is not" do
    test "an ordinal date is the day it names" do
      assert stored(~o"2026-181/2026-182") == {~U[2026-06-30 00:00:00Z], ~U[2026-07-02 00:00:00Z]}
    end

    test "a week date naming a day is that day" do
      assert stored(~o"2026-W23-4/2026-W23-5") ==
               {~U[2026-06-04 00:00:00Z], ~U[2026-06-06 00:00:00Z]}
    end

    test "a week is the seven days from its Monday" do
      # 2026-W23 begins on Monday the 1st of June; through W25 is three
      # weeks, to the 22nd.
      assert stored(~o"2026-W23/2026-W25") == {~U[2026-06-01 00:00:00Z], ~U[2026-06-22 00:00:00Z]}
      assert Date.beginning_of_week(~D[2026-06-04]) == ~D[2026-06-01]
    end

    test "a month is its days, read through" do
      assert stored(~o"2026-02/2026-03") == {~U[2026-02-01 00:00:00Z], ~U[2026-04-01 00:00:00Z]}
    end
  end

  describe "endpoints arriving as NaiveDateTime" do
    # Postgres hands back naive timestamps for a `tstzrange` when the
    # connection has no time zone configured, so both shapes must load.
    defp naive_range(lower_inclusive, upper_inclusive) do
      %Postgrex.Range{
        lower: ~N[2027-06-15 09:00:00],
        upper: ~N[2027-06-15 10:00:00],
        lower_inclusive: lower_inclusive,
        upper_inclusive: upper_inclusive
      }
    end

    test "a naive range loads as a floating interval" do
      assert {:ok, ~o"2027-06-15T09:00:00/2027-06-15T10:00:00"} =
               Conversion.range_to_interval(naive_range(true, false))
    end

    test "naive endpoints are bracket-normalised the same way" do
      # `(09:00, 10:00]` moves both ends one second on.
      assert {:ok, ~o"2027-06-15T09:00:01/2027-06-15T10:00:01"} =
               Conversion.range_to_interval(naive_range(false, true))
    end
  end

  describe "endpoints that are not times at all" do
    test "an unrecognised endpoint is refused rather than guessed at" do
      nonsense = %Postgrex.Range{
        lower: :bogus,
        upper: :bogus,
        lower_inclusive: true,
        upper_inclusive: false
      }

      assert {:error, %UnsupportedValueError{}} = Conversion.range_to_interval(nonsense)
    end
  end

  describe "a queryable range is the stretch an expression covers" do
    defp queryable(expression) do
      {:ok, range} = Conversion.interval_to_queryable_range(expression)
      {range.lower, range.upper}
    end

    test "an open end is an unbounded range bound" do
      assert queryable(~o"2027-06-15T09:00:00/..") == {~U[2027-06-15 09:00:00Z], :unbound}
      assert queryable(~o"../2027-06-15") == {:unbound, ~U[2027-06-16 00:00:00Z]}
    end

    test "a recurrence runs from its first occurrence to the end of its last" do
      assert queryable(~o"R5/2022-01-01/P1M") ==
               {~U[2022-01-01 00:00:00Z], ~U[2022-06-01 00:00:00Z]}
    end

    test "a recurrence with no end runs on from its first occurrence" do
      assert queryable(~o"R/2022-01-01/P1M") == {~U[2022-01-01 00:00:00Z], :unbound}
    end

    test "a set runs from its earliest member to its latest, in any order" do
      assert queryable(~o"{2026-06,2026-01}") ==
               {~U[2026-01-01 00:00:00Z], ~U[2026-07-01 00:00:00Z]}

      assert queryable(~o"{2026,2028/..}") == {~U[2026-01-01 00:00:00Z], :unbound}
    end

    test "a qualified expression is stored at the span it qualifies" do
      assert queryable(~o"1984?/2004~") == {~U[1984-01-01 00:00:00Z], ~U[2005-01-01 00:00:00Z]}
    end

    test "what has no place to query is refused" do
      for expression <- [~o"T09/T17", ~o"../..", ~o"R/P1W/2026-06-01", ~o"PT1H"] do
        assert {^expression, {:error, %UnsupportedValueError{}}} =
                 {expression, Conversion.interval_to_queryable_range(expression)}
      end
    end
  end
end
