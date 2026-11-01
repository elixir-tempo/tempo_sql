defmodule Tempo.Ecto.TempoTest do
  use ExUnit.Case, async: true

  import Tempo.Sigils

  alias Tempo.Ecto.Tempo, as: EctoTempo

  @default_params %{frame: :utc, resolution: :second}
  @floating_params %{frame: :floating, resolution: :second}
  @floating_params %{frame: :floating, resolution: :second}

  defp stored(expression, params \\ @default_params) do
    {:ok, range} = EctoTempo.dump(expression, nil, params)
    {range.lower, range.upper}
  end

  describe "type/1" do
    test "reports tstzrange" do
      assert EctoTempo.type(@default_params) == :tstzrange
    end
  end

  describe "dump/3 — a value is the span it denotes" do
    test "a year is its year" do
      assert stored(~o"2026[Etc/UTC]") == {~U[2026-01-01 00:00:00Z], ~U[2027-01-01 00:00:00Z]}
    end

    test "a month is its month" do
      assert stored(~o"2026-06[Etc/UTC]") == {~U[2026-06-01 00:00:00Z], ~U[2026-07-01 00:00:00Z]}
    end

    test "a day is its 24 hours" do
      assert stored(~o"2026-06-15[Etc/UTC]") ==
               {~U[2026-06-15 00:00:00Z], ~U[2026-06-16 00:00:00Z]}
    end

    test "an interval is stored as it is" do
      assert stored(~o"2026-06-15T09:00:00Z/2026-06-15T17:00:00Z") ==
               {~U[2026-06-15 09:00:00Z], ~U[2026-06-15 17:00:00Z]}
    end
  end

  describe "load/3 — :resolution recovers the value's resolution" do
    test "a year stored at :year loads as the year through the year" do
      params = EctoTempo.init(resolution: :year)

      {:ok, range} = EctoTempo.dump(~o"2026[Etc/UTC]", nil, params)

      # The closest a tstzrange comes to a round-trip of `~o"2026"`.
      assert {:ok, ~o"2026YZ/2026YZ"} = EctoTempo.load(range, nil, params)
    end
  end

  describe "cast/2" do
    test "makes a value the interval it denotes" do
      assert {:ok, ~o"2026-06/2026-06"} = EctoTempo.cast(~o"2026-06", @floating_params)
    end

    test "refuses a floating value for a column on the UTC line, saying which frame to declare" do
      assert {:error, message: message} = EctoTempo.cast(~o"2026-06", @default_params)
      assert message =~ "frame: :floating"
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

  describe "the floating frame" do
    test "reports tsrange" do
      assert EctoTempo.type(@floating_params) == :tsrange
    end

    test "a floating value is the span it denotes, with naive bounds" do
      assert stored(~o"2026", @floating_params) ==
               {~N[2026-01-01 00:00:00], ~N[2027-01-01 00:00:00]}

      assert stored(~o"2026-06-15", @floating_params) ==
               {~N[2026-06-15 00:00:00], ~N[2026-06-16 00:00:00]}
    end

    test "a floating year stored at :year loads as the floating year through the year" do
      params = EctoTempo.init(resolution: :year, frame: :floating)

      {:ok, range} = EctoTempo.dump(~o"2026", nil, params)

      assert {:ok, ~o"2026/2026"} = EctoTempo.load(range, nil, params)
    end

    test "a floating value is refused on the UTC line" do
      assert EctoTempo.dump(~o"2026-06-15", nil, @default_params) == :error
    end

    test "a value in a zone is refused on the floating frame" do
      assert EctoTempo.dump(~o"2026-06-15[Europe/Paris]", nil, @floating_params) == :error
    end
  end
end
