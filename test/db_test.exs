defmodule Tempo.SQL.DBTest do
  use Tempo.SQL.Test.RepoCase

  import Tempo.Ecto.QueryAPI
  import Tempo.Sigils

  alias Tempo.SQL.Conversion

  describe "Tempo.Ecto.Interval end-to-end" do
    test "inserts and reads back a meeting window" do
      meeting =
        Repo.insert!(%Meeting{
          name: "Standup",
          window: ~o"2026-06-15T09:00:00Z/2026-06-15T10:00:00Z"
        })

      fetched = Repo.get!(Meeting, meeting.id)

      assert fetched.window == ~o"2026-06-15T09:00:00Z/2026-06-15T10:00:00Z"
    end

    test "refuses to insert a floating window, which is not on the UTC line" do
      assert_raise Ecto.ChangeError, fn ->
        Repo.insert!(%Meeting{
          name: "Standup",
          window: ~o"2026-06-15T09:00:00/2026-06-15T10:00:00"
        })
      end
    end

    test "stores a window in a named zone as the instants it is" do
      Repo.insert!(%Meeting{
        name: "New York standup",
        window: ~o"2026-06-15T09:00/2026-06-15T10:00[America/New_York]"
      })

      [row] = Repo.all(from(m in Meeting, where: m.name == "New York standup"))

      # The zone's name is not stored: the window comes back at UTC.
      assert row.window == ~o"2026-06-15T13:00:00Z/2026-06-15T14:00:00Z"
    end

    test "stores a window of days as the instants it runs between" do
      Repo.insert!(%Meeting{name: "Offsite", window: ~o"2026-06-15/2026-06-17[Etc/UTC]"})

      [row] = Repo.all(from(m in Meeting, where: m.name == "Offsite"))

      assert Tempo.Interval.instants(row.window) ==
               {:ok, {~U[2026-06-15 00:00:00Z], ~U[2026-06-18 00:00:00Z]}}

      [upper] =
        Repo.all(
          from(m in Meeting, where: m.name == "Offsite", select: fragment("upper(?)", m.window))
        )

      assert DateTime.compare(upper, ~U[2026-06-18 00:00:00Z]) == :eq
    end

    test "stores an open-start window as a range unbounded on the left" do
      %Meeting{name: "Deadline", window: ~o"../2026-06-15T17:00:00Z"}
      |> Repo.insert!()

      [row] = Repo.all(from(m in Meeting, where: m.name == "Deadline"))
      assert row.window == ~o"../2026-06-15T17:00:00Z"
    end

    test "queries with `contains` — meetings whose window contains a point" do
      Repo.insert!(%Meeting{
        name: "Morning",
        window: ~o"2026-06-15T09:00:00Z/2026-06-15T10:00:00Z"
      })

      Repo.insert!(%Meeting{
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
          from(m in Meeting,
            where: contains(m.window, ^instant_at_930),
            select: m.name
          )
        )

      assert names == ["Morning"]
    end

    test "queries with `overlaps` — meetings whose window overlaps a search range" do
      Repo.insert!(%Meeting{name: "A", window: ~o"2026-06-15T09:00:00Z/2026-06-15T10:00:00Z"})
      Repo.insert!(%Meeting{name: "B", window: ~o"2026-06-15T09:30:00Z/2026-06-15T10:30:00Z"})
      Repo.insert!(%Meeting{name: "C", window: ~o"2026-06-15T14:00:00Z/2026-06-15T15:00:00Z"})

      {:ok, search_range} =
        Tempo.Ecto.Interval.dump(~o"2026-06-15T09:45:00Z/2026-06-15T10:15:00Z")

      names =
        Repo.all(
          from(m in Meeting,
            where: overlaps(m.window, ^search_range),
            select: m.name,
            order_by: m.name
          )
        )

      assert names == ["A", "B"]
    end

    test "refuses to insert a recurrence, which is no single range" do
      # Dump fails → Ecto raises a ChangeError on insert. This is the
      # system boundary where the storage contract is enforced.
      assert_raise Ecto.ChangeError, fn ->
        Repo.insert!(%Meeting{name: "Recurring", window: ~o"R5/2026-06-15T09:00:00Z/PT1H"})
      end
    end
  end

  describe "Tempo.Ecto.IntervalSet end-to-end" do
    test "inserts and reads back a busy-times multirange" do
      busy =
        Tempo.IntervalSet.new!([
          ~o"2026-06-15T09:00:00Z/2026-06-15T10:00:00Z",
          ~o"2026-06-15T14:00:00Z/2026-06-15T15:00:00Z"
        ])

      row = Repo.insert!(%Calendar{owner: "alice", busy_times: busy})
      fetched = Repo.get!(Calendar, row.id)

      assert Tempo.IntervalSet.members(fetched.busy_times) == [
               ~o"2026-06-15T09:00:00Z/2026-06-15T10:00:00Z",
               ~o"2026-06-15T14:00:00Z/2026-06-15T15:00:00Z"
             ]
    end

    test "stores a bounded recurrence as its occurrences, which Postgres joins" do
      # A recurrence's occurrences are back to back, and a multirange
      # keeps adjacent ranges as one.
      row =
        Repo.insert!(%Calendar{owner: "standups", busy_times: ~o"R3/2026-06-15T09:00:00Z/PT15M"})

      fetched = Repo.get!(Calendar, row.id)

      assert Tempo.IntervalSet.members(fetched.busy_times) == [
               ~o"2026-06-15T09:00:00Z/2026-06-15T09:45:00Z"
             ]
    end

    test "queries with `overlaps` on a multirange column" do
      alice_busy =
        Tempo.IntervalSet.new!([
          ~o"2026-06-15T09:00:00Z/2026-06-15T10:00:00Z",
          ~o"2026-06-15T14:00:00Z/2026-06-15T15:00:00Z"
        ])

      bob_busy = Tempo.IntervalSet.new!([~o"2026-06-15T11:00:00Z/2026-06-15T12:00:00Z"])

      Repo.insert!(%Calendar{owner: "alice", busy_times: alice_busy})
      Repo.insert!(%Calendar{owner: "bob", busy_times: bob_busy})

      search_set = Tempo.IntervalSet.new!([~o"2026-06-15T09:30:00Z/2026-06-15T09:45:00Z"])
      {:ok, search_multirange} = Tempo.Ecto.IntervalSet.dump(search_set)

      owners =
        Repo.all(
          from(c in Calendar,
            where: overlaps(c.busy_times, ^search_multirange),
            select: c.owner
          )
        )

      assert owners == ["alice"]
    end
  end

  describe "Tempo.Ecto.Interval on the floating frame end-to-end" do
    test "inserts and reads back a shop's opening hours as floating" do
      row =
        Repo.insert!(%OpeningHours{
          shop: "bakery",
          hours: ~o"2026-06-15T07:00:00/2026-06-15T13:00:00"
        })

      fetched = Repo.get!(OpeningHours, row.id)

      assert fetched.hours == ~o"2026-06-15T07:00:00/2026-06-15T13:00:00"
    end

    test "stores floating hours in a tsrange with naive bounds" do
      Repo.insert!(%OpeningHours{shop: "bakery", hours: ~o"2026-06-15/2026-06-16"})

      [{lower, upper}] =
        Repo.all(
          from(o in OpeningHours,
            where: o.shop == "bakery",
            select: {fragment("lower(?)", o.hours), fragment("upper(?)", o.hours)}
          )
        )

      assert NaiveDateTime.compare(lower, ~N[2026-06-15 00:00:00]) == :eq
      assert NaiveDateTime.compare(upper, ~N[2026-06-17 00:00:00]) == :eq
    end

    test "refuses to insert hours in a zone into a floating column" do
      assert_raise Ecto.ChangeError, fn ->
        Repo.insert!(%OpeningHours{
          shop: "bakery",
          hours: ~o"2026-06-15T07:00/2026-06-15T13:00[Europe/Paris]"
        })
      end
    end

    test "refuses to insert hours at a time shift into a floating column" do
      assert_raise Ecto.ChangeError, fn ->
        Repo.insert!(%OpeningHours{
          shop: "bakery",
          hours: ~o"2026-06-15T07:00:00Z/2026-06-15T13:00:00Z"
        })
      end
    end

    test "queries with `contains` — shops open at a floating moment" do
      Repo.insert!(%OpeningHours{
        shop: "bakery",
        hours: ~o"2026-06-15T07:00:00/2026-06-15T13:00:00"
      })

      Repo.insert!(%OpeningHours{
        shop: "bar",
        hours: ~o"2026-06-15T17:00:00/2026-06-15T23:00:00"
      })

      {:ok, eight_oclock} =
        Conversion.interval_to_range(~o"2026-06-15T08:00:00/PT1S", :floating)

      shops =
        Repo.all(
          from(o in OpeningHours,
            where: contains(o.hours, ^eight_oclock),
            select: o.shop
          )
        )

      assert shops == ["bakery"]
    end

    test "queries with `overlaps` — shops open during a floating search range" do
      Repo.insert!(%OpeningHours{
        shop: "bakery",
        hours: ~o"2026-06-15T07:00:00/2026-06-15T13:00:00"
      })

      Repo.insert!(%OpeningHours{
        shop: "cafe",
        hours: ~o"2026-06-15T12:00:00/2026-06-15T18:00:00"
      })

      Repo.insert!(%OpeningHours{
        shop: "bar",
        hours: ~o"2026-06-15T17:00:00/2026-06-15T23:00:00"
      })

      {:ok, lunchtime} =
        Tempo.Ecto.Interval.dump(
          ~o"2026-06-15T12:30:00/2026-06-15T13:30:00",
          nil,
          Tempo.Ecto.Interval.init(frame: :floating)
        )

      shops =
        Repo.all(
          from(o in OpeningHours,
            where: overlaps(o.hours, ^lunchtime),
            select: o.shop,
            order_by: o.shop
          )
        )

      assert shops == ["bakery", "cafe"]
    end
  end

  describe "Tempo.Ecto.IntervalSet on the floating frame end-to-end" do
    test "inserts and reads back a week of floating opening hours" do
      weekly =
        Tempo.IntervalSet.new!([
          ~o"2026-06-15T07:00:00/2026-06-15T13:00:00",
          ~o"2026-06-16T07:00:00/2026-06-16T13:00:00"
        ])

      row = Repo.insert!(%OpeningHours{shop: "bakery", weekly: weekly})
      fetched = Repo.get!(OpeningHours, row.id)

      assert Tempo.IntervalSet.members(fetched.weekly) == [
               ~o"2026-06-15T07:00:00/2026-06-15T13:00:00",
               ~o"2026-06-16T07:00:00/2026-06-16T13:00:00"
             ]
    end

    test "refuses to insert a set on the UTC line into a floating column" do
      weekly = Tempo.IntervalSet.new!([~o"2026-06-15T07:00:00Z/2026-06-15T13:00:00Z"])

      assert_raise Ecto.ChangeError, fn ->
        Repo.insert!(%OpeningHours{shop: "bakery", weekly: weekly})
      end
    end

    test "refuses to insert a floating set into a column on the UTC line" do
      busy = Tempo.IntervalSet.new!([~o"2026-06-15T09:00:00/2026-06-15T10:00:00"])

      assert_raise Ecto.ChangeError, fn ->
        Repo.insert!(%Calendar{owner: "alice", busy_times: busy})
      end
    end

    test "queries with `overlaps` on a floating multirange column" do
      bakery = Tempo.IntervalSet.new!([~o"2026-06-15T07:00:00/2026-06-15T13:00:00"])
      bar = Tempo.IntervalSet.new!([~o"2026-06-15T17:00:00/2026-06-15T23:00:00"])

      Repo.insert!(%OpeningHours{shop: "bakery", weekly: bakery})
      Repo.insert!(%OpeningHours{shop: "bar", weekly: bar})

      search = Tempo.IntervalSet.new!([~o"2026-06-15T18:00:00/2026-06-15T19:00:00"])

      {:ok, search_multirange} =
        Tempo.Ecto.IntervalSet.dump(search, nil, Tempo.Ecto.IntervalSet.init(frame: :floating))

      shops =
        Repo.all(
          from(o in OpeningHours,
            where: overlaps(o.weekly, ^search_multirange),
            select: o.shop
          )
        )

      assert shops == ["bar"]
    end
  end
end
