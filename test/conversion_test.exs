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

  alias Tempo.SQL.Conversion
  alias Tempo.SQL.UnsupportedValueError

  defp range(lower, upper, lower_inclusive, upper_inclusive) do
    %Postgrex.Range{
      lower: lower,
      upper: upper,
      lower_inclusive: lower_inclusive,
      upper_inclusive: upper_inclusive
    }
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

  describe "valid_frames/0 and validate_frame!/1" do
    test "the advertised frames all validate, the UTC line first" do
      assert [:utc | _] = Conversion.valid_frames()

      for frame <- Conversion.valid_frames() do
        assert Conversion.validate_frame!(frame) == frame
      end
    end

    test "anything else raises, naming what was given" do
      assert_raise ArgumentError, ~r/:local/, fn ->
        Conversion.validate_frame!(:local)
      end
    end
  end

  describe "interval_to_range/2" do
    test "converts a bounded interval to a half-open range" do
      assert {:ok, range} = Conversion.interval_to_range(~o"2027-06-15/2027-06-16[Etc/UTC]")

      assert range == range(~U[2027-06-15 00:00:00Z], ~U[2027-06-17 00:00:00Z], true, false)
    end

    test "an open start becomes an unbounded lower endpoint" do
      assert {:ok, range} = Conversion.interval_to_range(~o"../2027-06-15T17:00:00Z")
      assert range.lower == :unbound
    end

    test "an open end becomes an unbounded upper endpoint" do
      assert {:ok, range} = Conversion.interval_to_range(~o"2027-06-15T09:00:00Z/..")
      assert range.upper == :unbound
    end

    test "an end given as a duration is the instant it reaches" do
      assert {:ok, range} = Conversion.interval_to_range(~o"2027-06-15T09:00:00Z/PT1H")
      assert range.upper == ~U[2027-06-15 10:00:00Z]
    end
  end

  describe "interval_to_range/2 on the floating frame" do
    test "converts a floating interval to a half-open range of naive bounds" do
      assert {:ok, range} = Conversion.interval_to_range(~o"2027-06-15/2027-06-16", :floating)

      assert range == range(~N[2027-06-15 00:00:00], ~N[2027-06-17 00:00:00], true, false)
    end

    test "a floating interval is refused on the UTC line" do
      assert {:error, %UnsupportedValueError{reason: :frame}} =
               Conversion.interval_to_range(~o"2027-06-15T09:00:00/2027-06-15T10:00:00")
    end

    test "an interval in a zone is refused on the floating frame" do
      assert {:error, %UnsupportedValueError{reason: :frame}} =
               Conversion.interval_to_range(~o"2027-06-15/2027-06-16[Europe/Paris]", :floating)
    end

    test "an interval at a time shift is refused on the floating frame" do
      assert {:error, %UnsupportedValueError{reason: :frame}} =
               Conversion.interval_to_range(
                 ~o"2027-06-15T09:00:00+02:00/2027-06-15T10:00:00+02:00",
                 :floating
               )
    end

    test "an open end on the floating frame is unbounded" do
      assert {:ok, range} = Conversion.interval_to_range(~o"2027-06-15T09:00:00/..", :floating)

      assert {range.lower, range.upper} == {~N[2027-06-15 09:00:00], :unbound}
    end
  end

  describe "interval_to_queryable_range/2" do
    test "a duration alone has no position on the time line" do
      assert {:error, %UnsupportedValueError{} = exception} =
               Conversion.interval_to_queryable_range(~o"PT1H")

      assert Exception.message(exception) =~ "Tempo.Duration"
    end

    test "a recurrence runs from its first occurrence to the end of its last" do
      assert {:ok, range} = Conversion.interval_to_queryable_range(~o"R5/2027-06-15/P1D[Etc/UTC]")

      assert {range.lower, range.upper} == {~U[2027-06-15 00:00:00Z], ~U[2027-06-20 00:00:00Z]}
    end

    test "a recurrence with no end is unbounded above" do
      # A query can still ask "does anything of this recurrence fall here?"
      assert {:ok, range} = Conversion.interval_to_queryable_range(~o"R/2027-06-15/P1D[Etc/UTC]")

      assert {range.lower, range.upper} == {~U[2027-06-15 00:00:00Z], :unbound}
    end

    test "a set runs from the member that starts first at UTC, whatever its time shift" do
      # Nine in the morning at +10:00 is eleven the night before at UTC.
      set = ~o"{2027-06-15T09:00+10:00,2027-06-15T02:00Z}"
      assert {:ok, range} = Conversion.interval_to_queryable_range(set)

      assert {range.lower, range.upper} == {~U[2027-06-14 23:00:00Z], ~U[2027-06-15 02:01:00Z]}
    end

    test "a set with a member open at its end is unbounded above" do
      assert {:ok, range} =
               Conversion.interval_to_queryable_range(~o"{2027-06-15/..,2027-06-01}[Etc/UTC]")

      assert {range.lower, range.upper} == {~U[2027-06-01 00:00:00Z], :unbound}
    end

    test "a floating recurrence runs on the floating frame, with naive bounds" do
      assert {:ok, range} =
               Conversion.interval_to_queryable_range(~o"R5/2027-06-15/P1D", :floating)

      assert {range.lower, range.upper} == {~N[2027-06-15 00:00:00], ~N[2027-06-20 00:00:00]}
    end

    test "a floating recurrence is refused on the UTC line" do
      assert {:error, %UnsupportedValueError{reason: :frame}} =
               Conversion.interval_to_queryable_range(~o"R5/2027-06-15/P1D")
    end

    test "a set in a zone is refused on the floating frame" do
      assert {:error, %UnsupportedValueError{reason: :frame}} =
               Conversion.interval_to_queryable_range(
                 ~o"{2027-06-15,2027-06-20}[Europe/Paris]",
                 :floating
               )
    end
  end

  describe "range_to_interval/2 normalises whatever Postgres returns" do
    test "a canonical [) range converts directly" do
      canonical = range(~U[2027-06-15 09:00:00Z], ~U[2027-06-15 10:00:00Z], true, false)

      assert {:ok, ~o"2027-06-15T09:00:00Z/2027-06-15T10:00:00Z"} =
               Conversion.range_to_interval(canonical)
    end

    test "an exclusive lower bound is moved in to become inclusive" do
      # `(09:00, 10:00)` means the same instants as `[09:00:01, 10:00)`.
      exclusive = range(~U[2027-06-15 09:00:00Z], ~U[2027-06-15 10:00:00Z], false, false)

      assert {:ok, ~o"2027-06-15T09:00:01Z/2027-06-15T10:00:00Z"} =
               Conversion.range_to_interval(exclusive)
    end

    test "an inclusive upper bound is moved out to become exclusive" do
      # `[09:00, 10:00]` means the same instants as `[09:00, 10:00:01)`.
      inclusive = range(~U[2027-06-15 09:00:00Z], ~U[2027-06-15 10:00:00Z], true, true)

      assert {:ok, ~o"2027-06-15T09:00:00Z/2027-06-15T10:00:01Z"} =
               Conversion.range_to_interval(inclusive)
    end

    test "an unbounded lower endpoint stays open" do
      open = range(:unbound, ~U[2027-06-15 10:00:00Z], false, false)

      assert {:ok, ~o"../2027-06-15T10:00:00Z"} = Conversion.range_to_interval(open)
    end

    test "an unbounded upper endpoint stays open" do
      open = range(~U[2027-06-15 09:00:00Z], :unbound, true, false)

      assert {:ok, ~o"2027-06-15T09:00:00Z/.."} = Conversion.range_to_interval(open)
    end

    test "a nil endpoint is treated as unbounded" do
      open = range(nil, ~U[2027-06-15 10:00:00Z], false, false)

      assert {:ok, ~o"../2027-06-15T10:00:00Z"} = Conversion.range_to_interval(open)
    end
  end

  describe "range_to_interval/2 with naive bounds" do
    test "a range of naive bounds loads as a floating interval" do
      floating = range(~N[2027-06-15 09:00:00], ~N[2027-06-15 10:00:00], true, false)

      assert {:ok, ~o"2027-06-15T09:00:00/2027-06-15T10:00:00"} =
               Conversion.range_to_interval(floating)
    end

    test "naive bounds are normalised to half-open as UTC bounds are" do
      # `(09:00, 10:00]` means the same instants as `[09:00:01, 10:00:01)`.
      closed_above = range(~N[2027-06-15 09:00:00], ~N[2027-06-15 10:00:00], false, true)

      assert {:ok, ~o"2027-06-15T09:00:01/2027-06-15T10:00:01"} =
               Conversion.range_to_interval(closed_above)
    end

    test "a floating interval round-trips through the floating frame" do
      opening_hours = ~o"2027-06-15T09:00:00/2027-06-15T17:00:00"

      assert {:ok, range} = Conversion.interval_to_range(opening_hours, :floating)
      assert {:ok, ^opening_hours} = Conversion.range_to_interval(range)
    end
  end

  describe "range_to_interval/2 with a declared resolution" do
    test "writes the ends to the column's resolution, the last year through" do
      spans_a_year = range(~U[2027-01-01 00:00:00Z], ~U[2028-01-01 00:00:00Z], true, false)

      # A year-resolution column asserts its contents are years.
      assert {:ok, ~o"2027YZ/2027YZ"} =
               Conversion.range_to_interval(spans_a_year, resolution: :year)
    end

    test "a resolution coarser than the data collapses the span, and is refused" do
      # An hour-long range written to the year begins in 2027 and ends
      # through 2026, which is no span. Better to fail than to load a
      # span that covers nothing.
      one_hour = range(~U[2027-06-15 09:30:45Z], ~U[2027-06-15 10:30:45Z], true, false)

      assert {:error, %Tempo.IntervalEndpointsError{}} =
               Conversion.range_to_interval(one_hour, resolution: :year)
    end

    test "second resolution keeps the full precision" do
      precise = range(~U[2027-06-15 09:30:45Z], ~U[2027-06-15 10:30:45Z], true, false)

      assert {:ok, ~o"2027-06-15T09:30:45Z/2027-06-15T10:30:45Z"} =
               Conversion.range_to_interval(precise, resolution: :second)
    end
  end

  describe "truncate_tempo/2" do
    test "drops everything finer than the given resolution" do
      assert Conversion.truncate_tempo(~o"2027-06-15T09:30:45", :day) == ~o"2027-06-15"
    end

    test "a resolution finer than the value leaves it unchanged" do
      assert Conversion.truncate_tempo(~o"2027Y", :second) == ~o"2027Y"
    end
  end

  describe "a frame that is none" do
    test "is an ArgumentError from both encoders, not a crash" do
      assert {:error, %ArgumentError{} = error} =
               Conversion.interval_to_range(~o"2027-06-15T09:00Z/2027-06-15T10:00Z", :local)

      assert Exception.message(error) =~ ":local"

      assert {:error, %ArgumentError{}} =
               Conversion.interval_to_queryable_range(
                 ~o"2027-06-15T09:00Z/2027-06-15T10:00Z",
                 :local
               )
    end
  end
end
