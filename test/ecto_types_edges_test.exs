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

  defp interval(from, to) do
    Tempo.Interval.new!(from: Tempo.from_iso8601!(from), to: Tempo.from_iso8601!(to))
  end

  defp morning, do: interval("2027-06-15T09:00:00", "2027-06-15T10:00:00")
  defp afternoon, do: interval("2027-06-15T14:00:00", "2027-06-15T15:00:00")

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
      assert {:ok, %Tempo.Interval{} = cast} = IntervalType.cast(range(), @second)
      assert Tempo.hour(cast.from) == 9
    end

    test "the bare-Tempo type casts a range too, by delegating" do
      assert {:ok, %Tempo.Interval{}} = TempoType.cast(range(), @second)
    end

    test "a multirange casts to the set it represents" do
      assert {:ok, %Tempo.IntervalSet{} = set} = IntervalSetType.cast(multirange(), @second)
      assert Tempo.IntervalSet.count(set) == 2
    end

    test "a declared resolution is applied while casting a range" do
      # The span must survive truncation: a one-hour range truncated to
      # days would collapse to zero extent, which is not an interval.
      {:ok, week} = IntervalType.dump(interval("2027-06-15", "2027-06-22"), nil, @second)

      assert {:ok, cast} = IntervalType.cast(week, %{resolution: :day})
      assert Keyword.keys(cast.from.time) == [:year, :month, :day]
    end
  end

  describe "a list of intervals is accepted as a set" do
    test "the set types cast a plain list" do
      for type <- [IntervalSetType, TempoMultirange] do
        assert {:ok, %Tempo.IntervalSet{} = set} =
                 type.cast([morning(), afternoon()], @second)

        assert Tempo.IntervalSet.count(set) == 2
      end
    end

    test "a list that is not intervals at all is refused" do
      # Needs ex_tempo 1.1.1: before that, `IntervalSet.new/1` raised a
      # FunctionClauseError here instead of returning `{:error, _}`, so
      # a bad list from a changeset crashed rather than failing to cast.
      for type <- [IntervalSetType, TempoMultirange] do
        assert type.cast([:not, :intervals], @second) == :error
        assert type.cast(["09:00", "10:00"], @second) == :error
      end
    end

    test "a list holding a member no set can contain is refused" do
      # An open-ended interval has no upper endpoint, so it cannot be a
      # member of a set — `IntervalSet.new/1` says so and the cast
      # turns that into Ecto's `:error`.
      {:ok, open} = Tempo.Interval.new(from: Tempo.from_iso8601!("2027-06-15"), to: :undefined)

      for type <- [IntervalSetType, TempoMultirange] do
        assert type.cast([open], @second) == :error
      end
    end
  end

  describe "the empty set has no representation" do
    test "dumping an empty set is an error, not an empty multirange" do
      # `'{}'::tstzmultirange` and NULL would both read back as "no
      # busy times"; the column is expected to be NULL for that, so an
      # empty set is refused rather than silently conflated.
      empty = %Tempo.IntervalSet{intervals: []}

      assert IntervalSetType.dump(empty, nil, @second) == :error
      assert TempoMultirange.dump(empty, nil, @second) == :error
    end
  end

  describe "the composite falls back when a row carries no metadata" do
    test "a multirange composite decodes from its ranges alone" do
      assert {:ok, %Tempo.IntervalSet{} = set} =
               TempoMultirange.load({multirange(), "second", nil}, nil, @second)

      assert Tempo.IntervalSet.count(set) == 2
    end

    test "the fallback honours the declared resolution" do
      # Day-resolution members must span whole days to survive
      # truncation, so this set is two separate weeks.
      {:ok, weeks} =
        IntervalSetType.dump(
          Tempo.IntervalSet.new!([
            interval("2027-06-01", "2027-06-08"),
            interval("2027-07-01", "2027-07-08")
          ]),
          nil,
          @second
        )

      assert {:ok, set} = TempoMultirange.load({weeks, "day", nil}, nil, %{resolution: :day})

      [first | _] = Tempo.IntervalSet.to_list(set)
      assert Keyword.keys(first.from.time) == [:year, :month, :day]
    end

    test "metadata that is not a set document is refused" do
      assert {:error, _} =
               TempoMultirange.load({multirange(), "second", ~s({"not":"a set"})}, nil, @second)
    end
  end

  describe "the bare-Tempo type" do
    test "dumps an interval as readily as a Tempo" do
      assert {:ok, %Postgrex.Range{}} = TempoType.dump(morning(), nil, @second)
    end

    test "loads a range back as an interval" do
      assert {:ok, %Tempo.Interval{}} = TempoType.load(range(), nil, @second)
    end

    test "refuses a Tempo that materialises to a set" do
      # `{2027,2029}Y` is two disjoint years — an interval set, which a
      # single `tstzrange` column cannot hold.
      {:ok, disjoint} = Tempo.from_iso8601("{2027,2029}Y")

      assert TempoType.cast(disjoint, @second) == :error
      assert TempoType.dump(disjoint, nil, @second) == :error
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
      {:ok, recurring} = Tempo.from_iso8601("R5/2027-06-15/P1M")

      {:ok, dumped} = TempoRange.dump(recurring, nil, @second)
      {:ok, loaded} = TempoRange.load(dumped, nil, @second)

      assert Tempo.to_iso8601(loaded) == Tempo.to_iso8601(recurring)
      assert loaded.recurrence == 5
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
