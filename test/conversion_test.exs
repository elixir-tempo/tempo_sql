defmodule Tempo.SQL.ConversionTest do
  @moduledoc """
  `Conversion` is the boundary between Tempo values and Postgres
  ranges, and most of what was untested is the half of it that says
  *no*: the values a `tstzrange` cannot represent, and the bracket
  normalisation that turns whatever Postgres hands back into the
  half-open form Tempo requires.
  """

  use ExUnit.Case, async: true

  import Tempo.Sigils

  alias Tempo.Interval
  alias Tempo.SQL.Conversion
  alias Tempo.SQL.UnsupportedValueError

  defp interval(from, to) do
    Interval.new!(from: Tempo.from_iso8601!(from), to: Tempo.from_iso8601!(to))
  end

  describe "valid_resolutions/0 and validate_resolution!/1" do
    test "the advertised resolutions all validate" do
      for resolution <- Conversion.valid_resolutions() do
        assert Conversion.validate_resolution!(resolution) == resolution
      end
    end

    test "anything else raises, naming what was given" do
      assert_raise ArgumentError, ~r/fortnight/, fn ->
        Conversion.validate_resolution!(:fortnight)
      end
    end
  end

  describe "interval_to_range/1" do
    test "converts a bounded interval to a half-open range" do
      assert {:ok, range} = Conversion.interval_to_range(interval("2027-06-15", "2027-06-16"))

      assert range.lower_inclusive == true
      assert range.upper_inclusive == false
    end

    test "an open start becomes an unbounded lower endpoint" do
      {:ok, open} =
        Interval.new(from: :undefined, to: Tempo.from_iso8601!("2027-06-15T17:00:00"))

      assert {:ok, range} = Conversion.interval_to_range(open)
      assert range.lower == :unbound
    end

    test "an open end becomes an unbounded upper endpoint" do
      {:ok, open} =
        Interval.new(from: Tempo.from_iso8601!("2027-06-15T09:00:00"), to: :undefined)

      assert {:ok, range} = Conversion.interval_to_range(open)
      assert range.upper == :unbound
    end
  end

  describe "interval_to_queryable_range/1 rejects what a range cannot hold" do
    test "a duration endpoint has no position on the time line" do
      unpositioned = %Tempo.Interval{from: ~o"2027-06-15T09:00:00", to: ~o"PT1H"}

      assert {:error, %UnsupportedValueError{}} =
               Conversion.interval_to_queryable_range(unpositioned)
    end

    test "the error says which value it could not convert" do
      unpositioned = %Tempo.Interval{from: ~o"2027-06-15T09:00:00", to: ~o"PT1H"}

      {:error, exception} = Conversion.interval_to_queryable_range(unpositioned)

      assert Exception.message(exception) =~ "Tempo.Duration"
    end

    test "a recurring interval converts to its first occurrence, open-ended" do
      # A recurrence has a start but no single end, so the queryable
      # range is unbounded above rather than an error — a query can
      # still ask "does anything from this recurrence fall here?"
      {:ok, recurring} = Tempo.from_iso8601("R5/2027-06-15/P1D")

      assert {:ok, range} = Conversion.interval_to_queryable_range(recurring)
      assert range.upper == :unbound
      assert range.lower == ~U[2027-06-15 00:00:00Z]
    end
  end

  describe "range_to_interval/2 normalises whatever Postgres returns" do
    defp range(lower, upper, lower_inclusive, upper_inclusive) do
      %Postgrex.Range{
        lower: lower,
        upper: upper,
        lower_inclusive: lower_inclusive,
        upper_inclusive: upper_inclusive
      }
    end

    test "a canonical [) range converts directly" do
      canonical =
        range(~U[2027-06-15 09:00:00Z], ~U[2027-06-15 10:00:00Z], true, false)

      assert {:ok, %Tempo.Interval{} = interval} = Conversion.range_to_interval(canonical)
      assert Tempo.hour(interval.from) == 9
      assert Tempo.hour(interval.to) == 10
    end

    test "an exclusive lower bound is shifted in to become inclusive" do
      # `(09:00, 10:00)` means the same instants as `[09:00:01, 10:00)`.
      exclusive = range(~U[2027-06-15 09:00:00Z], ~U[2027-06-15 10:00:00Z], false, false)

      {:ok, interval} = Conversion.range_to_interval(exclusive)

      assert Tempo.second(interval.from) == 1
    end

    test "an inclusive upper bound is shifted out to become exclusive" do
      # `[09:00, 10:00]` means the same instants as `[09:00, 10:00:01)`.
      inclusive = range(~U[2027-06-15 09:00:00Z], ~U[2027-06-15 10:00:00Z], true, true)

      {:ok, interval} = Conversion.range_to_interval(inclusive)

      assert Tempo.second(interval.to) == 1
    end

    test "an unbounded lower endpoint stays open" do
      open = range(:unbound, ~U[2027-06-15 10:00:00Z], false, false)

      assert {:ok, %Tempo.Interval{from: :undefined}} = Conversion.range_to_interval(open)
    end

    test "an unbounded upper endpoint stays open" do
      open = range(~U[2027-06-15 09:00:00Z], :unbound, true, false)

      assert {:ok, %Tempo.Interval{to: :undefined}} = Conversion.range_to_interval(open)
    end

    test "a nil endpoint is treated as unbounded" do
      open = range(nil, ~U[2027-06-15 10:00:00Z], false, false)

      assert {:ok, %Tempo.Interval{from: :undefined}} = Conversion.range_to_interval(open)
    end
  end

  describe "range_to_interval/2 with a declared resolution" do
    test "truncates the endpoints to the column's resolution" do
      spans_two_years = %Postgrex.Range{
        lower: ~U[2027-06-15 09:30:45Z],
        upper: ~U[2028-06-15 10:30:45Z],
        lower_inclusive: true,
        upper_inclusive: false
      }

      {:ok, interval} = Conversion.range_to_interval(spans_two_years, resolution: :year)

      # A year-resolution column asserts its contents are years.
      assert Keyword.keys(interval.from.time) == [:year]
      assert Tempo.year(interval.from) == 2027
      assert Tempo.year(interval.to) == 2028
    end

    test "a resolution coarser than the data collapses the span, and is refused" do
      # An hour-long range truncated to years puts both endpoints in
      # 2027, and a zero-extent interval is not valid under the
      # half-open convention. Better to fail than to load a span that
      # covers nothing.
      one_hour = %Postgrex.Range{
        lower: ~U[2027-06-15 09:30:45Z],
        upper: ~U[2027-06-15 10:30:45Z],
        lower_inclusive: true,
        upper_inclusive: false
      }

      assert {:error, %Tempo.IntervalEndpointsError{}} =
               Conversion.range_to_interval(one_hour, resolution: :year)
    end

    test "second resolution keeps the full precision" do
      precise = %Postgrex.Range{
        lower: ~U[2027-06-15 09:30:45Z],
        upper: ~U[2027-06-15 10:30:45Z],
        lower_inclusive: true,
        upper_inclusive: false
      }

      {:ok, interval} = Conversion.range_to_interval(precise, resolution: :second)

      assert Tempo.second(interval.from) == 45
    end
  end

  describe "truncate_tempo/2" do
    test "drops everything finer than the given resolution" do
      truncated = Conversion.truncate_tempo(~o"2027-06-15T09:30:45", :day)

      assert Keyword.keys(truncated.time) == [:year, :month, :day]
    end

    test "a resolution finer than the value leaves it unchanged" do
      value = ~o"2027Y"

      assert Conversion.truncate_tempo(value, :second) == value
    end
  end
end
