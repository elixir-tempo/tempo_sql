defmodule Tempo.Ecto.TempoTest do
  use ExUnit.Case, async: true

  import Tempo.Sigils

  alias Tempo.Ecto.Tempo, as: EctoTempo

  @default_params %{resolution: :second}

  defp stored(expression) do
    {:ok, range} = EctoTempo.dump(expression, nil, @default_params)
    {range.lower, range.upper}
  end

  describe "type/1" do
    test "reports tstzrange" do
      assert EctoTempo.type(@default_params) == :tstzrange
    end
  end

  describe "dump/3 — a value is the span it denotes" do
    test "a year is its year" do
      assert stored(~o"2026") == {~U[2026-01-01 00:00:00Z], ~U[2027-01-01 00:00:00Z]}
    end

    test "a month is its month" do
      assert stored(~o"2026-06") == {~U[2026-06-01 00:00:00Z], ~U[2026-07-01 00:00:00Z]}
    end

    test "a day is its 24 hours" do
      assert stored(~o"2026-06-15") == {~U[2026-06-15 00:00:00Z], ~U[2026-06-16 00:00:00Z]}
    end

    test "an interval is stored as it is" do
      assert stored(~o"2026-06-15T09:00:00/2026-06-15T17:00:00") ==
               {~U[2026-06-15 09:00:00Z], ~U[2026-06-15 17:00:00Z]}
    end
  end

  describe "load/3 — :resolution recovers the value's resolution" do
    test "a year stored at :year loads as the year through the year" do
      params = EctoTempo.init(resolution: :year)

      {:ok, range} = EctoTempo.dump(~o"2026", nil, params)

      # The closest a tstzrange comes to a round-trip of `~o"2026"`.
      assert {:ok, ~o"2026YZ/2026YZ"} = EctoTempo.load(range, nil, params)
    end
  end

  describe "cast/2" do
    test "makes a value the interval it denotes" do
      assert {:ok, ~o"2026-06/2026-06"} = EctoTempo.cast(~o"2026-06", @default_params)
    end

    test "accepts a Postgrex.Range" do
      range = %Postgrex.Range{
        lower: ~U[2026-01-01 00:00:00Z],
        upper: ~U[2027-01-01 00:00:00Z],
        lower_inclusive: true,
        upper_inclusive: false
      }

      assert {:ok, ~o"2026-01-01T00:00:00Z/2027-01-01T00:00:00Z"} =
               EctoTempo.cast(range, @default_params)
    end
  end
end
