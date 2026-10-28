defmodule Tempo.SQL.ErrorPathsTest do
  @moduledoc """
  What each type does when handed something it cannot use. Ecto relies
  on `:error` rather than an exception to turn a bad value into a
  changeset error, so every one of these paths is load-bearing.

  Also exercises the default-argument forms of `load/1` and `dump/1`,
  which the schema-driven tests never take because Ecto always passes
  all three arguments.
  """

  use ExUnit.Case, async: true

  import Tempo.Sigils

  alias Tempo.Ecto.Interval, as: IntervalType
  alias Tempo.Ecto.IntervalSet, as: IntervalSetType
  alias Tempo.Ecto.Tempo, as: TempoType
  alias Tempo.Ecto.TempoMultirange
  alias Tempo.Ecto.TempoRange
  alias Tempo.SQL.Meta

  @second %{resolution: :second}

  defp interval do
    ~o"2027-06-15T09:00/2027-06-15T10:00"
  end

  # A time of day with no date has no place on the time line, so no range
  # can be built from it.
  defp unpositioned do
    ~o"T09/T10"
  end

  defp bad_range do
    %Postgrex.Range{lower: :bogus, upper: :bogus, lower_inclusive: true, upper_inclusive: false}
  end

  defp bad_multirange do
    %Postgrex.Multirange{ranges: [bad_range()]}
  end

  # Two disjoint years — a set, not a single span.
  defp disjoint do
    ~o"{2027,2029}Y"
  end

  describe "the default-argument forms" do
    test "load/1 uses second resolution" do
      {:ok, dumped} = IntervalType.dump(interval())

      assert {:ok, ~o"2027-06-15T09:00:00Z/2027-06-15T10:00:00Z"} = IntervalType.load(dumped)
    end

    test "dump/1 works without a dumper or params" do
      assert {:ok, %Postgrex.Range{}} = IntervalType.dump(interval())
      assert {:ok, %Postgrex.Range{}} = TempoType.dump(interval())
      assert {:ok, {_range, "second", _meta}} = TempoRange.dump(interval())
    end

    test "the set types load and dump with defaults too" do
      set = Tempo.IntervalSet.new!([interval()])

      {:ok, dumped} = IntervalSetType.dump(set)
      assert {:ok, loaded} = IntervalSetType.load(dumped)
      assert Tempo.IntervalSet.count(loaded) == 1

      {:ok, composite} = TempoMultirange.dump(set)
      assert {:ok, ^set} = TempoMultirange.load(composite)
    end

    test "cast_type/0 defaults to second resolution on every type" do
      for type <- [IntervalType, IntervalSetType, TempoType, TempoRange, TempoMultirange] do
        assert {:parameterized, {^type, %{resolution: :second}}} = type.cast_type()
      end
    end
  end

  describe "a range Postgres could not have produced" do
    test "casting it is an error" do
      assert IntervalType.cast(bad_range(), @second) == :error
    end

    test "loading it is an error" do
      assert IntervalType.load(bad_range(), nil, @second) == :error
    end

    test "the set types refuse a multirange holding one" do
      assert IntervalSetType.cast(bad_multirange(), @second) == :error
      assert IntervalSetType.load(bad_multirange(), nil, @second) == :error
    end

    test "the composite multirange refuses it in the fallback path" do
      assert TempoMultirange.load({bad_multirange(), "second", nil}, nil, @second) == :error
    end
  end

  describe "values with no position on the time line" do
    test "the composite refuses to dump an interval it cannot anchor" do
      assert TempoRange.dump(unpositioned(), nil, @second) == :error
    end

    test "a set containing one is refused too" do
      unanchorable = Tempo.IntervalSet.new!([unpositioned()])

      assert TempoMultirange.dump(unanchorable, nil, @second) == :error
      assert IntervalSetType.dump(unanchorable, nil, @second) == :error
    end
  end

  describe "an expression that is not a single span" do
    test "the composite stores it as the stretch it covers" do
      assert {:ok, {range, "second", _meta}} = TempoRange.dump(disjoint(), nil, @second)
      assert {range.lower, range.upper} == {~U[2027-01-01 00:00:00Z], ~U[2030-01-01 00:00:00Z]}
    end

    test "the plain interval type refuses to cast it" do
      assert IntervalType.cast(disjoint(), @second) == :error
    end
  end

  describe "wrong shapes altogether" do
    test "loading something that is not a range or multirange" do
      assert IntervalSetType.load("not a multirange", nil, @second) == :error
      assert TempoRange.load("not a composite", nil, @second) == :error
    end

    test "dumping something that is not an interval or set" do
      assert IntervalSetType.dump("not a set", nil, @second) == :error
      assert TempoRange.dump("not an interval", nil, @second) == :error
    end
  end

  describe "composite metadata that does not decode" do
    test "a meta document with neither an expression nor intervals" do
      {:ok, multirange} = IntervalSetType.dump(Tempo.IntervalSet.new!([interval()]))

      assert TempoMultirange.load({multirange, "second", ~s({"v":2})}, nil, @second) == :error
    end

    test "a meta document whose members do not decode" do
      {:ok, multirange} = IntervalSetType.dump(Tempo.IntervalSet.new!([interval()]))
      corrupt = ~s({"v":2,"intervals":[{"from":"not-a-date","to":"2027"}],"metadata":{}})

      assert TempoMultirange.load({multirange, "second", corrupt}, nil, @second) == :error
    end

    test "a version 3 expression that does not read" do
      {:ok, range} = IntervalType.dump(interval())
      corrupt = ~s({"v":3,"expression":"not-a-date"})

      assert TempoRange.load({range, "second", corrupt}, nil, @second) == :error
    end
  end

  describe "version 2 meta fields the common path never wrote" do
    test "a backward direction is read and changes no span" do
      assert {:ok, ~o"2027-06-15/2027-06-15"} =
               Meta.decode_interval(
                 ~s({"v":2,"from":"2027Y6M15D","to":"2027Y6M16D","direction":-1})
               )
    end

    test "a duration end survives as a duration" do
      assert {:ok, ~o"2027-06-15T09:00/PT1H"} =
               Meta.decode_interval(~s({"v":2,"from":"2027Y6M15DT9H0M","to":"PT1H"}))
    end

    test "a repeat rule that is no selection is refused" do
      assert {:error, %ArgumentError{}} =
               Meta.decode_interval(
                 ~s({"v":2,"from":"2027Y6M15D","to":"2027Y6M16D","repeat_rule":"2027Y"})
               )
    end

    test "an endpoint that reads as something that is not a value" do
      # An interval in an endpoint slot reads, but as an interval, which
      # is no end.
      assert {:error, %Tempo.IntervalEndpointsError{}} =
               Meta.decode_interval(~s({"from":"2027-06-15/2027-06-16","to":"2027-06-17"}))
    end

    test "a duration slot that does not read at all" do
      assert {:error, %Tempo.ParseError{}} =
               Meta.decode_interval(~s({"from":"2026","to":"2027","duration":"not-a-duration"}))
    end

    test "a repeat rule that does not read at all" do
      assert {:error, %Tempo.ParseError{}} =
               Meta.decode_interval(~s({"from":"2026","to":"2027","repeat_rule":"not-a-rule"}))
    end
  end
end
