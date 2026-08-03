# Tempo SQL

[![Hex.pm](https://img.shields.io/hexpm/v/ex_tempo_sql.svg)](https://hex.pm/packages/ex_tempo_sql)

Ecto types and migration helpers that persist [Tempo](https://github.com/elixir-tempo/tempo) intervals and interval sets as PostgreSQL `tstzrange` / `tstzmultirange` values.

Tempo models time as intervals, not instants. PostgreSQL models the same shape natively — a `tstzrange` **is** a bounded span with the half-open `[lower, upper)` convention, and `tstzmultirange` (PG 14+) is a set of disjoint spans. `tempo_sql` is the adapter between them: a Tempo interval dumps straight to a Postgrex range, loads straight back, and participates in Postgres range queries (`@>`, `&&`, `-|-`) as first-class values.

## Installation

Add `ex_tempo_sql` to your deps:

```elixir
def deps do
  [
    {:ex_tempo, "~> 1.1"},
    {:ex_tempo_sql, "~> 0.1"},
    {:ecto_sql, "~> 3.13"},
    {:postgrex, "~> 0.19"}
  ]
end
```

Requires PostgreSQL 14 or later for `tstzmultirange`. `tstzrange` alone works on PostgreSQL 9.2+.

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
window = Tempo.Interval.new!(
  from: Tempo.from_iso8601!("2026-06-15T09:00:00"),
  to:   Tempo.from_iso8601!("2026-06-15T10:00:00")
)

%MyApp.Meeting{name: "Standup", window: window} |> Repo.insert!()

import Ecto.Query
import Tempo.Ecto.QueryAPI

search = Tempo.Interval.new!(
  from: Tempo.from_iso8601!("2026-06-15T09:30:00"),
  to:   Tempo.from_iso8601!("2026-06-15T09:45:00")
)

{:ok, search_range} = Tempo.Ecto.Interval.dump(search)

Repo.all(
  from m in MyApp.Meeting,
    where: overlaps(m.window, ^search_range),
    select: m.name
)
#=> ["Standup"]
```

*Meetings whose **window overlaps** the search range — the pipeline reads like the English sentence.*

## Ecto types

**Plain range — span only, lossy round-trip:**

| Type                       | Stores                          | Postgres column    |
|----------------------------|---------------------------------|--------------------|
| `Tempo.Ecto.Interval`      | `%Tempo.Interval{}`             | `tstzrange`        |
| `Tempo.Ecto.IntervalSet`   | `%Tempo.IntervalSet{}`          | `tstzmultirange`   |
| `Tempo.Ecto.Tempo`         | bare `%Tempo{}` (implicit span) | `tstzrange`        |

**Composite — full Tempo shape, byte-exact round-trip:**

| Type                          | Stores                 | Postgres column    |
|-------------------------------|------------------------|--------------------|
| `Tempo.Ecto.TempoRange`       | `%Tempo.Interval{}`    | `tempo_range`      |
| `Tempo.Ecto.TempoMultirange`  | `%Tempo.IntervalSet{}` | `tempo_multirange` |

Use the composite types when the plain-range mode's losses hurt — recurrence rules, qualifications (`:uncertain`, `:approximate`), non-Gregorian calendars, zone identifiers, or the implicit-vs-explicit-span distinction. See the [storage contract guide](https://hexdocs.pm/ex_tempo_sql/storage-contract.html#composite-mode--tempo_range-and-tempo_multirange) for setup and trade-offs.

`Tempo.Ecto.Tempo` materialises a partial Tempo value (`~o"2026Y"`, `~o"2026Y-06M"`) to its explicit span before writing. On load you get back a `%Tempo.Interval{}` — the "it was just a year token" fact doesn't round-trip.

### The `:resolution` field option

All three types accept a `:resolution` field option that truncates loaded endpoints to a named Tempo component — `:year`, `:month`, `:day`, `:hour`, `:minute`, or `:second` (the default):

```elixir
schema "reports" do
  field :reporting_year,  Tempo.Ecto.Interval, resolution: :year
  field :daily_window,    Tempo.Ecto.Interval, resolution: :day
  field :meeting_window,  Tempo.Ecto.Interval   # full second resolution
end
```

A column declared `resolution: :year` always loads as year-resolution Tempos, regardless of what the underlying `tstzrange` stored — it's a caller-side assertion about column contents, not a heuristic. See the [storage contract guide](https://hexdocs.pm/ex_tempo_sql/storage-contract.html#preserving-resolution--the-options) for the caveats.

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

**Not every Tempo value can be stored as a Postgres range.** Tempo expresses things that `tstzrange` / `tstzmultirange` cannot: qualifications, recurrence rules, non-Gregorian calendars, multi-valued token slots. `tempo_sql` is *explicit* about this — rather than silently lose information, it returns `:error` from `dump/1`, which surfaces as an `Ecto.ChangeError` at insert time.

For the full mapping — what is retained, what is dropped, what is rejected, and how Tempo's resolution-by-omission convention interacts with Postgres ranges — see the [**Storage contract guide**](https://hexdocs.pm/ex_tempo_sql/storage-contract.html). The summary:

### What **is** storable

* **Fully-anchored `Tempo.Interval` values** — `from` and `to` are `%Tempo{}` values whose token lists contain enough of year / month / day / hour / minute / second to be materialised to a `NaiveDateTime`. Sub-fields default to calendar zero (month 1, day 1, hour/minute/second 0), so `~o"2026Y"` used as an endpoint lands on `2026-01-01T00:00:00Z`.

* **Partial open-ended intervals** — `from: :undefined` or `to: :undefined` (but not both) map to unbounded range sides (`(, upper]` or `[lower, )`).

* **`Tempo.IntervalSet` values** with at least one member, where every member is itself storable under the rules above. The set's own `:metadata` field is dropped.

* **UTC or offset-shifted Tempo values** — a `:shift` offset is applied to land on UTC before handing the value to Postgres.

### What is **not** storable (returns `:error`)

* Intervals with `recurrence != 1` or a `repeat_rule` — materialise them first via `Tempo.to_interval/1` into a `Tempo.IntervalSet` and store that instead.

* Intervals that are unbounded on both sides.

* Tempo endpoints with a `:qualification` (`:uncertain`, `:approximate`) — Postgres ranges have no notion of uncertainty.

* Tempo endpoints on a non-Gregorian calendar — no automatic conversion; convert first.

* Tempo endpoints with multi-valued token slots (`day_of_week: [1, 3, 5]`, `day: 1..15`) — these don't collapse to a single instant.

* Ordinal-date (`year: 2026, day: 75`) or week-date (`year: 2026, week: 10, day_of_week: 3`) endpoints — materialise to a calendar date first via `Tempo.to_date/1` / `Tempo.to_interval/1`.

* Empty `Tempo.IntervalSet` values — use a NULL column if you need "no set".

### What is **lossy on round-trip** (round 1)

For the initial release, a stored value and a loaded value match **only** on their interval shape, not their metadata. Round-trip discards:

* `Tempo.Interval.metadata`

* `Tempo.IntervalSet.metadata`

* Tempo `:extended` metadata (zone_id, IXDTF tags)

* The distinction between an *implicit* span (`~o"2026Y"`) and its materialisation (`2026-01-01..2027-01-01`)

A loaded value is always Gregorian, UTC (shift `[hour: 0]`, zone_id `"Etc/UTC"`). A future release will add a `:text` storage variant (ISO 8601 in a text column) that preserves the original Tempo shape byte-for-byte for callers who need perfect round-trip.

## Testing against a live database

`mix test` runs the unit tests in-process (no DB). To exercise the integration tests in `test/db_test.exs`, configure `config/test.exs` to point at a PostgreSQL 14+ instance:

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

Apache-2.0. See [LICENSE.md](LICENSE.md).
