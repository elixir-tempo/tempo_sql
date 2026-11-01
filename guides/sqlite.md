# SQLite

SQLite has four storage classes — integer, real, text and blob — and no range type, so a Tempo expression cannot be stored there as PostgreSQL stores it. `Tempo.Ecto.SQLite.TempoRange` keeps it in one `TEXT` column instead: the expression whole, as it was written, beside the integer bounds of the time it covers. `Tempo.Ecto.SQLite.QueryAPI` asks Allen's questions of those bounds with plain comparisons, which an index on each bound answers.

## Installation

Add `ecto_sqlite3` beside `ex_tempo_sql`; Tempo SQL lists it as an optional dependency, so an application on PostgreSQL alone does not fetch it:

```elixir
def deps do
  [
    {:ex_tempo_sql, "~> 0.4"},
    {:ecto_sqlite3, "~> 0.26"}
  ]
end
```

The JSON functions the column is queried with are built into SQLite from 3.38; `exqlite`, which `ecto_sqlite3` runs on, bundles a later one. Nothing is loaded into SQLite: no extension, no function defined from Elixir.

## Setup

The migration adds the column and its indexes:

```elixir
defmodule MyApp.Repo.Migrations.CreateMeetings do
  use Ecto.Migration

  import Tempo.SQL.SQLite.Migration

  def change do
    create table(:meetings) do
      add :name, :string
      add_tempo_range :window
    end

    create_tempo_range_index :meetings, :window
  end
end
```

The schema names the type, and the frame of a field whose values have no zone:

```elixir
defmodule MyApp.Meeting do
  use Ecto.Schema

  schema "meetings" do
    field :name, :string
    field :window, Tempo.Ecto.SQLite.TempoRange
  end
end

defmodule MyApp.Shop do
  use Ecto.Schema

  schema "shops" do
    field :name, :string
    field :hours, Tempo.Ecto.SQLite.TempoRange, frame: :floating
  end
end
```

## What the column holds

The column holds a JSON document. Its `lo` and `hi` are the half-open bounds of the stretch the expression covers, in whole seconds; its `spans` are the bounds of each span; its `meta` is the expression's ISO 8601 text and metadata, from which it is read back:

```elixir
iex> import Tempo.Sigils
iex> {:ok, json} = Tempo.SQL.SQLite.Document.encode(~o"2026-06-15T09:00Z/2026-06-15T10:00Z")
iex> document = Tempo.SQL.JSON.decode!(json)
iex> {document["lo"], document["hi"]}
{1781514000, 1781517600}
iex> document["meta"]["expression"]
"2026Y6M15DT9H0MZ/T10H0MZ"
iex> Tempo.SQL.SQLite.Document.decode(json)
{:ok, ~o"2026-06-15T09:00Z/2026-06-15T10:00Z"}
```

> *The meeting is **stored as the seconds that bound it**, and **read back as it was written**.*

* **On the UTC frame**, the default, a bound is seconds since the Unix epoch at UTC, and a value in a zone or at a time shift is stored as the instants it is.

* **On the floating frame**, `frame: :floating`, a bound is seconds since 1970-01-01T00:00 on the wall clock, and a value with no zone and no time shift is stored as the times it is.

* **A fraction of a second** is rounded outward, so the bounds always cover the expression. The expression itself keeps its fraction.

* **An open end** is the least or the greatest 64-bit integer, so a comparison needs no case for it.

* **A recurrence with no end** has its stretch alone, from its first occurrence on.

A value of the other frame is refused, as on PostgreSQL: by `Ecto.Changeset.cast/4` as an error on the field that names the frame to declare, and by `dump` for a value inserted without a changeset. So is an expression with no place on the time line — a value with no year, a duration, an interval open at both ends.

## Queries

A query compares a column with a probe, the bounds of an expression on the column's frame, which `Tempo.Ecto.SQLite.QueryAPI.probe/2` makes:

```elixir
iex> import Tempo.Sigils
iex> Tempo.Ecto.SQLite.QueryAPI.probe(~o"2026-06-15T09:30Z/2026-06-15T09:45Z")
{:ok, %{lo: 1781515800, hi: 1781516700}}
iex> Tempo.Ecto.SQLite.QueryAPI.probe(~o"2026-06-15T09:30/2026-06-15T09:45", :floating)
{:ok, %{lo: 1781515800, hi: 1781516700}}
```

The probe is pinned with `^`, as a range is for the PostgreSQL macros:

```elixir
import Ecto.Query
import Tempo.Ecto.SQLite.QueryAPI

{:ok, quarter_hour} = probe(~o"2026-06-15T09:30Z/2026-06-15T09:45Z")

Repo.all(from m in MyApp.Meeting, where: overlaps(m.window, ^quarter_hour), select: m.name)
```

> *The meetings whose **window overlaps** the quarter hour from half past nine.*

| Macro                     | Matches a row whose                                   |
|---------------------------|-------------------------------------------------------|
| `overlaps(a, ^b)`         | spans share a second with `b`                         |
| `contains(a, ^b)`         | spans hold every second of `b` in one of them         |
| `meets(a, ^b)`            | stretch ends where `b` begins, or begins where it ends |
| `strictly_before(a, ^b)`  | stretch ends at or before `b` begins                  |
| `strictly_after(a, ^b)`   | stretch begins at or after `b` ends                   |

Each gives the answer the PostgreSQL operator gives for the same values; the test suite holds the two to each other. `overlaps` and `contains` test each span a set holds, so the gaps between its members match nothing.

## Indexes

`create_tempo_range_index/2` creates an expression index on each bound, `json_extract(column, '$.lo')` and `json_extract(column, '$.hi')`. A query that bounds either end of the stretch — every macro does — is answered from one of them, which `EXPLAIN QUERY PLAN` shows.

SQLite evaluates the indexes on every write, so with them in place it refuses text that is not JSON in the column at all.

## What it is not

* **Not a range type.** Set operations on stored expressions — a union of two rows, the free time between them — are Tempo's, after loading; SQL sees the bounds.

* **Not finer than a second.** Two spans within one second can match one probe.

* **Not an R\*Tree.** The bounds are B-tree indexes. For a large table of spans of very different lengths, an R\*Tree index may answer an overlap faster; the design in the repository's `plans/sqlite.md` sets out why it is not the default.
