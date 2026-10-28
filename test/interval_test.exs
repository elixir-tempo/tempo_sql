defmodule Tempo.Ecto.IntervalTest do
  use ExUnit.Case, async: true

  import Tempo.Sigils

  alias Tempo.Ecto.Interval

  @default_params %{resolution: :second}

  defp half_open(lower, upper) do
    %Postgrex.Range{lower: lower, upper: upper, lower_inclusive: true, upper_inclusive: false}
  end

  describe "type/1" do
    test "reports tstzrange" do
      assert Interval.type(@default_params) == :tstzrange
    end
  end

  describe "init/1" do
    test "defaults :resolution to :second" do
      assert Interval.init([]) == %{resolution: :second}
    end

    test "accepts valid resolutions" do
      for r <- [:year, :month, :day, :hour, :minute, :second] do
        assert Interval.init(resolution: r) == %{resolution: r}
      end
    end

    test "rejects invalid resolutions" do
      assert_raise ArgumentError, fn -> Interval.init(resolution: :century) end
      assert_raise ArgumentError, fn -> Interval.init(resolution: "year") end
    end
  end

  describe "dump/3 — the storable shape" do
    test "dumps an anchored interval as a Postgrex.Range in UTC" do
      assert {:ok, %Postgrex.Range{} = range} =
               Interval.dump(~o"2026-06-15T09:00:00/2026-06-15T17:00:00", nil, @default_params)

      assert range.lower == ~U[2026-06-15 09:00:00Z]
      assert range.upper == ~U[2026-06-15 17:00:00Z]
      assert range.lower_inclusive == true
      assert range.upper_inclusive == false
    end

    test "dumps an end written to a date as the instant after it" do
      assert {:ok, half_open(~U[2026-06-15 00:00:00Z], ~U[2026-06-21 00:00:00Z])} ==
               Interval.dump(~o"2026-06-15/2026-06-20", nil, @default_params)
    end

    test "dumps a value as the span it denotes" do
      assert {:ok, half_open(~U[2026-01-01 00:00:00Z], ~U[2027-01-01 00:00:00Z])} ==
               Interval.dump(~o"2026", nil, @default_params)

      assert {:ok, half_open(~U[2026-03-16 00:00:00Z], ~U[2026-03-17 00:00:00Z])} ==
               Interval.dump(~o"2026-075", nil, @default_params)
    end

    test "dumps an open-start interval as a Range with :unbound lower" do
      assert {:ok, half_open(:unbound, ~U[2026-06-15 17:00:00Z])} ==
               Interval.dump(~o"../2026-06-15T17:00:00", nil, @default_params)
    end

    test "dumps an open-end interval as a Range with :unbound upper" do
      assert {:ok, half_open(~U[2026-06-15 09:00:00Z], :unbound)} ==
               Interval.dump(~o"2026-06-15T09:00:00/..", nil, @default_params)
    end

    test "returns nil passthrough" do
      assert {:ok, nil} = Interval.dump(nil, nil, @default_params)
    end
  end

  describe "dump/3 — the contract refusal cases" do
    test "refuses a recurrence" do
      assert :error = Interval.dump(~o"R5/2026-06-15T09:00:00/PT1H", nil, @default_params)
    end

    test "refuses a set" do
      assert :error = Interval.dump(~o"{2026-06-15,2026-06-17}", nil, @default_params)
    end

    test "refuses a fully-unbounded interval" do
      assert :error = Interval.dump(~o"../..", nil, @default_params)
    end

    test "refuses a qualified value" do
      assert :error = Interval.dump(~o"1984?", nil, @default_params)
    end

    test "refuses a value of another calendar" do
      assert :error = Interval.dump(~o"5786-10-01[u-ca=hebrew]", nil, @default_params)
    end

    test "refuses what is not an expression" do
      assert :error = Interval.dump("not a range", nil, @default_params)
      assert :error = Interval.dump(42, nil, @default_params)
    end
  end

  describe "load/3 — default :second resolution" do
    test "loads a Postgrex.Range back into an interval in UTC" do
      range = %Postgrex.Range{
        lower: ~U[2026-06-15 09:00:00Z],
        upper: ~U[2026-06-15 17:00:00Z],
        lower_inclusive: true,
        upper_inclusive: false
      }

      assert {:ok, ~o"2026-06-15T09:00:00Z/2026-06-15T17:00:00Z"} =
               Interval.load(range, nil, @default_params)
    end

    test "loads an unbound lower as an open start" do
      range = half_open(:unbound, ~U[2026-06-15 17:00:00Z])

      assert {:ok, ~o"../2026-06-15T17:00:00Z"} = Interval.load(range, nil, @default_params)
    end

    test "returns nil passthrough" do
      assert {:ok, nil} = Interval.load(nil, nil, @default_params)
    end
  end

  describe "load/3 — :resolution writes the ends to a unit" do
    test "resolution: :year reads a year through a year" do
      range = half_open(~U[2026-01-01 00:00:00Z], ~U[2027-01-01 00:00:00Z])

      assert {:ok, ~o"2026YZ/2026YZ"} =
               Interval.load(range, nil, Interval.init(resolution: :year))
    end

    test "resolution: :month reads a month through a month" do
      range = half_open(~U[2026-06-01 00:00:00Z], ~U[2026-07-01 00:00:00Z])

      assert {:ok, ~o"2026Y6MZ/2026Y6MZ"} =
               Interval.load(range, nil, Interval.init(resolution: :month))
    end

    test "resolution: :day reads a day through a day" do
      range = half_open(~U[2026-06-15 00:00:00Z], ~U[2026-06-16 00:00:00Z])

      assert {:ok, ~o"2026Y6M15DZ/2026Y6M15DZ"} =
               Interval.load(range, nil, Interval.init(resolution: :day))
    end

    test "resolution: :hour reads the hours as boundaries" do
      range = half_open(~U[2026-06-15 09:00:00Z], ~U[2026-06-15 10:00:00Z])

      assert {:ok, ~o"2026-06-15T09Z/2026-06-15T10Z"} =
               Interval.load(range, nil, Interval.init(resolution: :hour))
    end

    test "the span loaded is the span stored" do
      range = half_open(~U[2026-06-01 00:00:00Z], ~U[2026-07-01 00:00:00Z])
      {:ok, june} = Interval.load(range, nil, Interval.init(resolution: :month))

      assert {:ok, ^range} = Interval.dump(june, nil, @default_params)
    end
  end

  describe "load/3 — bracket normalisation" do
    test "[] closed range moves the upper one second on, to [)" do
      range = %Postgrex.Range{
        lower: ~U[2026-06-15 09:00:00Z],
        upper: ~U[2026-06-15 09:59:59Z],
        lower_inclusive: true,
        upper_inclusive: true
      }

      assert {:ok, ~o"2026-06-15T09:00:00Z/2026-06-15T10:00:00Z"} =
               Interval.load(range, nil, @default_params)
    end

    test "(] range moves both ends one second on, to [)" do
      range = %Postgrex.Range{
        lower: ~U[2026-06-15 08:59:59Z],
        upper: ~U[2026-06-15 09:59:59Z],
        lower_inclusive: false,
        upper_inclusive: true
      }

      assert {:ok, ~o"2026-06-15T09:00:00Z/2026-06-15T10:00:00Z"} =
               Interval.load(range, nil, @default_params)
    end

    test "() open range moves the lower one second on, to [)" do
      range = %Postgrex.Range{
        lower: ~U[2026-06-15 08:59:59Z],
        upper: ~U[2026-06-15 10:00:00Z],
        lower_inclusive: false,
        upper_inclusive: false
      }

      assert {:ok, ~o"2026-06-15T09:00:00Z/2026-06-15T10:00:00Z"} =
               Interval.load(range, nil, @default_params)
    end
  end

  describe "cast/2 — the input-accepting surface" do
    test "accepts an interval unchanged" do
      interval = ~o"2026-06-15T09:00:00/2026-06-15T17:00:00"

      assert {:ok, ^interval} = Interval.cast(interval, @default_params)
    end

    test "makes a value the interval it denotes" do
      assert {:ok, ~o"2026-06-15/2026-06-15"} = Interval.cast(~o"2026-06-15", @default_params)
    end

    test "accepts a Postgrex.Range" do
      range = half_open(~U[2026-06-15 09:00:00Z], ~U[2026-06-15 17:00:00Z])

      assert {:ok, ~o"2026-06-15T09:00:00Z/2026-06-15T17:00:00Z"} =
               Interval.cast(range, @default_params)
    end

    test "rejects an expression of more than one span" do
      assert :error = Interval.cast(~o"{2026-06-15,2026-06-17}", @default_params)
      assert :error = Interval.cast(~o"R5/2026-06-15T09:00:00/PT1H", @default_params)
    end

    test "rejects unknown input" do
      assert :error = Interval.cast("2026", @default_params)
      assert :error = Interval.cast(%{random: "map"}, @default_params)
    end
  end

  describe "round-trip" do
    test "an anchored interval dumps and loads back as the same span" do
      original = ~o"2026-06-15T09:00:00Z/2026-06-15T17:00:00Z"

      {:ok, range} = Interval.dump(original, nil, @default_params)

      assert {:ok, ^original} = Interval.load(range, nil, @default_params)
    end

    test "a floating interval is stored as if it were in UTC" do
      {:ok, range} =
        Interval.dump(~o"2026-06-15T09:00:00/2026-06-15T17:00:00", nil, @default_params)

      assert {:ok, ~o"2026-06-15T09:00:00Z/2026-06-15T17:00:00Z"} =
               Interval.load(range, nil, @default_params)
    end
  end
end
