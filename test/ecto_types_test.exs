defmodule Tempo.SQL.EctoTypesTest do
  @moduledoc """
  The Ecto callbacks — `cast/2`, `load/3`, `dump/3`, `type/1`, `init/1`
  — are pure functions over values, so they can be exercised without a
  database. These cover the paths the round-trip tests never reach:
  `nil`, wrong types, and the error returns Ecto relies on to reject
  bad data before it gets near a query.
  """

  use ExUnit.Case, async: true

  import Tempo.Sigils

  alias Tempo.Ecto.Interval, as: IntervalType
  alias Tempo.Ecto.IntervalSet, as: IntervalSetType
  alias Tempo.Ecto.Tempo, as: TempoType
  alias Tempo.Ecto.TempoMultirange
  alias Tempo.Ecto.TempoRange

  @second %{resolution: :second}

  defp interval do
    Tempo.Interval.new!(
      from: Tempo.from_iso8601!("2027-06-15T09:00:00"),
      to: Tempo.from_iso8601!("2027-06-15T10:00:00")
    )
  end

  defp interval_set do
    Tempo.IntervalSet.new!([interval()])
  end

  describe "type/1 declares the underlying column" do
    test "each type maps to the Postgres type it documents" do
      assert IntervalType.type(@second) == :tstzrange
      assert IntervalSetType.type(@second) == :tstzmultirange
      assert TempoType.type(@second) == :tstzrange
      assert TempoRange.type(@second) == :tempo_range
      assert TempoMultirange.type(@second) == :tempo_multirange
    end
  end

  describe "init/1 validates the :resolution option" do
    test "defaults to second resolution" do
      assert IntervalType.init([]) == %{resolution: :second}
      assert TempoRange.init([]) == %{resolution: :second}
    end

    test "accepts a declared resolution" do
      assert IntervalType.init(resolution: :year) == %{resolution: :year}
      assert TempoMultirange.init(resolution: :day) == %{resolution: :day}
    end

    test "rejects a resolution that is not a time unit" do
      assert_raise ArgumentError, fn -> IntervalType.init(resolution: :fortnight) end
    end
  end

  describe "cast/2" do
    test "nil casts to nil for every type" do
      for type <- [IntervalType, IntervalSetType, TempoType, TempoRange, TempoMultirange] do
        assert type.cast(nil, @second) == {:ok, nil}
      end
    end

    test "an interval casts to itself" do
      assert IntervalType.cast(interval(), @second) == {:ok, interval()}
      assert TempoRange.cast(interval(), @second) == {:ok, interval()}
    end

    test "a bare Tempo materialises to its implicit span" do
      assert {:ok, %Tempo.Interval{} = cast} = TempoRange.cast(~o"2027Y", @second)
      assert Tempo.to_iso8601(cast.from) == "2027Y"
    end

    test "a Tempo that materialises to a set is rejected by a single-range type" do
      # A one-of set spans several disjoint intervals, which a single
      # `tstzrange` column cannot hold.
      {:ok, disjoint} = Tempo.from_iso8601("{2027,2029}Y")

      assert TempoRange.cast(disjoint, @second) == :error
    end

    test "an interval set casts to itself" do
      assert IntervalSetType.cast(interval_set(), @second) == {:ok, interval_set()}
    end

    test "values of the wrong shape are rejected" do
      for type <- [IntervalType, IntervalSetType, TempoType, TempoRange, TempoMultirange] do
        assert type.cast("not a time", @second) == :error
        assert type.cast(42, @second) == :error
      end
    end
  end

  describe "dump/3" do
    test "nil dumps to nil" do
      for type <- [IntervalType, IntervalSetType, TempoType, TempoRange, TempoMultirange] do
        assert type.dump(nil, nil, @second) == {:ok, nil}
      end
    end

    test "an interval dumps to a Postgrex range with half-open bounds" do
      assert {:ok, %Postgrex.Range{} = range} = IntervalType.dump(interval(), nil, @second)
      assert range.lower_inclusive == true
      assert range.upper_inclusive == false
    end

    test "a composite dump carries the range, the resolution and the metadata" do
      assert {:ok, {%Postgrex.Range{}, "second", meta}} =
               TempoRange.dump(interval(), nil, @second)

      assert is_binary(meta)
    end

    test "the declared resolution is recorded in the composite" do
      assert {:ok, {_range, "year", _meta}} =
               TempoRange.dump(interval(), nil, %{resolution: :year})
    end

    test "a bare Tempo dumps by materialising first" do
      assert {:ok, {%Postgrex.Range{}, _resolution, _meta}} =
               TempoRange.dump(~o"2027Y", nil, @second)
    end

    test "values of the wrong shape are rejected" do
      for type <- [IntervalType, TempoType, TempoRange, TempoMultirange] do
        assert type.dump("not a time", nil, @second) == :error
      end
    end
  end

  describe "load/3" do
    test "nil loads to nil" do
      for type <- [IntervalType, IntervalSetType, TempoType, TempoRange, TempoMultirange] do
        assert type.load(nil, nil, @second) == {:ok, nil}
      end
    end

    test "a dumped interval loads back as an interval" do
      {:ok, dumped} = IntervalType.dump(interval(), nil, @second)

      assert {:ok, %Tempo.Interval{}} = IntervalType.load(dumped, nil, @second)
    end

    test "a composite row without metadata falls back to plain range decoding" do
      {:ok, range} = IntervalType.dump(interval(), nil, @second)

      assert {:ok, %Tempo.Interval{}} = TempoRange.load({range, "second", nil}, nil, @second)
    end

    test "a composite row with metadata is decoded from the metadata" do
      {:ok, {range, resolution, meta}} = TempoRange.dump(interval(), nil, @second)

      assert {:ok, %Tempo.Interval{}} =
               TempoRange.load({range, resolution, meta}, nil, @second)
    end

    test "values of the wrong shape are rejected" do
      for type <- [IntervalType, TempoRange, TempoMultirange] do
        assert type.load("not a range", nil, @second) == :error
      end
    end
  end

  describe "equal?/3 and embed_as/2" do
    test "equality is structural" do
      assert TempoRange.equal?(interval(), interval(), @second)
      refute TempoRange.equal?(interval(), nil, @second)
    end

    test "types embed as themselves" do
      assert TempoRange.embed_as(:json, @second) == :self
      assert TempoMultirange.embed_as(:json, @second) == :self
    end
  end

  describe "cast_type/1" do
    test "builds a parameterized type usable in a schema" do
      assert {:parameterized, {TempoRange, %{resolution: :second}}} = TempoRange.cast_type()

      assert {:parameterized, {IntervalType, %{resolution: :year}}} =
               IntervalType.cast_type(resolution: :year)
    end
  end

  describe "round-trip through dump and load" do
    test "a loaded interval comes back grounded in UTC" do
      # Plain-range mode is lossy in one direction: a floating value
      # goes in and a UTC-grounded one comes out, because a `tstzrange`
      # has no way to say "no zone". The storage-contract guide states
      # this; the test pins it.
      {:ok, dumped} = IntervalType.dump(interval(), nil, @second)
      {:ok, loaded} = IntervalType.load(dumped, nil, @second)

      assert Tempo.grounded?(loaded.from)
      refute Tempo.grounded?(interval().from)
    end

    test "the round-trip is stable — dumping a loaded value reproduces the range" do
      {:ok, first} = IntervalType.dump(interval(), nil, @second)
      {:ok, loaded} = IntervalType.load(first, nil, @second)
      {:ok, second} = IntervalType.dump(loaded, nil, @second)

      # Whatever the first cycle changed, the second changes nothing —
      # so a value read and written back is not silently drifting.
      assert second == first
    end

    test "an interval set survives a dump/load cycle" do
      {:ok, dumped} = IntervalSetType.dump(interval_set(), nil, @second)
      {:ok, loaded} = IntervalSetType.load(dumped, nil, @second)

      assert Tempo.IntervalSet.count(loaded) == 1
    end
  end
end
