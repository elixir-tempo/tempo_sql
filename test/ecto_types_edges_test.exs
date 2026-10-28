defmodule Tempo.SQL.EctoTypesEdgesTest do
  @moduledoc """
  The type callbacks reached by paths the round-trip tests never take:
  casting the wire shapes Postgrex hands back, the list form of a set,
  the empty set, and the composite's fallback when a row has no
  metadata to decode.
  """

  use ExUnit.Case, async: true

  import Tempo.Sigils

  alias Tempo.Ecto.Interval, as: IntervalType
  alias Tempo.Ecto.IntervalSet, as: IntervalSetType
  alias Tempo.Ecto.Tempo, as: TempoType
  alias Tempo.Ecto.TempoMultirange
  alias Tempo.Ecto.TempoRange

  @second %{resolution: :second}

  defp morning do
    ~o"2027-06-15T09:00:00/2027-06-15T10:00:00"
  end

  defp afternoon do
    ~o"2027-06-15T14:00:00/2027-06-15T15:00:00"
  end

  defp range do
    {:ok, range} = IntervalType.dump(morning(), nil, @second)
    range
  end

  defp multirange do
    {:ok, multirange} =
      IntervalSetType.dump(Tempo.IntervalSet.new!([morning(), afternoon()]), nil, @second)

    multirange
  end

  describe "casting the shapes Postgrex hands back" do
    test "a range casts to the interval it represents" do
      assert {:ok, ~o"2027-06-15T09:00:00Z/2027-06-15T10:00:00Z"} =
               IntervalType.cast(range(), @second)
    end

    test "the bare-Tempo type casts a range too, by delegating" do
      assert {:ok, ~o"2027-06-15T09:00:00Z/2027-06-15T10:00:00Z"} =
               TempoType.cast(range(), @second)
    end

    test "a multirange casts to the set it represents" do
      assert {:ok, set} = IntervalSetType.cast(multirange(), @second)
      assert Tempo.IntervalSet.count(set) == 2
    end

    test "a declared resolution is applied while casting a range" do
      # The span must survive truncation: a one-hour range written to the
      # day would end before it began, which is no interval.
      {:ok, week} = IntervalType.dump(~o"2027-06-15/2027-06-21", nil, @second)

      assert {:ok, ~o"2027Y6M15DZ/2027Y6M21DZ"} = IntervalType.cast(week, %{resolution: :day})
    end
  end

  describe "a list of intervals is accepted as a set" do
    test "the set types cast a plain list" do
      for type <- [IntervalSetType, TempoMultirange] do
        assert {:ok, set} = type.cast([morning(), afternoon()], @second)
        assert Tempo.IntervalSet.members(set) == [morning(), afternoon()]
      end
    end

    test "a list that is not intervals at all is refused" do
      # A bad list from a changeset fails to cast rather than crashing.
      for type <- [IntervalSetType, TempoMultirange] do
        assert type.cast([:not, :intervals], @second) == :error
        assert type.cast(["09:00", "10:00"], @second) == :error
      end
    end

    test "a list holding an open-ended member is a set with an unbounded member" do
      assert {:ok, set} = IntervalSetType.cast([~o"2027-06-15/.."], @second)

      assert {:ok, %Postgrex.Multirange{ranges: [range]}} =
               IntervalSetType.dump(set, nil, @second)

      assert {range.lower, range.upper} == {~U[2027-06-15 00:00:00Z], :unbound}
    end

    test "a recurrence with no end is refused by the plain set type" do
      assert IntervalSetType.cast(~o"R/2027-06-15/P1D", @second) == :error
    end
  end

  describe "the empty set has no representation" do
    test "dumping an empty set is an error, not an empty multirange" do
      # `'{}'::tstzmultirange` and NULL would both read back as "no
      # busy times"; the column is expected to be NULL for that, so an
      # empty set is refused rather than silently conflated.
      empty = Tempo.IntervalSet.new!([])

      assert IntervalSetType.dump(empty, nil, @second) == :error
      assert TempoMultirange.dump(empty, nil, @second) == :error
    end
  end

  describe "the composite falls back when a row carries no metadata" do
    test "a multirange composite decodes from its ranges alone" do
      assert {:ok, set} = TempoMultirange.load({multirange(), "second", nil}, nil, @second)

      assert Tempo.IntervalSet.members(set) == [
               ~o"2027-06-15T09:00:00Z/2027-06-15T10:00:00Z",
               ~o"2027-06-15T14:00:00Z/2027-06-15T15:00:00Z"
             ]
    end

    test "the fallback honours the declared resolution" do
      # Day-resolution members must span whole days, so this set is two
      # separate weeks.
      weeks = Tempo.IntervalSet.new!([~o"2027-06-01/2027-06-07", ~o"2027-07-01/2027-07-07"])
      {:ok, multirange} = IntervalSetType.dump(weeks, nil, @second)

      assert {:ok, set} = TempoMultirange.load({multirange, "day", nil}, nil, %{resolution: :day})

      assert Tempo.IntervalSet.members(set) == [
               ~o"2027Y6M1DZ/2027Y6M7DZ",
               ~o"2027Y7M1DZ/2027Y7M7DZ"
             ]
    end

    test "metadata that is not a set document is refused" do
      assert TempoMultirange.load({multirange(), "second", ~s({"not":"a set"})}, nil, @second) ==
               :error
    end
  end

  describe "the bare-Tempo type" do
    test "dumps an interval as readily as a Tempo" do
      assert {:ok, %Postgrex.Range{}} = TempoType.dump(morning(), nil, @second)
    end

    test "loads a range back as an interval" do
      assert {:ok, ~o"2027-06-15T09:00:00Z/2027-06-15T10:00:00Z"} =
               TempoType.load(range(), nil, @second)
    end

    test "refuses an expression of several spans" do
      # `{2027,2029}Y` is two disjoint years, which a single `tstzrange`
      # column cannot hold.
      assert TempoType.cast(~o"{2027,2029}Y", @second) == :error
      assert TempoType.dump(~o"{2027,2029}Y", nil, @second) == :error
    end

    test "builds a parameterized type usable in a schema" do
      assert {:parameterized, {TempoType, %{resolution: :year}}} =
               TempoType.cast_type(resolution: :year)
    end
  end

  describe "cast_type/1 on the remaining types" do
    test "each set type builds its parameterized form" do
      assert {:parameterized, {IntervalSetType, %{resolution: :second}}} =
               IntervalSetType.cast_type()

      assert {:parameterized, {TempoMultirange, %{resolution: :day}}} =
               TempoMultirange.cast_type(resolution: :day)
    end
  end

  describe "a recurring interval survives the composite round-trip" do
    test "it comes back rendering as it went in" do
      # This is the fidelity the composite type exists for, and the
      # case the plain-range types refuse outright.
      recurring = ~o"R5/2027-06-15/P1M"

      {:ok, dumped} = TempoRange.dump(recurring, nil, @second)
      {:ok, loaded} = TempoRange.load(dumped, nil, @second)

      assert loaded == recurring
      assert Tempo.IntervalSet.count(loaded) == 5
    end
  end

  describe "equality and embedding on the set types" do
    test "equality is structural" do
      set = Tempo.IntervalSet.new!([morning()])

      assert IntervalSetType.equal?(set, set, @second)
      assert TempoMultirange.equal?(set, set, @second)
      refute TempoMultirange.equal?(set, nil, @second)
    end

    test "the set types embed as themselves" do
      assert IntervalSetType.embed_as(:json, @second) == :self
      assert TempoType.embed_as(:json, @second) == :self
      assert IntervalType.embed_as(:json, @second) == :self
    end

    test "equality on the interval types" do
      assert IntervalType.equal?(morning(), morning(), @second)
      refute IntervalType.equal?(morning(), afternoon(), @second)
      assert TempoType.equal?(~o"2027Y", ~o"2027Y", @second)
    end
  end
end
