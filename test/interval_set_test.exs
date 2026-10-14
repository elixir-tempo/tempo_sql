defmodule Tempo.Ecto.IntervalSetTest do
  use ExUnit.Case, async: true

  import Tempo.Sigils

  alias Tempo.Ecto.IntervalSet

  @default_params %{resolution: :second}

  defp half_open(lower, upper),
    do: %Postgrex.Range{lower: lower, upper: upper, lower_inclusive: true, upper_inclusive: false}

  defp meetings do
    Tempo.IntervalSet.new!([
      ~o"2026-06-15T09:00:00/2026-06-15T10:00:00",
      ~o"2026-06-15T14:00:00/2026-06-15T15:00:00"
    ])
  end

  describe "type/1" do
    test "reports tstzmultirange" do
      assert IntervalSet.type(@default_params) == :tstzmultirange
    end
  end

  describe "dump/3" do
    test "dumps a set of anchored intervals as a Postgrex.Multirange" do
      assert {:ok, %Postgrex.Multirange{ranges: ranges}} =
               IntervalSet.dump(meetings(), nil, @default_params)

      assert ranges == [
               half_open(~U[2026-06-15 09:00:00Z], ~U[2026-06-15 10:00:00Z]),
               half_open(~U[2026-06-15 14:00:00Z], ~U[2026-06-15 15:00:00Z])
             ]
    end

    test "dumps a bounded recurrence as its occurrences" do
      assert {:ok, %Postgrex.Multirange{ranges: ranges}} =
               IntervalSet.dump(~o"R3/2026-06-01/P1W", nil, @default_params)

      assert Enum.map(ranges, & &1.lower) == [
               ~U[2026-06-01 00:00:00Z],
               ~U[2026-06-08 00:00:00Z],
               ~U[2026-06-15 00:00:00Z]
             ]
    end

    test "dumps a value that names several as the values it names" do
      assert {:ok, %Postgrex.Multirange{ranges: ranges}} =
               IntervalSet.dump(~o"2026Y{6,8}M", nil, @default_params)

      assert ranges == [
               half_open(~U[2026-06-01 00:00:00Z], ~U[2026-07-01 00:00:00Z]),
               half_open(~U[2026-08-01 00:00:00Z], ~U[2026-09-01 00:00:00Z])
             ]
    end

    test "refuses an empty set" do
      assert :error = IntervalSet.dump(Tempo.IntervalSet.new!([]), nil, @default_params)
    end

    test "refuses a recurrence with no end" do
      assert :error = IntervalSet.dump(~o"R/2026-06-01/P1W", nil, @default_params)
    end

    test "refuses a set with a member a tstzrange cannot hold" do
      set = Tempo.IntervalSet.new!([~o"2026-06-15T09:00:00/2026-06-15T10:00:00", ~o"1984?"])

      assert :error = IntervalSet.dump(set, nil, @default_params)
    end
  end

  describe "load/3" do
    test "loads a Postgrex.Multirange into a set" do
      multirange = %Postgrex.Multirange{
        ranges: [
          half_open(~U[2026-06-15 09:00:00Z], ~U[2026-06-15 10:00:00Z]),
          half_open(~U[2026-06-15 14:00:00Z], ~U[2026-06-15 15:00:00Z])
        ]
      }

      assert {:ok, set} = IntervalSet.load(multirange, nil, @default_params)

      assert Tempo.IntervalSet.members(set) == [
               ~o"2026-06-15T09:00:00Z/2026-06-15T10:00:00Z",
               ~o"2026-06-15T14:00:00Z/2026-06-15T15:00:00Z"
             ]
    end

    test "resolution: :day reads every member through its days" do
      multirange = %Postgrex.Multirange{
        ranges: [
          half_open(~U[2026-06-15 00:00:00Z], ~U[2026-06-16 00:00:00Z]),
          half_open(~U[2026-06-20 00:00:00Z], ~U[2026-06-22 00:00:00Z])
        ]
      }

      {:ok, set} = IntervalSet.load(multirange, nil, IntervalSet.init(resolution: :day))

      assert Tempo.IntervalSet.members(set) == [
               ~o"2026Y6M15DZ/2026Y6M15DZ",
               ~o"2026Y6M20DZ/2026Y6M21DZ"
             ]
    end
  end

  describe "cast/2" do
    test "accepts a list of intervals and makes a set of them" do
      [a, b] = Tempo.IntervalSet.members(meetings())

      assert {:ok, set} = IntervalSet.cast([a, b], @default_params)
      assert set == meetings()
    end

    test "accepts a set unchanged" do
      set = meetings()

      assert {:ok, ^set} = IntervalSet.cast(set, @default_params)
    end

    test "accepts a bounded recurrence unchanged" do
      weekly = ~o"R3/2026-06-01/P1W"

      assert {:ok, ^weekly} = IntervalSet.cast(weekly, @default_params)
    end

    test "rejects a recurrence with no end, and what is not a set" do
      assert :error = IntervalSet.cast(~o"R/2026-06-01/P1W", @default_params)
      assert :error = IntervalSet.cast("2026", @default_params)
      assert :error = IntervalSet.cast([1, 2], @default_params)
    end
  end

  describe "round-trip" do
    test "a set dumps and loads back as the same members" do
      {:ok, multirange} = IntervalSet.dump(meetings(), nil, @default_params)
      {:ok, loaded} = IntervalSet.load(multirange, nil, @default_params)

      assert Tempo.IntervalSet.members(loaded) == [
               ~o"2026-06-15T09:00:00Z/2026-06-15T10:00:00Z",
               ~o"2026-06-15T14:00:00Z/2026-06-15T15:00:00Z"
             ]
    end
  end
end
