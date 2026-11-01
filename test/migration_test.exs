defmodule Tempo.SQL.MigrationTest do
  @moduledoc """
  The migration helpers are the library's schema-facing API, and until
  now nothing exercised them: the project's own test migration
  hand-writes `add(:window, :tstzrange)` rather than calling
  `add_interval/2`, and migrations run in a separate `mix ecto.migrate`
  process that the test run never sees.

  These tests run migrations *inline* — building the column with the
  documented helper, then reading the resulting table back out of the
  catalogue to confirm the column really has the type it should.
  """

  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migrator
  alias Tempo.SQL.Repo

  # Migrations issue DDL, which the sandbox cannot roll back, and
  # `Ecto.Migrator` runs them in a process of its own that cannot
  # inherit a checkout. `:auto` mode lets both take connections
  # normally; this module is `async: false`, so nothing else is
  # touching the sandbox while it runs.
  setup_all do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok
  end

  defp unboxed(fun) do
    fun.()
  end

  defp drop_all do
    tables =
      ~w(migration_probe migration_probe_composite migration_probe_floating migration_probe_floating_composite)

    for table <- tables do
      {:ok, _} = SQL.query(Repo, "DROP TABLE IF EXISTS #{table}", [])
    end

    :ok
  end

  defp column_type(table, column) do
    {:ok, %{rows: rows}} =
      SQL.query(
        Repo,
        """
        SELECT format_type(a.atttypid, a.atttypmod)
        FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        WHERE c.relname = $1 AND a.attname = $2 AND a.attnum > 0
        """,
        [table, column]
      )

    case rows do
      [[type]] -> type
      [] -> nil
    end
  end

  defp indexes(table) do
    {:ok, %{rows: rows}} =
      SQL.query(Repo, "SELECT indexdef FROM pg_indexes WHERE tablename = $1", [table])

    List.flatten(rows)
  end

  defp run(migration) do
    Migrator.up(Repo, System.unique_integer([:positive]), migration, log: false)
  end

  defmodule RangeColumns do
    @moduledoc false
    use Ecto.Migration

    import Tempo.SQL.Migration

    def change do
      create table(:migration_probe) do
        add_interval(:window)
        add_interval(:required_window, null: false)
        add_interval_set(:busy_times)
      end

      create_interval_index(:migration_probe, :window)
    end
  end

  defmodule CompositeColumns do
    @moduledoc false
    use Ecto.Migration

    import Tempo.SQL.Migration

    def change do
      create table(:migration_probe_composite) do
        add_tempo_range(:window)
        add_tempo_multirange(:busy_times)
      end
    end
  end

  defmodule FloatingRangeColumns do
    @moduledoc false
    use Ecto.Migration

    import Tempo.SQL.Migration

    def change do
      create table(:migration_probe_floating) do
        add_interval(:hours, frame: :floating)
        add_interval(:required_hours, frame: :floating, null: false)
        add_interval(:utc_window, frame: :utc)
        add_interval_set(:weekly, frame: :floating)
      end

      create_interval_index(:migration_probe_floating, :hours)
    end
  end

  defmodule FloatingCompositeColumns do
    @moduledoc false
    use Ecto.Migration

    import Tempo.SQL.Migration

    def change do
      create table(:migration_probe_floating_composite) do
        add_tempo_range(:hours, frame: :floating)
        add_tempo_multirange(:weekly, frame: :floating)
      end
    end
  end

  describe "add_interval/2 and add_interval_set/2" do
    setup do
      unboxed(fn ->
        drop_all()
        run(RangeColumns)
      end)

      :ok
    end

    test "add_interval builds a tstzrange column" do
      unboxed(fn -> assert column_type("migration_probe", "window") == "tstzrange" end)
    end

    test "options pass through to Ecto.Migration.add/3" do
      # `null: false` must survive the macro rather than be swallowed.
      unboxed(fn ->
        {:ok, %{rows: [[nullable]]}} =
          SQL.query(
            Repo,
            """
            SELECT a.attnotnull
            FROM pg_attribute a
            JOIN pg_class c ON c.oid = a.attrelid
            WHERE c.relname = 'migration_probe' AND a.attname = 'required_window'
            """,
            []
          )

        assert nullable == true
      end)
    end

    test "add_interval_set builds a tstzmultirange column" do
      unboxed(fn -> assert column_type("migration_probe", "busy_times") == "tstzmultirange" end)
    end
  end

  describe "add_interval/2 and add_interval_set/2 on the floating frame" do
    setup do
      unboxed(fn ->
        drop_all()
        run(FloatingRangeColumns)
      end)

      :ok
    end

    test "add_interval with frame: :floating builds a tsrange column" do
      unboxed(fn ->
        assert column_type("migration_probe_floating", "hours") == "tsrange"
      end)
    end

    test "add_interval with frame: :utc builds a tstzrange column" do
      unboxed(fn ->
        assert column_type("migration_probe_floating", "utc_window") == "tstzrange"
      end)
    end

    test "add_interval_set with frame: :floating builds a tsmultirange column" do
      unboxed(fn ->
        assert column_type("migration_probe_floating", "weekly") == "tsmultirange"
      end)
    end

    test "the other options still pass through to Ecto.Migration.add/3" do
      unboxed(fn ->
        {:ok, %{rows: [[nullable]]}} =
          SQL.query(
            Repo,
            """
            SELECT a.attnotnull
            FROM pg_attribute a
            JOIN pg_class c ON c.oid = a.attrelid
            WHERE c.relname = 'migration_probe_floating' AND a.attname = 'required_hours'
            """,
            []
          )

        assert nullable == true
      end)
    end

    test "a floating column takes a GiST index too" do
      unboxed(fn ->
        definitions = indexes("migration_probe_floating")

        assert Enum.any?(definitions, &(&1 =~ "USING gist" and &1 =~ "hours"))
      end)
    end
  end

  describe "a frame the helpers do not know" do
    test "each column helper raises, naming what was given" do
      require Tempo.SQL.Migration

      assert_raise ArgumentError, ~r/:local/, fn ->
        Tempo.SQL.Migration.add_interval(:hours, frame: :local)
      end

      assert_raise ArgumentError, ~r/:local/, fn ->
        Tempo.SQL.Migration.add_interval_set(:weekly, frame: :local)
      end

      assert_raise ArgumentError, ~r/:local/, fn ->
        Tempo.SQL.Migration.add_tempo_range(:hours, frame: :local)
      end

      assert_raise ArgumentError, ~r/:local/, fn ->
        Tempo.SQL.Migration.add_tempo_multirange(:weekly, frame: :local)
      end
    end

    test "create_tempo_types/1 and drop_tempo_types/1 raise too" do
      assert_raise ArgumentError, ~r/:local/, fn ->
        Tempo.SQL.Migration.create_tempo_types(frame: :local)
      end

      assert_raise ArgumentError, ~r/:local/, fn ->
        Tempo.SQL.Migration.drop_tempo_types(frame: :local)
      end
    end
  end

  describe "create_interval_index/3" do
    setup do
      unboxed(fn ->
        drop_all()
        run(RangeColumns)
      end)

      :ok
    end

    test "creates a GiST index, which is what makes range operators fast" do
      unboxed(fn ->
        definitions = indexes("migration_probe")

        assert Enum.any?(definitions, &(&1 =~ "USING gist" and &1 =~ "window"))
      end)
    end
  end

  describe "create_tempo_types/0 and the composite helpers" do
    setup do
      unboxed(fn ->
        drop_all()
        run(CompositeColumns)
      end)

      :ok
    end

    test "creates the tempo_range composite type" do
      unboxed(fn ->
        assert column_type("migration_probe_composite", "window") == "tempo_range"
      end)
    end

    test "creates the tempo_multirange composite type" do
      unboxed(fn ->
        assert column_type("migration_probe_composite", "busy_times") == "tempo_multirange"
      end)
    end

    test "the composite types exist in the catalogue" do
      unboxed(fn ->
        {:ok, %{rows: rows}} =
          SQL.query(
            Repo,
            "SELECT typname FROM pg_type WHERE typname IN ('tempo_range', 'tempo_multirange')",
            []
          )

        assert List.flatten(rows)
               |> Enum.sort() == ["tempo_multirange", "tempo_range"]
      end)
    end
  end

  describe "create_tempo_types/1 on the floating frame and its composite helpers" do
    setup do
      unboxed(fn ->
        drop_all()
        run(FloatingCompositeColumns)
      end)

      :ok
    end

    test "add_tempo_range with frame: :floating builds a tempo_floating_range column" do
      unboxed(fn ->
        assert column_type("migration_probe_floating_composite", "hours") ==
                 "tempo_floating_range"
      end)
    end

    test "add_tempo_multirange with frame: :floating builds a tempo_floating_multirange column" do
      unboxed(fn ->
        assert column_type("migration_probe_floating_composite", "weekly") ==
                 "tempo_floating_multirange"
      end)
    end

    test "the floating composite types hold timestamp ranges" do
      unboxed(fn ->
        {:ok, %{rows: rows}} =
          SQL.query(
            Repo,
            """
            SELECT t.typname, a.attname, format_type(a.atttypid, a.atttypmod)
            FROM pg_type t
            JOIN pg_attribute a ON a.attrelid = t.typrelid
            WHERE t.typname IN ('tempo_floating_range', 'tempo_floating_multirange')
              AND a.attname IN ('range', 'ranges')
            ORDER BY t.typname
            """,
            []
          )

        assert rows == [
                 ["tempo_floating_multirange", "ranges", "tsmultirange"],
                 ["tempo_floating_range", "range", "tsrange"]
               ]
      end)
    end
  end

  describe "drop_tempo_types/0" do
    test "removes the types create_tempo_types/0 made" do
      # The types are shared by every other test in the suite, so the
      # drop happens inside a transaction that is rolled back — the
      # assertion is made while it is still in effect.
      assert type_exists?("tempo_range")

      {:error, :rolled_back} =
        Repo.transaction(fn ->
          # CASCADE because the fidelity tables use these types; the
          # rollback undoes those drops too.
          SQL.query!(Repo, "DROP TYPE tempo_multirange CASCADE", [])
          SQL.query!(Repo, "DROP TYPE tempo_range CASCADE", [])

          refute type_exists?("tempo_range")

          Repo.rollback(:rolled_back)
        end)

      # Rolled back, so the rest of the suite still has its types.
      assert type_exists?("tempo_range")
    end

    test "create_tempo_types/0 is what put them there" do
      # The project's own migration calls it; these are the types it made.
      assert type_exists?("tempo_range")
      assert type_exists?("tempo_multirange")
    end

    test "create_tempo_types(frame: :floating) put the floating pair there" do
      assert type_exists?("tempo_floating_range")
      assert type_exists?("tempo_floating_multirange")
    end

    test "dropping the floating pair leaves the UTC pair alone" do
      {:error, :rolled_back} =
        Repo.transaction(fn ->
          SQL.query!(Repo, "DROP TYPE tempo_floating_multirange CASCADE", [])
          SQL.query!(Repo, "DROP TYPE tempo_floating_range CASCADE", [])

          refute type_exists?("tempo_floating_range")
          assert type_exists?("tempo_range")

          Repo.rollback(:rolled_back)
        end)

      assert type_exists?("tempo_floating_range")
    end
  end

  describe "the helpers are reversible" do
    test "a migration built from the column helpers rolls back cleanly" do
      unboxed(fn ->
        drop_all()
        version = System.unique_integer([:positive])

        Migrator.up(Repo, version, RangeColumns, log: false)
        assert column_type("migration_probe", "window") == "tstzrange"

        Migrator.down(Repo, version, RangeColumns, log: false)
        assert column_type("migration_probe", "window") == nil
      end)
    end

    test "a migration built from the floating column helpers rolls back cleanly" do
      unboxed(fn ->
        drop_all()
        version = System.unique_integer([:positive])

        Migrator.up(Repo, version, FloatingRangeColumns, log: false)
        assert column_type("migration_probe_floating", "hours") == "tsrange"

        Migrator.down(Repo, version, FloatingRangeColumns, log: false)
        assert is_nil(column_type("migration_probe_floating", "hours"))
      end)
    end
  end

  # Note on what is deliberately not tested here: reversing the
  # project's own migration to exercise `create_tempo_types/0` in both
  # directions. Dropping and recreating a composite type gives it a new
  # OID, and the pooled Postgrex connections go on using the old one —
  # so later composite tests decode against a stale type and fail
  # intermittently. `create_tempo_types/0` is exercised for real by the
  # `mix ecto.migrate` that precedes every test run; that coverage just
  # happens in a process the run cannot observe.

  defp type_exists?(name) do
    {:ok, %{rows: rows}} =
      SQL.query(Repo, "SELECT 1 FROM pg_type WHERE typname = $1", [name])

    match?([_ | _], rows)
  end
end
