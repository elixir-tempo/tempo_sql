# Tempo SQL

[![Hex.pm](https://img.shields.io/hexpm/v/ex_tempo_sql.svg)](https://hex.pm/packages/ex_tempo_sql)

Ecto types and migration helpers that persist [Tempo](https://github.com/elixir-tempo/tempo) intervals and interval sets as PostgreSQL `tstzrange` / `tstzmultirange` values.

Tempo models time as intervals, not instants. PostgreSQL models the same shape natively — a `tstzrange` **is** a bounded span with the half-open `[lower, upper)` convention, and `tstzmultirange` (PG 14+) is a set of disjoint spans. `tempo_sql` is the adapter between them: a Tempo interval dumps straight to a Postgrex range, loads straight back, and participates in Postgres range queries (`@>`, `&&`, `-|-`) as first-class values.

## Installation

Add `ex_tempo_sql` to your deps:

```elixir
def deps do
  [
    {:ex_tempo, "~> 2.0"},
    {:ex_tempo_sql, "~> 0.3"},
    {:ecto_sql, "~> 3.13"},
    {:postgrex, "~> 0.19"}
  ]
end
```

Requires PostgreSQL 14 or later for `tstzmultirange`. `tstzrange` alone works on PostgreSQL 9.2+.

Requires **Erlang/OTP 27 or later**, inherited from `ex_tempo`. Elixir 1.17 and later are supported.

## Quick start

### 1. Migration

```elixir
defmodule MyApp.Repo.Migrations.AddMeetings do
  use Ecto.Migration
  import Tempo.SQL.Migration

  def change do
    create table(:meetings) do
      add :name, :string
      add_interval :window, null: false
    end

    create_interval_index :meetings, :window
  end
end
```

### 2. Schema

```elixir
defmodule MyApp.Meeting do
  use Ecto.Schema

  schema "meetings" do
    field :name, :string
    field :window, Tempo.Ecto.Interval
  end
end
```

### 3. Insert and query

```elixir
import Ecto.Query
import Tempo.Ecto.QueryAPI
import Tempo.Sigils

standup = ~o"2026-06-15T09:00/2026-06-15T10:00"
Repo.insert!(%MyApp.Meeting{name: "Standup", window: standup})

{:ok, search} = Tempo.Ecto.Interval.dump(~o"2026-06-15T09:30/2026-06-15T09:45")

Repo.all(from m in MyApp.Meeting, where: overlaps(m.window, ^search), select: m.name)
#=> ["Standup"]
```

> *The meetings whose **window overlaps** the half hour from 9:30.*

## Ecto types

**Plain range — the span only:**

| Type                       | Stores                                                         | Postgres column    |
|----------------------------|----------------------------------------------------------------|--------------------|
| `Tempo.Ecto.Interval`      | an expression of one span: a value or an interval              | `tstzrange`        |
| `Tempo.Ecto.IntervalSet`   | an expression with a last span: a set, a bounded recurrence    | `tstzmultirange`   |
| `Tempo.Ecto.Tempo`         | as `Tempo.Ecto.Interval`, under the name kept for older schemas | `tstzrange`        |

**Composite — the whole expression, read back as it was written:**

| Type                          | Stores                                     | Postgres column    |
|-------------------------------|--------------------------------------------|--------------------|
| `Tempo.Ecto.TempoRange`       | any expression with ISO 8601 text          | `tempo_range`      |
| `Tempo.Ecto.TempoMultirange`  | any expression with ISO 8601 text          | `tempo_multirange` |

Use the composite types when the plain-range mode's losses hurt — recurrences, qualifications (`:uncertain`, `:approximate`), calendars other than the Gregorian, zones, metadata, or the resolution a value was written to. The composite stores the stretch the expression covers, so range queries still find it, beside its ISO 8601 text. See the [storage contract guide](https://hexdocs.pm/ex_tempo_sql/storage-contract.html#composite-mode--tempo_range-and-tempo_multirange) for setup and trade-offs.

An end written to a date is read through it, so a value or an interval is stored as the instants it runs between: `~o"2026-06-15/2026-06-20"` is the six days, the range `[2026-06-15 00:00, 2026-06-21 00:00)`, and `~o"2026"` is the year, `[2026-01-01 00:00, 2027-01-01 00:00)`. A plain range keeps no resolution, so the year comes back as the instants that bound it unless the column declares one.

### The `:resolution` field option

All three plain types accept a `:resolution` field option that writes loaded ends to a named unit — `:year`, `:month`, `:day`, `:hour`, `:minute`, or `:second` (the default):

```elixir
schema "reports" do
  field :reporting_year,  Tempo.Ecto.Interval, resolution: :year
  field :daily_window,    Tempo.Ecto.Interval, resolution: :day
  field :meeting_window,  Tempo.Ecto.Interval   # to the second
end
```

A column declared `resolution: :year` loads a range of whole years as the years it holds (`2026/2026` for the range of 2026), whatever the underlying `tstzrange` stored — it's a caller-side assertion about column contents, not a heuristic. See the [storage contract guide](https://hexdocs.pm/ex_tempo_sql/storage-contract.html#preserving-resolution--the-options) for the caveats.

## Query API

`Tempo.Ecto.QueryAPI` gives you Allen-named fragments over Postgres range operators:

| Macro                      | Postgres operator | Meaning                                              |
|----------------------------|-------------------|------------------------------------------------------|
| `contains(a, b)`           | `@>`              | `a` fully contains `b`                               |
| `overlaps(a, b)`           | `&&`              | `a` and `b` share any instant                        |
| `meets(a, b)`              | `-|-`             | `a` is immediately adjacent to `b`                   |
| `strictly_before(a, b)`    | `<<`              | `a` ends strictly before `b` starts (Allen precedes) |
| `strictly_after(a, b)`     | `>>`              | `a` starts strictly after `b` ends                   |

## Migration helpers

`Tempo.SQL.Migration` exposes three macros:

```elixir
add_interval :window                # → add :window, :tstzrange
add_interval_set :busy_times        # → add :busy_times, :tstzmultirange
create_interval_index :meetings, :window  # GiST index — required for range-operator speed
```

All three are thin delegates — you can also write the raw `add :window, :tstzrange` form.

## Storage contract

**Not every Tempo expression can be stored as a Postgres range.** Tempo expresses things that `tstzrange` / `tstzmultirange` cannot: qualifications, recurrences with no end, calendars other than the Gregorian, values with no year. The plain types are *explicit* about this — rather than silently lose information, they return `:error` from `dump/1`, which surfaces as an `Ecto.ChangeError` at insert time.

For the full mapping — what is kept, what is dropped, what is refused — see the [**Storage contract guide**](https://hexdocs.pm/ex_tempo_sql/storage-contract.html). The summary:

### What **is** storable

* **A value or an interval with a year** under `Tempo.Ecto.Interval`, stored as the instants it runs between.

* **An interval open at one end** — `~o"2026-06-15/.."` or `~o"../2026-06-15"` — as a range unbounded on that side.

* **A set, a bounded recurrence, or a value that names several** (`~o"2026Y{6,8}M"`) under `Tempo.Ecto.IntervalSet`, one range a span. Postgres keeps a multirange's adjacent ranges as one, so a recurrence's back-to-back occurrences come back joined.

* **A value at a time shift** (`Z`, `+02:00`), or in a named zone where the application configures a time zone database, stored as the UTC instants it is.

### What is **not** storable by the plain types (returns `:error`)

* An expression of several spans under `Tempo.Ecto.Interval`, and a recurrence with no end under `Tempo.Ecto.IntervalSet`.

* An interval unbounded on both sides.

* A qualified value (`:uncertain`, `:approximate`) — Postgres ranges have no notion of uncertainty.

* A value of a calendar other than the Gregorian — convert it first with `Tempo.to_calendar/2`.

* A value with no year (`~o"T09/T17"`), which has no instant to store.

* An empty set — use a NULL column if you need "no set".

### What is **lossy on round-trip**

A plain range keeps the span and nothing else. A loaded value is Gregorian and at UTC, its ends to the second or to the column's `:resolution`. Lost on the way are the expression's metadata, its zone (an expression in a zone comes back at UTC), and the resolution it was written to. The composite types keep all of these.

## Testing against a live database

The test suite needs a PostgreSQL 14+ instance. Configure `config/test.exs` to point at it:

```elixir
config :ex_tempo_sql, Tempo.SQL.Repo,
  adapter: Ecto.Adapters.Postgres,
  database: "tempo_sql_test",
  username: "...",
  hostname: "localhost",
  pool: Ecto.Adapters.SQL.Sandbox,
  priv: "test/support"
```

`mix test` is aliased to run `ecto.drop / ecto.create / ecto.migrate` before the suite.

## License

Apache-2.0. See [LICENSE.md](https://github.com/elixir-tempo/tempo_sql/blob/v0.3.0/LICENSE.md).
