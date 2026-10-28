defmodule Tempo.SQL.DBTest do
  use Tempo.SQL.Test.RepoCase

  import Tempo.Ecto.QueryAPI
  import Tempo.Sigils

  describe "Tempo.Ecto.Interval end-to-end" do
    test "inserts and reads back a meeting window" do
      meeting =
        Repo.insert!(%Meeting{
          name: "Standup",
          window: ~o"2026-06-15T09:00:00/2026-06-15T10:00:00"
        })

      fetched = Repo.get!(Meeting, meeting.id)

      # A tstzrange has no "no zone", so the window comes back in UTC.
      assert fetched.window == ~o"2026-06-15T09:00:00Z/2026-06-15T10:00:00Z"
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
      Repo.insert!(%Meeting{name: "Offsite", window: ~o"2026-06-15/2026-06-17"})

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
      %Meeting{name: "Deadline", window: ~o"../2026-06-15T17:00:00"}
      |> Repo.insert!()

      [row] = Repo.all(from(m in Meeting, where: m.name == "Deadline"))
      assert row.window == ~o"../2026-06-15T17:00:00Z"
    end

    test "queries with `contains` — meetings whose window contains a point" do
      Repo.insert!(%Meeting{name: "Morning", window: ~o"2026-06-15T09:00:00/2026-06-15T10:00:00"})

      Repo.insert!(%Meeting{
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
          from(m in Meeting,
            where: contains(m.window, ^instant_at_930),
            select: m.name
          )
        )

      assert names == ["Morning"]
    end

    test "queries with `overlaps` — meetings whose window overlaps a search range" do
      Repo.insert!(%Meeting{name: "A", window: ~o"2026-06-15T09:00:00/2026-06-15T10:00:00"})
      Repo.insert!(%Meeting{name: "B", window: ~o"2026-06-15T09:30:00/2026-06-15T10:30:00"})
      Repo.insert!(%Meeting{name: "C", window: ~o"2026-06-15T14:00:00/2026-06-15T15:00:00"})

      {:ok, search_range} = Tempo.Ecto.Interval.dump(~o"2026-06-15T09:45:00/2026-06-15T10:15:00")

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
        Repo.insert!(%Meeting{name: "Recurring", window: ~o"R5/2026-06-15T09:00:00/PT1H"})
      end
    end
  end

  describe "Tempo.Ecto.IntervalSet end-to-end" do
    test "inserts and reads back a busy-times multirange" do
      busy =
        Tempo.IntervalSet.new!([
          ~o"2026-06-15T09:00:00/2026-06-15T10:00:00",
          ~o"2026-06-15T14:00:00/2026-06-15T15:00:00"
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
        Repo.insert!(%Calendar{owner: "standups", busy_times: ~o"R3/2026-06-15T09:00:00/PT15M"})

      fetched = Repo.get!(Calendar, row.id)

      assert Tempo.IntervalSet.members(fetched.busy_times) == [
               ~o"2026-06-15T09:00:00Z/2026-06-15T09:45:00Z"
             ]
    end

    test "queries with `overlaps` on a multirange column" do
      alice_busy =
        Tempo.IntervalSet.new!([
          ~o"2026-06-15T09:00:00/2026-06-15T10:00:00",
          ~o"2026-06-15T14:00:00/2026-06-15T15:00:00"
        ])

      bob_busy = Tempo.IntervalSet.new!([~o"2026-06-15T11:00:00/2026-06-15T12:00:00"])

      Repo.insert!(%Calendar{owner: "alice", busy_times: alice_busy})
      Repo.insert!(%Calendar{owner: "bob", busy_times: bob_busy})

      search_set = Tempo.IntervalSet.new!([~o"2026-06-15T09:30:00/2026-06-15T09:45:00"])
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
end
