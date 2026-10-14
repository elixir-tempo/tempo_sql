defmodule Tempo.SQL.MetaTest do
  use ExUnit.Case, async: true

  import Tempo.Sigils

  alias Tempo.Interval
  alias Tempo.IntervalSet
  alias Tempo.SQL.Meta

  defp round_trip(expression) do
    {:ok, json} = Meta.encode_interval(expression)
    {:ok, loaded} = json |> IO.iodata_to_binary() |> Meta.decode_interval()
    loaded
  end

  defp document(expression) do
    {:ok, json} = Meta.encode_interval(expression)
    json |> IO.iodata_to_binary() |> Meta.decode_json()
  end

  describe "encode/decode round-trip — the shapes the plain-range types reject" do
    test "a year through a year keeps its resolution" do
      loaded = round_trip(~o"2026/2026")

      assert loaded == ~o"2026/2026"
      assert Tempo.resolution(Interval.from(loaded)) == :year
    end

    test "qualified (uncertain) ends survive" do
      loaded = round_trip(~o"1984?/2004~")

      assert loaded == ~o"1984?/2004~"
      assert Tempo.qualification(Interval.from(loaded)) == %{year: :uncertain}
      assert Tempo.qualification(Interval.to(loaded)) == %{year: :approximate}
    end

    test "a recurrence survives" do
      loaded = round_trip(~o"R5/2022-01-01/P1M")

      assert loaded == ~o"R5/2022-01-01/P1M"
      assert IntervalSet.count(loaded) == 5
    end

    test "an unbounded recurrence survives" do
      assert round_trip(~o"R/2022-01-01/P1M") == ~o"R/2022-01-01/P1M"
    end

    test "a recurrence with a selection rule survives" do
      {:ok, christmas_day} = Tempo.selection(month: 12, day: 25)
      {:ok, christmas} = Tempo.every(~o"P1Y", from: ~o"2022-01-01", select: christmas_day)
      assert round_trip(christmas) == christmas
    end

    test "user metadata passes through when JSON-serialisable" do
      meeting =
        Tempo.put_metadata(~o"2026-06-15T09:00:00/2026-06-15T10:00:00", %{
          "source" => "calendar-import",
          "priority" => 3
        })

      assert Tempo.metadata(round_trip(meeting)) == %{
               "source" => "calendar-import",
               "priority" => 3
             }
    end

    test "each member of a set keeps its own metadata" do
      set =
        IntervalSet.new!([
          Tempo.put_metadata(~o"2026-06-01/2026-06-02", %{"name" => "first"}),
          Tempo.put_metadata(~o"2026-06-10/2026-06-11", %{"name" => "second"})
        ])

      loaded = round_trip(set)

      assert loaded == set

      assert Enum.map(IntervalSet.members(loaded), &Tempo.metadata/1) == [
               %{"name" => "first"},
               %{"name" => "second"}
             ]
    end
  end

  describe "encode_interval/1" do
    test "writes version 3 with the expression's text" do
      decoded = document(~o"2026-06-15T09:00:00/2026-06-15T10:00:00")

      assert decoded["v"] == 3

      assert {:ok, ~o"2026-06-15T09:00:00/2026-06-15T10:00:00"} =
               Tempo.from_iso8601(decoded["expression"])

      assert decoded["metadata"] == %{}
      assert decoded["members"] == nil
    end

    test "an open end is written as the ISO 8601 open marker" do
      decoded = document(~o"../2026-06-15T10:00:00")

      assert String.starts_with?(decoded["expression"], "../")
    end

    test "open ends round-trip on either side" do
      assert round_trip(~o"../2026-06-15T10:00:00") == ~o"../2026-06-15T10:00:00"
      assert round_trip(~o"2022-01-01/..") == ~o"2022-01-01/.."
    end
  end

  describe "rows written by tempo_sql 0.2.0 are read as they were written to mean" do
    # Tempo 1.x read an interval's `to` as the instant it stops before.
    # Tempo 2.0 reads an end written to a date through it, so a stored
    # calendar-unit end is the unit before the one written.

    test "an end written to a day is the day before" do
      assert {:ok, ~o"2022-01-01/2022-01-04"} =
               Meta.decode_interval(
                 ~s({"v":2,"from":"2022Y1M1D","to":"2022Y1M5D","recurrence":1})
               )
    end

    test "an end written to a year is the year before" do
      assert {:ok, ~o"2026/2026"} =
               Meta.decode_interval(~s({"v":2,"from":"2026Y","to":"2027Y","recurrence":1}))
    end

    test "an end written to the clock is the same boundary" do
      assert {:ok, loaded} =
               Meta.decode_interval(
                 ~s({"v":2,"from":"2026Y6M15DT9H","to":"2026Y6M15DT10H","recurrence":1,"metadata":{"source":"import"}})
               )

      assert loaded ==
               Tempo.put_metadata(~o"2026-06-15T09/2026-06-15T10", %{"source" => "import"})
    end

    test "the stored span is the span read back" do
      {:ok, loaded} =
        Meta.decode_interval(~s({"v":2,"from":"2022Y1M1D","to":"2022Y1M5D","recurrence":1}))

      assert {:ok, {~N[2022-01-01 00:00:00], ~N[2022-01-05 00:00:00]}} =
               Interval.instants(loaded)
    end

    test "qualifications are kept" do
      assert {:ok, loaded} =
               Meta.decode_interval(~s({"v":2,"from":"1984Y?","to":"2004Y~","recurrence":1}))

      assert Tempo.qualification(Interval.from(loaded)) == %{year: :uncertain}
      assert Tempo.qualification(Interval.to(loaded)) == %{year: :approximate}
    end

    test "a recurrence from its start, of a duration" do
      assert {:ok, ~o"R5/2022-01-01/P1M"} =
               Meta.decode_interval(
                 ~s({"v":2,"duration":"P1M","from":"2022Y1M1D","recurrence":5,"to":null})
               )
    end

    test "an unbounded recurrence" do
      assert {:ok, ~o"R/2022-01-01/P1M"} =
               Meta.decode_interval(
                 ~s({"v":2,"duration":"P1M","from":"2022Y1M1D","recurrence":"infinity","to":null})
               )
    end

    test "a recurrence counted back from its end keeps its occurrences" do
      assert {:ok, loaded} =
               Meta.decode_interval(
                 ~s({"v":2,"duration":"P1M","from":"..","recurrence":5,"to":"2022Y6M1D"})
               )

      assert IntervalSet.count(loaded) == 5
      assert IntervalSet.first(loaded) == ~o"2022-01-01/2022-01-31"
    end

    test "a recurrence of a start and an end repeats that span" do
      assert {:ok, ~o"R3/2022-01-01/P2D"} =
               Meta.decode_interval(
                 ~s({"v":2,"from":"2022Y1M1D","recurrence":3,"to":"2022Y1M3D"})
               )
    end

    test "a recurrence with a selection rule" do
      assert {:ok, loaded} =
               Meta.decode_interval(
                 ~s({"v":2,"duration":"P1Y","from":"2022Y1M1D","recurrence":"infinity","repeat_rule":"L12M25DN","to":null})
               )

      {:ok, christmas_day} = Tempo.selection(month: 12, day: 25)
      assert {:ok, ^loaded} = Tempo.every(~o"P1Y", from: ~o"2022-01-01", select: christmas_day)
    end

    test "a set, with its metadata" do
      assert {:ok, loaded} =
               Meta.decode_interval(
                 ~s({"v":2,"intervals":[{"v":2,"from":"2026Y6M1D","to":"2026Y6M3D"},{"v":2,"from":"2026Y6M10D","to":"2026Y6M12D"}],"metadata":{"k":"v"}})
               )

      assert IntervalSet.members(loaded) == [~o"2026-06-01/2026-06-02", ~o"2026-06-10/2026-06-11"]
      assert Tempo.metadata(loaded) == %{"k" => "v"}
    end

    # 0.1.0 wrote no `..` marker and read every null endpoint as
    # open-ended; 0.2.0 wrote `..` for an open end and null for an end a
    # duration gave. An interval with neither is open either way.
    test "a null end of a version 1 row is open" do
      assert {:ok, ~o"2022-01-01/.."} =
               Meta.decode_interval(
                 ~s({"v":1,"from":"2022Y1M1D","to":null,"recurrence":1,"direction":1})
               )
    end

    test "a null end of a version 2 interval with no duration is open" do
      assert {:ok, ~o"2022-01-01/.."} =
               Meta.decode_interval(
                 ~s({"v":2,"from":"2022Y1M1D","to":null,"recurrence":1,"direction":1})
               )
    end

    test "a row with no version at all is read as version 1" do
      assert {:ok, ~o"2022-01-01/.."} = Meta.decode_interval(~s({"from":"2022Y1M1D","to":null}))
    end

    test "an explicit open start" do
      assert {:ok, ~o"../2021-12-31"} =
               Meta.decode_interval(~s({"v":2,"from":"..","to":"2022Y1M1D","recurrence":1}))
    end
  end

  describe "decode_interval/1 refuses meta it cannot trust" do
    test "a recurrence that is not a count" do
      assert {:error, {:invalid_recurrence, "often"}} =
               Meta.decode_interval(~s({"from":"2026","to":"2027","recurrence":"often"}))
    end

    test "a direction that is neither forward nor backward" do
      assert {:error, {:invalid_direction, 7}} =
               Meta.decode_interval(~s({"from":"2026","to":"2027","direction":7}))
    end

    test "an endpoint that is not a time" do
      assert {:error, %Tempo.ParseError{}} =
               Meta.decode_interval(~s({"from":"not-a-date","to":"2027"}))
    end

    test "a duration slot holding something that is not a duration" do
      assert {:error, {:unexpected_duration_type, _}} =
               Meta.decode_interval(~s({"from":"2026","to":"2027","duration":"2026"}))
    end

    test "a repeat rule holding something that is not a Tempo" do
      assert {:error, {:unexpected_repeat_rule_type, _}} =
               Meta.decode_interval(~s({"from":"2026","to":"2027","repeat_rule":"P1D"}))
    end

    test "an object that no version wrote" do
      assert {:error, {:invalid_meta_shape, %{"not" => "a set"}}} =
               Meta.decode_interval(~s({"not":"a set"}))
    end

    test "JSON that is not an object at all" do
      assert {:error, {:invalid_meta_shape, [1, 2, 3]}} = Meta.decode_interval(~s([1,2,3]))
    end

    test "a version 3 expression that does not read" do
      assert {:error, %Tempo.ParseError{}} =
               Meta.decode_interval(~s({"v":3,"expression":"not-a-date"}))
    end

    test "a version 3 expression that is a duration" do
      assert {:error, {:unexpected_expression, %Tempo.Duration{}}} =
               Meta.decode_interval(~s({"v":3,"expression":"P1D"}))
    end

    test "member metadata that does not match the members" do
      assert {:error, {:invalid_members_metadata, [%{}]}} =
               Meta.decode_interval(
                 ~s({"v":3,"expression":"{2026Y6M1D,2026Y6M10D}","members":[{}]})
               )
    end
  end
end
