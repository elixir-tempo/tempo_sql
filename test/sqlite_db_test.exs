defmodule Tempo.SQL.SQLiteDBTest do
  use ExUnit.Case, async: false

  # Tempo.Ecto.SQLite.TempoRange end to end, through a SQLite repository:
  # round trips, refusals, the query macros held to the answers the
  # PostgreSQL range operators give on the same values, and the indexes
  # the migration helper creates.

  import Ecto.Query
  import Tempo.Sigils

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Changeset
  alias Tempo.Ecto.QueryAPI.Composite, as: PostgresQuery
  alias Tempo.Ecto.SQLite.QueryAPI, as: SQLiteQuery
  alias Tempo.SQL.Conversion
  alias Tempo.SQL.Repo
  alias Tempo.SQL.SQLiteRepo
  alias Tempo.SQL.Test.{FidelityMeeting, SQLiteMeeting, SQLiteShop}

  require PostgresQuery
  require SQLiteQuery

  setup do
    :ok = Sandbox.checkout(SQLiteRepo)
    :ok = Sandbox.checkout(Repo)
  end

  defp column_text(table, column, id) do
    %{rows: [[text]]} =
      SQL.query!(SQLiteRepo, "SELECT #{column} FROM #{table} WHERE id = ?", [id])

    text
  end

  describe "round trips" do
    test "an expression on the UTC line comes back as it was written" do
      for window <- [
            ~o"2026-06-15T09:00Z/2026-06-15T10:00Z",
            ~o"2026-06-15T09:00/2026-06-15T10:00[Europe/Paris]",
            ~o"{2026-06-01T09Z,2026-06-10T09Z}",
            ~o"R3/2026-06-01T09:00Z/P1W",
            ~o"R/2026-06-01T09:00Z/P1W",
            ~o"2026-06-15T09:00Z/.."
          ] do
        meeting = SQLiteRepo.insert!(%SQLiteMeeting{name: "m", window: window})
        assert SQLiteRepo.get!(SQLiteMeeting, meeting.id).window == window
      end
    end

    test "a floating expression comes back floating, qualifications and metadata kept" do
      hours = Tempo.put_metadata(~o"2026-06-15T09:00/2026-06-15T17:00", %{"till" => 2})

      for value <- [hours, ~o"2026", ~o"1984?/2004~", ~o"R/2026-06-01T09/P1D"] do
        shop = SQLiteRepo.insert!(%SQLiteShop{name: "s", hours: value})
        assert SQLiteRepo.get!(SQLiteShop, shop.id).hours == value
      end
    end

    test "the column holds the document's bounds, which SQLite reads as integers" do
      meeting =
        SQLiteRepo.insert!(%SQLiteMeeting{
          name: "m",
          window: ~o"2026-06-15T09:00Z/2026-06-15T10:00Z"
        })

      %{rows: [[lower, upper]]} =
        SQL.query!(
          SQLiteRepo,
          "SELECT json_extract(window, '$.lo'), json_extract(window, '$.hi') FROM meetings WHERE id = ?",
          [meeting.id]
        )

      assert {lower, upper} ==
               {DateTime.to_unix(~U[2026-06-15 09:00:00Z]),
                DateTime.to_unix(~U[2026-06-15 10:00:00Z])}

      assert column_text("meetings", "window", meeting.id) =~ ~s("frame":"utc")
    end
  end

  describe "refusals" do
    test "a value of the other frame is a changeset error naming the frame to declare" do
      changeset = Changeset.cast(%SQLiteMeeting{}, %{window: ~o"2026-06-15"}, [:window])

      refute changeset.valid?
      assert {message, _details} = changeset.errors[:window]
      assert message =~ "frame: :floating"

      changeset = Changeset.cast(%SQLiteShop{}, %{hours: ~o"2026-06-15T09Z"}, [:hours])
      assert {message, _details} = changeset.errors[:hours]
      assert message =~ "frame: :utc"
    end

    test "a value of the other frame inserted without a changeset raises Ecto's error" do
      assert_raise Ecto.ChangeError, fn ->
        SQLiteRepo.insert!(%SQLiteMeeting{name: "m", window: ~o"2026-06-15"})
      end
    end

    test "an expression with no place on the time line is refused" do
      assert_raise Ecto.ChangeError, fn ->
        SQLiteRepo.insert!(%SQLiteShop{name: "s", hours: ~o"T09/T17"})
      end
    end

    test "the indexes refuse text that is not JSON, as SQLite evaluates them on a write" do
      meeting =
        SQLiteRepo.insert!(%SQLiteMeeting{name: "m", window: ~o"2026-06-15T09Z/2026-06-15T10Z"})

      assert_raise Exqlite.Error, ~r/malformed JSON/, fn ->
        SQL.query!(
          SQLiteRepo,
          "UPDATE meetings SET window = 'not json' WHERE id = ?",
          [meeting.id]
        )
      end
    end

    test "a row of JSON that is not a document fails to load, as Ecto reports a type's error" do
      meeting =
        SQLiteRepo.insert!(%SQLiteMeeting{name: "m", window: ~o"2026-06-15T09Z/2026-06-15T10Z"})

      SQL.query!(
        SQLiteRepo,
        ~s|UPDATE meetings SET window = '{"v": 2}' WHERE id = ?|,
        [meeting.id]
      )

      assert_raise ArgumentError, fn -> SQLiteRepo.get!(SQLiteMeeting, meeting.id) end
    end
  end

  describe "the query macros" do
    defp sqlite_names(query) do
      query
      |> select([m], m.name)
      |> SQLiteRepo.all()
      |> Enum.sort()
    end

    defp postgres_names(query) do
      query
      |> select([m], m.name)
      |> Repo.all()
      |> Enum.sort()
    end

    @windows [
      {"early", ~o"2026-06-15T07:00Z/2026-06-15T09:00Z"},
      {"standup", ~o"2026-06-15T09:00Z/2026-06-15T09:15Z"},
      {"morning", ~o"2026-06-15T09:00Z/2026-06-15T12:00Z"},
      {"lunch", ~o"2026-06-15T12:00Z/2026-06-15T13:00Z"},
      {"afternoon", ~o"2026-06-15T13:00Z/2026-06-15T17:00Z"},
      {"from noon", ~o"2026-06-15T12:00Z/.."}
    ]

    @probes [
      ~o"2026-06-15T09:00Z/2026-06-15T12:00Z",
      ~o"2026-06-15T09:05Z/2026-06-15T09:10Z",
      ~o"2026-06-15T12:00Z/2026-06-15T13:00Z",
      ~o"2026-06-15T06:00Z/2026-06-15T07:00Z",
      ~o"2026-06-15T17:00Z/2026-06-15T18:00Z"
    ]

    setup do
      for {name, window} <- @windows do
        SQLiteRepo.insert!(%SQLiteMeeting{name: name, window: window})
        Repo.insert!(%FidelityMeeting{name: name, window: window})
      end

      :ok
    end

    test "overlaps, contains, meets, strictly_before and strictly_after answer as PostgreSQL does" do
      for expression <- @probes do
        {:ok, probe} = SQLiteQuery.probe(expression)
        {:ok, range} = Conversion.interval_to_queryable_range(expression)

        pairs = [
          {from(m in SQLiteMeeting, where: SQLiteQuery.overlaps(m.window, ^probe)),
           from(m in FidelityMeeting, where: PostgresQuery.overlaps(m.window, ^range))},
          {from(m in SQLiteMeeting, where: SQLiteQuery.contains(m.window, ^probe)),
           from(m in FidelityMeeting, where: PostgresQuery.contains(m.window, ^range))},
          {from(m in SQLiteMeeting, where: SQLiteQuery.meets(m.window, ^probe)),
           from(m in FidelityMeeting, where: PostgresQuery.meets(m.window, ^range))},
          {from(m in SQLiteMeeting, where: SQLiteQuery.strictly_before(m.window, ^probe)),
           from(m in FidelityMeeting, where: PostgresQuery.strictly_before(m.window, ^range))},
          {from(m in SQLiteMeeting, where: SQLiteQuery.strictly_after(m.window, ^probe)),
           from(m in FidelityMeeting, where: PostgresQuery.strictly_after(m.window, ^range))}
        ]

        for {sqlite, postgres} <- pairs do
          assert sqlite_names(sqlite) == postgres_names(postgres),
                 "#{Tempo.to_iso8601!(expression)}: #{inspect(sqlite)}"
        end
      end
    end

    test "a set matches where one of its members does, not in the gaps between them" do
      SQLiteRepo.insert!(%SQLiteMeeting{
        name: "two days",
        window: ~o"{2026-06-01T09Z/2026-06-01T10Z,2026-06-10T09Z/2026-06-10T10Z}"
      })

      {:ok, gap} = SQLiteQuery.probe(~o"2026-06-05T09Z/2026-06-05T10Z")
      {:ok, second_day} = SQLiteQuery.probe(~o"2026-06-10T09:30Z/2026-06-10T09:45Z")

      assert sqlite_names(from(m in SQLiteMeeting, where: SQLiteQuery.overlaps(m.window, ^gap))) ==
               []

      assert sqlite_names(
               from(m in SQLiteMeeting, where: SQLiteQuery.contains(m.window, ^second_day))
             ) == ["two days"]
    end

    test "a floating column is queried with a floating probe" do
      SQLiteRepo.insert!(%SQLiteShop{
        name: "bakery",
        hours: ~o"2026-06-15T07:00/2026-06-15T13:00"
      })

      SQLiteRepo.insert!(%SQLiteShop{name: "bar", hours: ~o"2026-06-15T17:00/2026-06-15T23:00"})

      {:ok, half_past_nine} = SQLiteQuery.probe(~o"2026-06-15T09:30/2026-06-15T09:31", :floating)

      assert from(s in SQLiteShop, where: SQLiteQuery.contains(s.hours, ^half_past_nine))
             |> select([s], s.name)
             |> SQLiteRepo.all() == ["bakery"]
    end
  end

  describe "the indexes" do
    test "a query bounding the stretch is answered from an index on the bounds" do
      {:ok, probe} = SQLiteQuery.probe(~o"2026-06-15T09:00Z/2026-06-15T12:00Z")
      query = from(m in SQLiteMeeting, where: SQLiteQuery.strictly_before(m.window, ^probe))
      {sql, parameters} = SQL.to_sql(:all, SQLiteRepo, query)

      %{rows: rows} =
        SQL.query!(SQLiteRepo, "EXPLAIN QUERY PLAN " <> sql, parameters)

      plan = Enum.map_join(rows, "\n", &List.last/1)

      assert plan =~ "meetings_window_hi_index"
    end
  end
end
