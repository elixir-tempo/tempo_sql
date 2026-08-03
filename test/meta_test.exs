defmodule Tempo.SQL.MetaTest do
  use ExUnit.Case, async: true

  alias Tempo.Interval
  alias Tempo.SQL.Meta

  describe "encode/decode round-trip — the shapes the plain-range types reject" do
    test "year-resolution implicit span survives" do
      year = Tempo.from_iso8601!("2026")
      {:ok, interval} = Interval.new(from: year, to: Tempo.from_iso8601!("2027"))

      json = interval |> Meta.encode_interval() |> IO.iodata_to_binary()
      {:ok, loaded} = Meta.decode_interval(json)

      # The loaded `from` endpoint still has only a year token.
      assert loaded.from.time == [year: 2026]
      assert loaded.to.time == [year: 2027]
    end

    test "qualified (uncertain) endpoint survives" do
      {:ok, interval} = Tempo.from_iso8601("1984?/2004~")

      json = interval |> Meta.encode_interval() |> IO.iodata_to_binary()
      {:ok, loaded} = Meta.decode_interval(json)

      assert loaded.from.qualification == :uncertain
      assert loaded.to.qualification == :approximate
    end

    test "recurrence rule survives" do
      {:ok, interval} = Tempo.from_iso8601("R5/2022-01-01/P1M")

      json = interval |> Meta.encode_interval() |> IO.iodata_to_binary()
      {:ok, loaded} = Meta.decode_interval(json)

      assert loaded.recurrence == 5
      assert %Tempo.Duration{} = loaded.duration
    end

    test "user metadata passes through when JSON-serialisable" do
      from = Tempo.from_iso8601!("2026-06-15T09:00:00")
      to = Tempo.from_iso8601!("2026-06-15T10:00:00")

      interval = %Tempo.Interval{
        from: from,
        to: to,
        metadata: %{"source" => "calendar-import", "priority" => 3}
      }

      json = interval |> Meta.encode_interval() |> IO.iodata_to_binary()
      {:ok, loaded} = Meta.decode_interval(json)

      assert loaded.metadata == %{"source" => "calendar-import", "priority" => 3}
    end
  end

  describe "encode_interval/1" do
    test "produces a string with the expected top-level keys" do
      from = Tempo.from_iso8601!("2026-06-15T09:00:00")
      to = Tempo.from_iso8601!("2026-06-15T10:00:00")
      {:ok, interval} = Interval.new(from: from, to: to)

      decoded = interval |> Meta.encode_interval() |> IO.iodata_to_binary() |> Meta.decode_json()

      assert Map.has_key?(decoded, "v")
      assert Map.has_key?(decoded, "from")
      assert Map.has_key?(decoded, "to")
      assert Map.has_key?(decoded, "recurrence")
      assert decoded["v"] == 2
      assert decoded["recurrence"] == 1
      assert decoded["direction"] == 1
    end

    test "unbounded endpoints encode as the ISO 8601 open marker" do
      to = Tempo.from_iso8601!("2026-06-15T10:00:00")
      {:ok, interval} = Interval.new(from: :undefined, to: to)

      decoded = interval |> Meta.encode_interval() |> IO.iodata_to_binary() |> Meta.decode_json()

      assert decoded["from"] == ".."
      assert is_binary(decoded["to"])
    end
  end

  describe "open-ended versus absent endpoints" do
    # Tempo distinguishes two things a `to` can be when it is not a
    # datetime, and they are not interchangeable: `:undefined` is an
    # explicitly open end (`2022-01-01/..`), while `nil` is no end at
    # all, as on a recurring interval that takes its extent from a
    # duration. Encoding both as JSON null loses the difference, and
    # the value that comes back cannot be rendered.

    defp round_trip(interval) do
      {:ok, loaded} =
        interval
        |> Meta.encode_interval()
        |> IO.iodata_to_binary()
        |> Meta.decode_interval()

      loaded
    end

    test "a recurring interval keeps its absent end, and can still be rendered" do
      {:ok, recurring} = Tempo.from_iso8601("R5/2022-01-01/P1M")
      assert recurring.to == nil

      loaded = round_trip(recurring)

      assert loaded.to == nil
      assert Tempo.to_iso8601(loaded) == Tempo.to_iso8601(recurring)
    end

    test "an open-ended interval keeps its open end" do
      {:ok, open} = Interval.new(from: Tempo.from_iso8601!("2022-01-01"), to: :undefined)

      loaded = round_trip(open)

      assert loaded.to == :undefined
      assert Tempo.to_iso8601(loaded) == Tempo.to_iso8601(open)
    end

    test "an open start is distinguished from an absent one" do
      {:ok, open} = Interval.new(from: :undefined, to: Tempo.from_iso8601!("2022-01-01"))

      assert round_trip(open).from == :undefined
    end
  end

  describe "version 1 rows still decode" do
    # 0.1.0 wrote no `..` marker and read every null endpoint as
    # open-ended. Those rows must keep decoding the way they always
    # have — that reading is all the information they carry.
    test "a null endpoint in a v1 row reads as open-ended" do
      v1 = ~s({"v":1,"from":"2022Y1M1D","to":null,"recurrence":1,"direction":1})

      assert {:ok, interval} = Meta.decode_interval(v1)
      assert interval.to == :undefined
    end

    test "a v2 row reads a null endpoint as absent instead" do
      v2 = ~s({"v":2,"from":"2022Y1M1D","to":null,"recurrence":1,"direction":1})

      assert {:ok, interval} = Meta.decode_interval(v2)
      assert interval.to == nil
    end

    test "a row with no version at all is treated as v1" do
      unversioned = ~s({"from":"2022Y1M1D","to":null})

      assert {:ok, interval} = Meta.decode_interval(unversioned)
      assert interval.to == :undefined
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

    test "JSON that is not an object at all" do
      assert {:error, {:invalid_meta_shape, [1, 2, 3]}} = Meta.decode_interval(~s([1,2,3]))
    end
  end

  describe "unbounded recurrence" do
    test "an infinite recurrence survives the round-trip" do
      {:ok, forever} = Tempo.from_iso8601("R/2022-01-01/P1M")

      json = forever |> Meta.encode_interval() |> IO.iodata_to_binary()

      assert Meta.decode_json(json)["recurrence"] == "infinity"
      assert {:ok, loaded} = Meta.decode_interval(json)
      assert loaded.recurrence == :infinity
    end
  end
end
