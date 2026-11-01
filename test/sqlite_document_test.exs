defmodule Tempo.SQL.SQLite.DocumentTest do
  use ExUnit.Case, async: true

  # The JSON document a SQLite column holds: the expression whole, beside the
  # integer bounds of its stretch and of each of its spans, on one frame.

  import Tempo.Sigils

  alias Tempo.SQL.JSON, as: StorageJSON
  alias Tempo.SQL.SQLite.Document
  alias Tempo.SQL.UnsupportedValueError

  @least -9_223_372_036_854_775_808
  @greatest 9_223_372_036_854_775_807

  defp document(expression, frame) do
    {:ok, json} = Document.encode(expression, frame)
    StorageJSON.decode!(json)
  end

  defp seconds(%DateTime{} = instant) do
    DateTime.to_unix(instant)
  end

  defp seconds(%NaiveDateTime{} = instant) do
    NaiveDateTime.diff(instant, ~N[1970-01-01 00:00:00])
  end

  describe "the bounds" do
    test "an interval on the UTC line is its instants in seconds since the epoch" do
      document = document(~o"2026-06-15T09:00Z/2026-06-15T10:00Z", :utc)

      assert document["lo"] == seconds(~U[2026-06-15 09:00:00Z])
      assert document["hi"] == seconds(~U[2026-06-15 10:00:00Z])
      assert document["frame"] == "utc"
    end

    test "a value in a named zone is the UTC instants it is" do
      document = document(~o"2026-06-15T09:00/2026-06-15T10:00[Europe/Paris]", :utc)

      assert document["lo"] == seconds(~U[2026-06-15 07:00:00Z])
    end

    test "a floating value is its times on the wall clock" do
      document = document(~o"2026-06-15/2026-06-20", :floating)

      assert document["lo"] == seconds(~N[2026-06-15 00:00:00])
      assert document["hi"] == seconds(~N[2026-06-21 00:00:00])
      assert document["frame"] == "floating"
    end

    test "a fraction of a second is rounded outward, so the bounds cover the expression" do
      document = document(~o"2026-06-15T09:00:00.25Z/2026-06-15T09:00:01.5Z", :utc)

      assert document["lo"] == seconds(~U[2026-06-15 09:00:00Z])
      assert document["hi"] == seconds(~U[2026-06-15 09:00:02Z])
    end

    test "a value before the epoch is rounded outward too" do
      document = document(~o"1969-12-31T23:59:59.5/1969-12-31T23:59:59.75", :floating)

      assert {document["lo"], document["hi"]} == {-1, 0}
    end

    test "an open end is the least or the greatest 64-bit integer" do
      assert %{"lo" => _from, "hi" => @greatest} =
               document(~o"2026-06-15T09:00Z/..", :utc)

      assert %{"lo" => @least} = document(~o"../2026-06-15", :floating)
    end
  end

  describe "the spans" do
    test "a set has a span for each member, and a stretch across them" do
      document = document(~o"{2026-06-01,2026-06-10}", :floating)

      first = [seconds(~N[2026-06-01 00:00:00]), seconds(~N[2026-06-02 00:00:00])]
      second = [seconds(~N[2026-06-10 00:00:00]), seconds(~N[2026-06-11 00:00:00])]

      assert document["spans"] == [first, second]
      assert [document["lo"], document["hi"]] == [hd(first), List.last(second)]
    end

    test "a bounded recurrence has a span for each occurrence" do
      document = document(~o"R3/2026-06-01T09:00Z/P1D", :utc)

      assert length(document["spans"]) == 3
    end

    test "a recurrence with no end has its stretch alone, open above" do
      document = document(~o"R/2026-06-01/P1W", :floating)

      assert document["hi"] == @greatest
      assert document["spans"] == [[document["lo"], @greatest]]
    end
  end

  describe "the expression, read back as it was written" do
    test "a value, an interval, a set and a recurrence round-trip" do
      for {expression, frame} <- [
            {~o"2026", :floating},
            {~o"2026-06-15T09:00Z/2026-06-15T10:00Z", :utc},
            {~o"{2026-06-01,2026-06-10}", :floating},
            {~o"R3/2026-06-01/P1W", :floating},
            {~o"1984?/2004~", :floating},
            {~o"2026-06-15T09:00/2026-06-15T10:00[Europe/Paris]", :utc}
          ] do
        {:ok, json} = Document.encode(expression, frame)
        assert Document.decode(json) == {:ok, expression}
      end
    end

    test "metadata comes back with string keys" do
      expression = Tempo.put_metadata(~o"2026-06-15", %{room: "A1"})
      {:ok, json} = Document.encode(expression, :floating)

      assert {:ok, read} = Document.decode(json)
      assert Tempo.metadata(read) == %{"room" => "A1"}
    end
  end

  describe "what is refused" do
    test "a value of the other frame, in either direction" do
      assert {:error, %UnsupportedValueError{reason: :frame}} =
               Document.encode(~o"2026-06-15", :utc)

      assert {:error, %UnsupportedValueError{reason: :frame}} =
               Document.encode(~o"2026-06-15T09Z", :floating)
    end

    test "an expression with no place on the time line" do
      assert {:error, %UnsupportedValueError{}} = Document.encode(~o"T09/T17", :floating)
      assert {:error, %UnsupportedValueError{}} = Document.encode(~o"../..", :floating)
      assert {:error, %UnsupportedValueError{}} = Document.encode(~o"P1D", :floating)
    end

    test "a frame that is none" do
      assert {:error, %ArgumentError{}} = Document.encode(~o"2026-06-15", :local)
    end

    test "a document that is not JSON, not of this shape, or of no expression is an error" do
      assert {:error, _exception} = Document.decode(~s({"v": 1, "meta":))
      assert {:error, {:invalid_document, _}} = Document.decode(~s({"v": 2, "meta": {}}))
      assert {:error, {:invalid_document, _}} = Document.decode(~s([1, 2]))
      assert {:error, {:invalid_document, nil}} = Document.decode(nil)

      assert {:error, _reason} =
               Document.decode(~s({"v": 1, "meta": {"v": 3, "expression": "not ISO 8601"}}))
    end
  end
end
