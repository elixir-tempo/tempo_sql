defmodule Tempo.Ecto.IntervalTest do
  use ExUnit.Case, async: true

  import Tempo.Sigils

  alias Tempo.Ecto.Interval

  @default_params %{frame: :utc, resolution: :second}
  @floating_params %{frame: :floating, resolution: :second}
  @floating_params %{frame: :floating, resolution: :second}

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
      assert Interval.init([]) == %{frame: :utc, resolution: :second}
    end

    test "defaults :frame to :utc and accepts :floating" do
      assert %{frame: :utc} = Interval.init([])
      assert %{frame: :floating} = Interval.init(frame: :floating)
    end

    test "rejects a frame it does not know" do
      assert_raise ArgumentError, ~r/:local/, fn -> Interval.init(frame: :local) end
      assert_raise ArgumentError, fn -> Interval.init(frame: "floating") end
    end

    test "accepts valid resolutions" do
      for r <- [:year, :month, :day, :hour, :minute, :second] do
        assert Interval.init(resolution: r) == %{frame: :utc, resolution: r}
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
               Interval.dump(~o"2026-06-15T09:00:00Z/2026-06-15T17:00:00Z", nil, @default_params)

      assert range.lower == ~U[2026-06-15 09:00:00Z]
      assert range.upper == ~U[2026-06-15 17:00:00Z]
      assert range.lower_inclusive == true
      assert range.upper_inclusive == false
    end

    test "dumps an end written to a date as the instant after it" do
      assert {:ok, half_open(~U[2026-06-15 00:00:00Z], ~U[2026-06-21 00:00:00Z])} ==
               Interval.dump(~o"2026-06-15/2026-06-20[Etc/UTC]", nil, @default_params)
    end

    test "dumps a value as the span it denotes" do
      assert {:ok, half_open(~U[2026-01-01 00:00:00Z], ~U[2027-01-01 00:00:00Z])} ==
               Interval.dump(~o"2026[Etc/UTC]", nil, @default_params)

      assert {:ok, half_open(~U[2026-03-16 00:00:00Z], ~U[2026-03-17 00:00:00Z])} ==
               Interval.dump(~o"2026-075[Etc/UTC]", nil, @default_params)
    end

    test "dumps an open-start interval as a Range with :unbound lower" do
      assert {:ok, half_open(:unbound, ~U[2026-06-15 17:00:00Z])} ==
               Interval.dump(~o"../2026-06-15T17:00:00Z", nil, @default_params)
    end

    test "dumps an open-end interval as a Range with :unbound upper" do
      assert {:ok, half_open(~U[2026-06-15 09:00:00Z], :unbound)} ==
               Interval.dump(~o"2026-06-15T09:00:00Z/..", nil, @default_params)
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
      interval = ~o"2026-06-15T09:00:00Z/2026-06-15T17:00:00Z"

      assert {:ok, ^interval} = Interval.cast(interval, @default_params)
    end

    test "makes a value the interval it denotes" do
      assert {:ok, ~o"2026-06-15/2026-06-15"} = Interval.cast(~o"2026-06-15", @floating_params)
    end

    test "refuses a value of the other frame, in either direction" do
      assert {:error, message: message} = Interval.cast(~o"2026-06-15", @default_params)
      assert message =~ "frame: :floating"

      assert {:error, message: message} =
               Interval.cast(~o"2026-06-15T09:00Z/2026-06-15T10:00Z", @floating_params)

      assert message =~ "frame: :utc"
    end

    test "refuses a range read back on the other frame" do
      range = half_open(~N[2026-06-15 09:00:00], ~N[2026-06-15 17:00:00])

      assert {:error, message: _message} = Interval.cast(range, @default_params)

      assert {:ok, ~o"2026-06-15T09:00:00/2026-06-15T17:00:00"} =
               Interval.cast(range, @floating_params)
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

    test "a floating interval is refused on the UTC line, not stored as if it were at UTC" do
      assert :error =
               Interval.dump(~o"2026-06-15T09:00:00/2026-06-15T17:00:00", nil, @default_params)
    end

    test "a floating interval dumps and loads back floating on the floating frame" do
      original = ~o"2026-06-15T09:00:00/2026-06-15T17:00:00"

      {:ok, range} = Interval.dump(original, nil, @floating_params)

      assert {:ok, ^original} = Interval.load(range, nil, @floating_params)
    end
  end

  describe "the floating frame" do
    test "reports tsrange" do
      assert Interval.type(@floating_params) == :tsrange
    end

    test "dumps a floating interval as a Postgrex.Range of naive bounds" do
      assert {:ok, half_open(~N[2026-06-15 09:00:00], ~N[2026-06-15 17:00:00])} ==
               Interval.dump(~o"2026-06-15T09:00:00/2026-06-15T17:00:00", nil, @floating_params)
    end

    test "dumps a floating end written to a date as the instant after it" do
      assert {:ok, half_open(~N[2026-06-15 00:00:00], ~N[2026-06-21 00:00:00])} ==
               Interval.dump(~o"2026-06-15/2026-06-20", nil, @floating_params)
    end

    test "dumps a floating open end as an unbound upper" do
      assert {:ok, half_open(~N[2026-06-15 09:00:00], :unbound)} ==
               Interval.dump(~o"2026-06-15T09:00:00/..", nil, @floating_params)
    end

    test "refuses an interval at a time shift" do
      assert :error =
               Interval.dump(~o"2026-06-15T09:00:00Z/2026-06-15T17:00:00Z", nil, @floating_params)
    end

    test "refuses an interval in a zone" do
      assert :error =
               Interval.dump(
                 ~o"2026-06-15T09:00/2026-06-15T17:00[Europe/Paris]",
                 nil,
                 @floating_params
               )
    end

    test "loads a range of naive bounds as a floating interval" do
      range = half_open(~N[2026-06-15 09:00:00], ~N[2026-06-15 17:00:00])

      assert {:ok, ~o"2026-06-15T09:00:00/2026-06-15T17:00:00"} =
               Interval.load(range, nil, @floating_params)
    end

    test "normalises a closed range of naive bounds to half-open" do
      range = %Postgrex.Range{
        lower: ~N[2026-06-15 09:00:00],
        upper: ~N[2026-06-15 16:59:59],
        lower_inclusive: true,
        upper_inclusive: true
      }

      assert {:ok, ~o"2026-06-15T09:00:00/2026-06-15T17:00:00"} =
               Interval.load(range, nil, @floating_params)
    end

    test "resolution: :day reads floating days through" do
      range = half_open(~N[2026-06-15 00:00:00], ~N[2026-06-16 00:00:00])

      assert {:ok, ~o"2026-06-15/2026-06-15"} =
               Interval.load(range, nil, Interval.init(resolution: :day, frame: :floating))
    end
  end
end
