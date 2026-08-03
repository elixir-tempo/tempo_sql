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

  defp interval, do: Tempo.Interval.new!(from: ~o"2027-06-15T09:00", to: ~o"2027-06-15T10:00")

  # An interval whose `to` is a duration has no second endpoint on the
  # time line, so no range can be built from it.
  defp unpositioned, do: %Tempo.Interval{from: ~o"2027-06-15T09:00", to: ~o"PT1H"}

  defp bad_range do
    %Postgrex.Range{lower: :bogus, upper: :bogus, lower_inclusive: true, upper_inclusive: false}
  end

  defp bad_multirange, do: %Postgrex.Multirange{ranges: [bad_range()]}

  # Two disjoint years — an interval set, not a single span.
  defp disjoint, do: Tempo.from_iso8601!("{2027,2029}Y")

  describe "the default-argument forms" do
    test "load/1 uses second resolution" do
      {:ok, dumped} = IntervalType.dump(interval())

      assert {:ok, %Tempo.Interval{}} = IntervalType.load(dumped)
    end

    test "dump/1 works without a dumper or params" do
      assert {:ok, %Postgrex.Range{}} = IntervalType.dump(interval())
      assert {:ok, %Postgrex.Range{}} = TempoType.dump(interval())
      assert {:ok, {_range, "second", _meta}} = TempoRange.dump(interval())
    end

    test "the set types load and dump with defaults too" do
      set = Tempo.IntervalSet.new!([interval()])

      {:ok, dumped} = IntervalSetType.dump(set)
      assert {:ok, %Tempo.IntervalSet{}} = IntervalSetType.load(dumped)

      {:ok, composite} = TempoMultirange.dump(set)
      assert {:ok, %Tempo.IntervalSet{}} = TempoMultirange.load(composite)
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
      unanchorable = %Tempo.IntervalSet{intervals: [unpositioned()]}

      assert TempoMultirange.dump(unanchorable, nil, @second) == :error
      assert IntervalSetType.dump(unanchorable, nil, @second) == :error
    end
  end

  describe "a Tempo that is not a single span" do
    test "the composite refuses to dump it" do
      assert TempoRange.dump(disjoint(), nil, @second) == :error
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
    test "a meta document with no intervals key" do
      {:ok, multirange} = IntervalSetType.dump(Tempo.IntervalSet.new!([interval()]))

      assert {:error, _} =
               TempoMultirange.load({multirange, "second", ~s({"v":2})}, nil, @second)
    end

    test "a meta document whose members do not decode" do
      {:ok, multirange} = IntervalSetType.dump(Tempo.IntervalSet.new!([interval()]))
      corrupt = ~s({"v":2,"intervals":[{"from":"not-a-date","to":"2027"}],"metadata":{}})

      assert {:error, _} = TempoMultirange.load({multirange, "second", corrupt}, nil, @second)
    end
  end

  describe "meta fields the common path never writes" do
    test "a backward interval keeps its direction" do
      backward = %Tempo.Interval{from: ~o"2027-06-15", to: ~o"2027-06-16", direction: -1}

      json = backward |> Meta.encode_interval() |> IO.iodata_to_binary()

      assert Meta.decode_json(json)["direction"] == -1
      assert {:ok, loaded} = Meta.decode_interval(json)
      assert loaded.direction == -1
    end

    test "a duration endpoint survives as a duration" do
      json = unpositioned() |> Meta.encode_interval() |> IO.iodata_to_binary()

      assert {:ok, loaded} = Meta.decode_interval(json)
      assert %Tempo.Duration{} = loaded.to
    end

    test "a repeat rule survives" do
      with_rule = %Tempo.Interval{
        from: ~o"2027-06-15",
        to: ~o"2027-06-16",
        repeat_rule: ~o"2027Y"
      }

      json = with_rule |> Meta.encode_interval() |> IO.iodata_to_binary()

      assert {:ok, loaded} = Meta.decode_interval(json)
      assert %Tempo{} = loaded.repeat_rule
    end

    test "an endpoint that parses to something that is not a time" do
      # An interval string in an endpoint slot parses, but to an
      # interval — not a value an endpoint can be.
      assert {:error, {:unexpected_endpoint_type, _}} =
               Meta.decode_interval(~s({"from":"2027-06-15/2027-06-16","to":"2027-06-17"}))
    end

    test "a duration slot that does not parse at all" do
      assert {:error, %Tempo.ParseError{}} =
               Meta.decode_interval(~s({"from":"2026","to":"2027","duration":"not-a-duration"}))
    end

    test "a repeat rule that does not parse at all" do
      assert {:error, %Tempo.ParseError{}} =
               Meta.decode_interval(~s({"from":"2026","to":"2027","repeat_rule":"not-a-rule"}))
    end
  end
end
