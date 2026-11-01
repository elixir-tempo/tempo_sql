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
      window = ~o"2026-06-15T09:00:00Z/2026-06-15T10:00:00Z"

      assert stored(FidelityMeeting, :window, window, :name, "Standup") == window
    end

    test "reads back a value at the resolution it was written to" do
      # The plain-range types read a range back at the column's
      # resolution; the composite keeps the expression's own.
      june = ~o"2026-06[Europe/Paris]"

      assert stored(FidelityMeeting, :window, june, :name, "June") == june
    end

    test "reads back qualifications" do
      history = ~o"1984?/2004~[Europe/Paris]"

      assert stored(FidelityMeeting, :window, history, :name, "Uncertain history") == history
    end

    test "reads back a recurrence" do
      series = ~o"R5/2022-01-01/P1M[Europe/Paris]"

      assert stored(FidelityMeeting, :window, series, :name, "Five-month series") == series
    end

    test "reads back a recurrence with no end, and finds it by its first occurrence" do
      monthly = ~o"R/2022-01-01/P1M[Europe/Paris]"

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
      hebrew = ~o"5786-01-01/5786-01-10[Asia/Jerusalem][u-ca=hebrew]"

      assert stored(FidelityMeeting, :window, hebrew, :name, "Nisan") == hebrew
    end

    test "reads back an expression in a named zone" do
      new_york = ~o"2026-06-15T09:00/2026-06-15T10:00[America/New_York]"

      assert stored(FidelityMeeting, :window, new_york, :name, "New York") == new_york
    end

    test "queries with composite `contains` — the range column stays queryable" do
      Repo.insert!(%FidelityMeeting{
        name: "Morning",
        window: ~o"2026-06-15T09:00:00Z/2026-06-15T10:00:00Z"
      })

      Repo.insert!(%FidelityMeeting{
        name: "Afternoon",
        window: ~o"2026-06-15T14:00:00Z/2026-06-15T15:00:00Z"
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
          ~o"2026-06-15T09:00:00Z/2026-06-15T10:00:00Z",
          ~o"2026-06-15T14:00:00Z/2026-06-15T15:00:00Z"
        ])

      assert stored(FidelityCalendar, :busy_times, busy, :owner, "alice") == busy
    end

    test "reads back a set whose members have qualifications" do
      set = IntervalSet.new!([~o"1984?/1985[Europe/Paris]", ~o"1990/1991~[Europe/Paris]"])

      assert stored(FidelityCalendar, :busy_times, set, :owner, "archivist") == set
    end

    test "reads back each member's metadata" do
      set =
        IntervalSet.new!([
          Tempo.put_metadata(~o"2026-06-15T09:00:00Z/2026-06-15T10:00:00Z", %{
            "title" => "standup"
          }),
          Tempo.put_metadata(~o"2026-06-15T14:00:00Z/2026-06-15T15:00:00Z", %{"title" => "review"})
        ])

      fetched = stored(FidelityCalendar, :busy_times, set, :owner, "team")

      assert Enum.map(IntervalSet.members(fetched), &Tempo.metadata/1) == [
               %{"title" => "standup"},
               %{"title" => "review"}
             ]
    end
  end

  describe "Tempo.Ecto.TempoRange on the floating frame end-to-end" do
    test "reads back floating hours exactly as they went in" do
      hours = ~o"2026-06-15T07:00:00/2026-06-15T13:00:00"

      assert stored(FidelityOpeningHours, :hours, hours, :shop, "bakery") == hours
    end

    test "reads back a floating value at the resolution it was written to" do
      assert stored(FidelityOpeningHours, :hours, ~o"2026-06", :shop, "June") == ~o"2026-06"
    end

    test "reads back floating qualifications" do
      history = ~o"1984?/2004~"

      assert stored(FidelityOpeningHours, :hours, history, :shop, "archive") == history
    end

    test "reads back a floating recurrence" do
      series = ~o"R5/2022-01-01/P1M"

      assert stored(FidelityOpeningHours, :hours, series, :shop, "market") == series
    end

    test "reads back a floating expression of another calendar" do
      hebrew = ~o"5786-01-01/5786-01-10[u-ca=hebrew]"

      assert stored(FidelityOpeningHours, :hours, hebrew, :shop, "Nisan") == hebrew
    end

    test "refuses to insert a value in a zone into a floating composite" do
      assert_raise Ecto.ChangeError, fn ->
        Repo.insert!(%FidelityOpeningHours{
          shop: "bakery",
          hours: ~o"2026-06-15T07:00/2026-06-15T13:00[Europe/Paris]"
        })
      end
    end

    test "refuses to insert a floating value into a composite on the UTC line" do
      assert_raise Ecto.ChangeError, fn ->
        Repo.insert!(%FidelityMeeting{
          name: "Standup",
          window: ~o"2026-06-15T09:00:00/2026-06-15T10:00:00"
        })
      end
    end

    test "queries with composite `contains` on floating hours" do
      Repo.insert!(%FidelityOpeningHours{
        shop: "bakery",
        hours: ~o"2026-06-15T07:00:00/2026-06-15T13:00:00"
      })

      Repo.insert!(%FidelityOpeningHours{
        shop: "bar",
        hours: ~o"2026-06-15T17:00:00/2026-06-15T23:00:00"
      })

      eight_oclock = %Postgrex.Range{
        lower: ~N[2026-06-15 08:00:00],
        upper: ~N[2026-06-15 08:00:00],
        lower_inclusive: true,
        upper_inclusive: true
      }

      shops =
        Repo.all(
          from(o in FidelityOpeningHours,
            where: contains(o.hours, ^eight_oclock),
            select: o.shop
          )
        )

      assert shops == ["bakery"]
    end

    test "finds a floating recurrence with no end by its first occurrence" do
      monthly = ~o"R/2022-01-01/P1M"

      assert stored(FidelityOpeningHours, :hours, monthly, :shop, "market") == monthly

      probe = %Postgrex.Range{
        lower: ~N[2030-06-01 00:00:00],
        upper: ~N[2030-06-02 00:00:00],
        lower_inclusive: true,
        upper_inclusive: false
      }

      shops =
        Repo.all(
          from(o in FidelityOpeningHours,
            where: overlaps(o.hours, ^probe),
            select: o.shop
          )
        )

      assert shops == ["market"]
    end
  end

  describe "Tempo.Ecto.TempoMultirange on the floating frame end-to-end" do
    test "reads back a set of floating intervals" do
      weekly =
        IntervalSet.new!([
          ~o"2026-06-15T07:00:00/2026-06-15T13:00:00",
          ~o"2026-06-16T07:00:00/2026-06-16T13:00:00"
        ])

      assert stored(FidelityOpeningHours, :weekly, weekly, :shop, "bakery") == weekly
    end

    test "reads back each floating member's metadata" do
      weekly =
        IntervalSet.new!([
          Tempo.put_metadata(~o"2026-06-15T07:00:00/2026-06-15T13:00:00", %{"day" => "monday"}),
          Tempo.put_metadata(~o"2026-06-16T07:00:00/2026-06-16T13:00:00", %{"day" => "tuesday"})
        ])

      fetched = stored(FidelityOpeningHours, :weekly, weekly, :shop, "bakery")

      assert Enum.map(IntervalSet.members(fetched), &Tempo.metadata/1) == [
               %{"day" => "monday"},
               %{"day" => "tuesday"}
             ]
    end

    test "refuses to insert a set on the UTC line into a floating composite" do
      weekly = IntervalSet.new!([~o"2026-06-15T07:00:00Z/2026-06-15T13:00:00Z"])

      assert_raise Ecto.ChangeError, fn ->
        Repo.insert!(%FidelityOpeningHours{shop: "bakery", weekly: weekly})
      end
    end

    test "refuses to insert a floating set into a composite on the UTC line" do
      busy = IntervalSet.new!([~o"2026-06-15T09:00:00/2026-06-15T10:00:00"])

      assert_raise Ecto.ChangeError, fn ->
        Repo.insert!(%FidelityCalendar{owner: "alice", busy_times: busy})
      end
    end
  end
end
