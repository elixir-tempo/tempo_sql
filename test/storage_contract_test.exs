defmodule Tempo.SQL.StorageContractTest do
  @moduledoc """
  The plain-range types promise to refuse what a `tstzrange` cannot
  hold rather than store a lossy approximation of it. These are the
  teeth of that promise: the shapes that are turned away, and the ones
  that look like they should be turned away but are not.
  """

  use ExUnit.Case, async: true

  alias Tempo.Interval
  alias Tempo.SQL.Conversion
  alias Tempo.SQL.UnsupportedValueError

  defp spanning(from, to) do
    %Tempo.Interval{from: Tempo.from_iso8601!(from), to: Tempo.from_iso8601!(to)}
  end

  describe "what a tstzrange refuses to hold" do
    test "a qualified endpoint, because the doubt cannot be stored" do
      # `1984?` means "1984, uncertain". A range has nowhere to put the
      # question mark, so storing it would silently assert certainty.
      assert {:error, %UnsupportedValueError{}} =
               Conversion.interval_to_range(spanning("1984?", "2004"))
    end

    test "an approximate endpoint, for the same reason" do
      assert {:error, %UnsupportedValueError{}} =
               Conversion.interval_to_range(spanning("1984", "2004~"))
    end

    test "a non-Gregorian calendar, because the range is Gregorian" do
      assert {:error, %UnsupportedValueError{}} =
               Conversion.interval_to_range(
                 spanning("2026-01-01[u-ca=hebrew]", "2027-01-01[u-ca=hebrew]")
               )
    end

    test "an endpoint with no day, because a range endpoint is an instant" do
      # `2026-W23` is a whole week — it names no single day, so there is
      # no instant to anchor the endpoint to.
      assert {:error, %UnsupportedValueError{}} =
               Conversion.interval_to_range(spanning("2026-W23", "2026-W25"))
    end

    test "the error says why, and keeps the value it refused" do
      {:error, exception} = Conversion.interval_to_range(spanning("1984?", "2004"))

      assert exception.reason == :qualification
      assert exception.value == :uncertain
      assert Exception.message(exception) =~ "uncertain"
    end

    test "each refusal carries its own reason" do
      refusals = [
        {spanning("2026-01-01[u-ca=hebrew]", "2027-01-01[u-ca=hebrew]"), :non_gregorian_calendar},
        {spanning("2026-W23", "2026-W25"), :partial_resolution}
      ]

      for {interval, reason} <- refusals do
        assert {:error, %UnsupportedValueError{reason: ^reason}} =
                 Conversion.interval_to_range(interval)
      end
    end
  end

  describe "what looks refusable but is not" do
    test "an ordinal date, because Tempo resolves it to a calendar day" do
      # `2026-181` is the 181st day of 2026, which Tempo normalises to
      # 2026-06-30 while parsing. By the time storage sees it, it is an
      # ordinary date.
      assert {:ok, %Postgrex.Range{}} =
               Conversion.interval_to_range(spanning("2026-181", "2026-182"))
    end

    test "a week date naming a day, for the same reason" do
      assert {:ok, %Postgrex.Range{}} =
               Conversion.interval_to_range(spanning("2026-W23-4", "2026-W23-5"))
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

    test "a naive range loads like a zoned one" do
      assert {:ok, interval} = Conversion.range_to_interval(naive_range(true, false))

      assert Tempo.hour(interval.from) == 9
      assert Tempo.hour(interval.to) == 10
    end

    test "naive endpoints are bracket-normalised the same way" do
      # `(09:00, 10:00]` shifts both ends inward/outward by a second.
      assert {:ok, interval} = Conversion.range_to_interval(naive_range(false, true))

      assert Tempo.second(interval.from) == 1
      assert Tempo.second(interval.to) == 1
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

  describe "an open interval is queryable" do
    test "an undefined endpoint becomes an unbounded range bound" do
      {:ok, open} =
        Interval.new(from: Tempo.from_iso8601!("2027-06-15T09:00:00"), to: :undefined)

      assert {:ok, range} = Conversion.interval_to_queryable_range(open)
      assert range.upper == :unbound
    end
  end
end
