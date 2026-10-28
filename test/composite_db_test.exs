defmodule Tempo.SQL.CompositeDBTest do
  use Tempo.SQL.Test.RepoCase

  import Tempo.Ecto.QueryAPI.Composite
  import Tempo.Sigils

  alias Tempo.IntervalSet

  defp stored(schema, field, value, name_field, name) do
    row = Repo.insert!(struct(schema, [{name_field, name}, {field, value}]))

    schema
    |> Repo.get!(row.id)
    |> Map.fetch!(field)
  end

  describe "Tempo.Ecto.TempoRange end-to-end" do
    test "reads back an interval exactly as it went in" do
      window = ~o"2026-06-15T09:00:00/2026-06-15T10:00:00"

      assert stored(FidelityMeeting, :window, window, :name, "Standup") == window
    end

    test "reads back a value at the resolution it was written to" do
      # The plain-range types read a range back at the column's
      # resolution; the composite keeps the expression's own.
      assert stored(FidelityMeeting, :window, ~o"2026-06", :name, "June") == ~o"2026-06"
    end

    test "reads back qualifications" do
      history = ~o"1984?/2004~"

      assert stored(FidelityMeeting, :window, history, :name, "Uncertain history") == history
    end

    test "reads back a recurrence" do
      series = ~o"R5/2022-01-01/P1M"

      assert stored(FidelityMeeting, :window, series, :name, "Five-month series") == series
    end

    test "reads back a recurrence with no end, and finds it by its first occurrence" do
      monthly = ~o"R/2022-01-01/P1M"

      assert stored(FidelityMeeting, :window, monthly, :name, "Monthly") == monthly

      probe = %Postgrex.Range{
        lower: ~U[2030-06-01 00:00:00Z],
        upper: ~U[2030-06-02 00:00:00Z],
        lower_inclusive: true,
        upper_inclusive: false
      }

      assert Repo.all(
               from(m in FidelityMeeting, where: overlaps(m.window, ^probe), select: m.name)
             ) ==
               ["Monthly"]
    end

    test "reads back an expression of another calendar" do
      hebrew = ~o"5786-01-01/5786-01-10[u-ca=hebrew]"

      assert stored(FidelityMeeting, :window, hebrew, :name, "Nisan") == hebrew
    end

    test "queries with composite `contains` — the range column stays queryable" do
      Repo.insert!(%FidelityMeeting{
        name: "Morning",
        window: ~o"2026-06-15T09:00:00/2026-06-15T10:00:00"
      })

      Repo.insert!(%FidelityMeeting{
        name: "Afternoon",
        window: ~o"2026-06-15T14:00:00/2026-06-15T15:00:00"
      })

      instant_at_930 = %Postgrex.Range{
        lower: ~U[2026-06-15 09:30:00Z],
        upper: ~U[2026-06-15 09:30:00Z],
        lower_inclusive: true,
        upper_inclusive: true
      }

      names =
        Repo.all(
          from(m in FidelityMeeting,
            where: contains(m.window, ^instant_at_930),
            select: m.name
          )
        )

      assert names == ["Morning"]
    end
  end

  describe "Tempo.Ecto.TempoMultirange end-to-end" do
    test "reads back a set of anchored intervals" do
      busy =
        IntervalSet.new!([
          ~o"2026-06-15T09:00:00/2026-06-15T10:00:00",
          ~o"2026-06-15T14:00:00/2026-06-15T15:00:00"
        ])

      assert stored(FidelityCalendar, :busy_times, busy, :owner, "alice") == busy
    end

    test "reads back a set whose members have qualifications" do
      set = IntervalSet.new!([~o"1984?/1985", ~o"1990/1991~"])

      assert stored(FidelityCalendar, :busy_times, set, :owner, "archivist") == set
    end

    test "reads back each member's metadata" do
      set =
        IntervalSet.new!([
          Tempo.put_metadata(~o"2026-06-15T09:00:00/2026-06-15T10:00:00", %{"title" => "standup"}),
          Tempo.put_metadata(~o"2026-06-15T14:00:00/2026-06-15T15:00:00", %{"title" => "review"})
        ])

      fetched = stored(FidelityCalendar, :busy_times, set, :owner, "team")

      assert Enum.map(IntervalSet.members(fetched), &Tempo.metadata/1) == [
               %{"title" => "standup"},
               %{"title" => "review"}
             ]
    end
  end
end
