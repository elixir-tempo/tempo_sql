# Storage contract

How Tempo expressions map to PostgreSQL range types, what survives a store-and-load cycle, and — importantly — what does not.

This is a reference document. Every claim here is enforced by `Tempo.SQL.Conversion` and `Tempo.SQL.Meta` and covered by the test suite.

## Two storage modes

`tempo_sql` offers two parallel storage strategies. Pick one per column:

| Strategy             | Ecto types                                         | PG types                           | Round-trip fidelity |
|----------------------|----------------------------------------------------|------------------------------------|---------------------|
| **Plain range**      | `Tempo.Ecto.Interval` / `.IntervalSet` / `.Tempo`  | `tstzrange` / `tstzmultirange`     | The span only       |
| **Composite**        | `Tempo.Ecto.TempoRange` / `.TempoMultirange`       | `tempo_range` / `tempo_multirange` | The whole expression |

**Pick plain range when** the downstream workflow only cares about the span — start, end, overlap relationships. Queries are native Postgres operators. Minimal schema overhead.

**Pick composite when** you need the expression back as it was written — qualifications, calendars other than the Gregorian, recurrences, zones, metadata, or the resolution a value was written to. The composite stores a queryable `tstzrange` *and* a `jsonb` meta column holding the expression's ISO 8601 text. Costs: a `CREATE TYPE` migration, a different column type, composite-aware query macros, and one extra column's worth of storage per row.

Most of the rest of this guide is about the plain-range mode, because the composite mode keeps the whole expression — the one-paragraph summary is "whatever you put in comes back as it was written, and range queries still work via `(column).range`". Composites have their own section at the end.

## The plain-range mapping

| Tempo expression                                                     | Ecto type                 | PostgreSQL column   |
|----------------------------------------------------------------------|---------------------------|---------------------|
| one span: a value (`~o"2026-06"`) or an interval                     | `Tempo.Ecto.Interval`     | `tstzrange`         |
| a last span: a set, a bounded recurrence, a value that names several | `Tempo.Ecto.IntervalSet`  | `tstzmultirange`    |
| one span, under the name older schemas use                           | `Tempo.Ecto.Tempo`        | `tstzrange`         |

`tstzrange` is a timezone-aware range of two `timestamptz` values. `tstzmultirange` (PostgreSQL 14+) is an ordered, disjoint set of `tstzrange` values. Both follow the half-open `[lower, upper)` convention, which is the convention every Tempo span has underneath — so adjacency, ordering, and emptiness all compose cleanly across the boundary.

An end written to a date is read through it, as it is said aloud: `~o"2026-06-15/2026-06-20"` is six days, and holds the 20th. It is stored as the instants it runs between, `[2026-06-15 00:00, 2026-06-21 00:00)`. An end written to the clock is a boundary: `~o"2026-06-15T09/2026-06-15T17"` is stored as `[09:00, 17:00)`. `Tempo.Interval.instants/1` gives the two instants any interval is stored as.

## What a round-trip looks like

A minimal setup, three Tempo values, pipeline through the type module:

```elixir
year    = ~o"2026"
meeting = ~o"2026-06-15T09:00/2026-06-15T10:00"
offset  = ~o"2026-06-15T09:00+02:00/2026-06-15T10:00+02:00"

{:ok, year_range}    = Tempo.Ecto.Interval.dump(year)
{:ok, meeting_range} = Tempo.Ecto.Interval.dump(meeting)
{:ok, offset_range}  = Tempo.Ecto.Interval.dump(offset)

Tempo.Ecto.Interval.load(year_range)
#=> {:ok, ~o"2026-01-01T00:00:00Z/2027-01-01T00:00:00Z"}

Tempo.Ecto.Interval.load(meeting_range)
#=> {:ok, ~o"2026-06-15T09:00:00Z/2026-06-15T10:00:00Z"}

Tempo.Ecto.Interval.load(offset_range)
#=> {:ok, ~o"2026-06-15T07:00:00Z/2026-06-15T08:00:00Z"}
```

> *The year is **stored as the instants that bound it**, and loads back as an interval between them — the "it was just a year" fact is gone. The meeting comes back on the same instants, at UTC. The meeting at `+02:00` comes back as the same instants at UTC, two hours earlier on the clock.*

That is the whole guide in one paragraph. The rest of this document makes each claim precise.

## What is retained

**For every storable expression,** the following survive a round-trip exactly:

* The instants each span begins and ends at, to the second.

* The half-open `[from, to)` convention. Adjacent spans remain adjacent, touching spans still touch.

* Open ends. `~o"2026-06-15T09:00/.."` is stored as a range with `upper: :unbound` (SQL `[lower, )`), and loads back with an open end. An open-ended booking like "everything after 9 on the 15th of June" round-trips as it went in.

* For `tstzmultirange`, the order of the spans. Postgres keeps a multirange's overlapping or adjacent ranges as one, so spans that touch come back joined: a recurrence's back-to-back occurrences, `~o"R3/2026-06-15T09:00/PT15M"`, come back as the one span `~o"2026-06-15T09:00:00Z/2026-06-15T09:45:00Z"`.

## What is lost

The following are **dropped on store**. They cannot be recovered on load.

### 1. The resolution a value was written to

This is the most important loss and has its own section below. `~o"2026"` is stored as the range `[2026-01-01 00:00:00Z, 2027-01-01 00:00:00Z)` and loads back as an interval between those two instants. That it was written as a year is not recoverable from the range, unless the column declares `:resolution`.

### 2. The zone

An expression in a named zone, or at a time shift, is stored as the UTC instants it is: PostgreSQL's `tstzrange` keeps every value at UTC, and the zone's name is not stored. On load the expression is at UTC (`Z`) — the *instants* are kept, the "it was in `America/New_York`" fact is not. An expression with no zone, floating, is stored as though it were at UTC, and loads back at UTC.

### 3. Metadata

The map `Tempo.put_metadata/2` sets, on an expression or on the members of a set, has no place in a range. It is dropped on store and loaded expressions come back with no metadata.

### 4. What the expression was

A value, an interval, a set and a recurrence are different expressions with spans. Postgres ranges hold only the spans. `~o"2026"`, `~o"2026/2026"` and `~o"2026-01-01T00:00/2027-01-01T00:00"` all store as the same range, and all load back as the last.

## What is rejected

The storage contract distinguishes between *dropped* (lost on store) and *rejected* (the `dump/1` callback returns `:error`, Ecto raises `Ecto.ChangeError` on insert). Rejection is the library's way of saying "this expression has no faithful representation in a `tstzrange` — the caller must make a decision". Each refusal is a `Tempo.SQL.UnsupportedValueError` from `Tempo.SQL.Conversion`, carrying its reason:

* **Several spans in one range** (`:multi_valued_slot`). `Tempo.Ecto.Interval` holds one span. A set, a recurrence, or a value that names several (`~o"2026Y{6,8}M"`, June and August) belongs in a `Tempo.Ecto.IntervalSet` column, one range a span.

* **A recurrence with no end.** `~o"R/2026-06-01/P1W"` has no last span, so no multirange holds it. Bound it with `Tempo.select/3` and a `:within` window, or store it in a composite column.

* **Qualifications** (`:qualification`). `~o"1984?/2004"` has no Postgres-range analogue — ranges are precise, uncertainty is not. Callers who need to persist uncertainty should store the expression in a composite column, or the qualification in a sibling column.

* **Calendars other than the Gregorian** (`:non_gregorian_calendar`). Values of the Hebrew, Persian or another calendar are rejected. The library does not convert for you; convert with `Tempo.to_calendar/2` before storing.

* **A value with no year** (`:partial_resolution`). `~o"T09/T17"` is the hours from nine to five of no day in particular, and names no instant. Place it in a day first.

* **Fully-unbounded intervals** (`:fully_unbounded`). `~o"../.."` would serialise to the Postgres range `(,)` — a range that contains every instant. This is almost always a caller error (unset fields), so we reject rather than store silently. Callers who genuinely want the universal range can store `NULL` in a nullable column.

* **An empty set.** An empty set serialises to `'{}'::tstzmultirange`, which is valid Postgres but usually indicates a caller error. Callers who want "no set" should use a `NULL` column.

What looks refusable but is not: an ordinal date (`~o"2026-181"`, the 30th of June), a week date (`~o"2026-W23-4"`), and a whole week (`~o"2026-W23"`, the seven days from Monday the 1st of June 2026) each name days, and store as the days they name.

## Resolution and round-trip

The resolution a value is written to is what it means:

```elixir
~o"2026"                        # the year
~o"2026-06"                     # the month
~o"2026-06-15"                  # the day
~o"2026-06-15T09"               # the hour
~o"2026-06-15T09:30:00"         # the second
```

Each of these is a valid Tempo value and each denotes a *different* span. `~o"2026"` is the whole of 2026; `~o"2026-06-15T09:30:00"` is one second.

**PostgreSQL ranges cannot express this distinction.** Every `tstzrange` is two timestamps — the resolution of the source value does not exist in the type system. `'[2026-01-01 00:00:00+00, 2027-01-01 00:00:00+00)'::tstzrange` is the storage representation of:

* `~o"2026"` — the year

* `~o"2026/2026"` — an interval from the year through the year

* `~o"2026-01-01T00:00/2027-01-01T00:00"` — a one-year booking written to the minute

All three store as the exact same range. On load we return the third form — an interval between two instants — because that is the only shape the loaded range guarantees.

**This means:** if the caller stores `~o"2026"` and loads it back, they do not get `~o"2026"`. They get `~o"2026-01-01T00:00:00Z/2027-01-01T00:00:00Z"`. It covers the same instants and gives the same answers to `Tempo.contains?/2`, `Tempo.overlaps?/2` and `Tempo.within?/2`. But the *expression* is different, and code that asks for its resolution gets the second.

### Preserving resolution — the options

**Option 1 — the `:resolution` field option.** Declare the resolution the column holds, and loaded values come back written to it:

```elixir
schema "reports" do
  field :reporting_year,    Tempo.Ecto.Interval, resolution: :year
  field :reporting_quarter, Tempo.Ecto.Interval, resolution: :month
  field :daily_window,      Tempo.Ecto.Interval, resolution: :day
  field :meeting_window,    Tempo.Ecto.Interval   # defaults to :second
end
```

The option takes a unit: `:year`, `:month`, `:day`, `:hour`, `:minute`, or `:second`. On load, both ends are written to that unit. An end at a calendar unit is read through it, so the range's upper bound becomes the last year, month or day it holds:

```elixir
# A column declared `resolution: :year`
~U[2026-01-01 00:00:00Z] .. ~U[2027-01-01 00:00:00Z]
#=> ~o"2026YZ/2026YZ"

# A column declared `resolution: :month`
~U[2026-04-01 00:00:00Z] .. ~U[2026-07-01 00:00:00Z]
#=> ~o"2026Y4MZ/2026Y6MZ"
```

> *"Load the range **as the years it holds** — 2026 through 2026." "Load the quarter as the months it holds — April through June."*

This is **an assertion by the caller about what the column holds**, not a heuristic. The loader writes the ends to the unit unconditionally — it does not peek at the bytes and guess. A column declared `resolution: :year` always loads as years, regardless of what was actually stored.

**Caveats:**

* **`:resolution` only affects `load/3`, not `dump/3`.** An expression is always stored as the instants it runs between.

* **A column with mixed-resolution data is a footgun.** If some rows were written as `~o"2026"` and others as `~o"2026-06-15T09:30:00Z/2026-06-15T10:00:00Z"`, declaring any single `:resolution` writes both to it — genuine instants come back as whole units. The option is for columns that hold data of one resolution, which is the common schema-level case but not universal.

* **`:resolution` does not change the stored bytes.** Switching the option later is a safe schema change — no data migration needed.

* **A range shorter than the unit is refused.** With `resolution: :day`, a stored range of `[2026-06-15 09:00:00Z, 2026-06-15 10:00:00Z)` begins on the 15th and ends through the 14th, which is no interval, so loading it is an error rather than a span that covers nothing. The option assumes your writers respect the declared resolution; it cannot undo bad data.

**Option 2 — a composite column.** For columns that hold data of mixed resolutions, or need the whole expression back, use `Tempo.Ecto.TempoRange` or `Tempo.Ecto.TempoMultirange`: the range column carries the queryable span and the `meta` column the expression's ISO 8601 text. See the composite section below.

## Bracket conventions

A Tempo span is half-open `[from, to)` underneath — inclusive first, exclusive last. PostgreSQL ranges support all four bracket shapes: `[]`, `[)`, `(]`, `()`. Unlike **discrete** range types (`int4range`, `daterange`) which Postgres canonicalises to `[)` on output, `tstzrange` and `tstzmultirange` **preserve the bracket shape** you wrote. A column populated by another writer can therefore hand you a `[a, b]` or `(a, b)` range.

`tempo_sql` normalises anything non-half-open to `[)` on load by shifting the offending endpoint one second:

| Stored shape | Normalised to                     | Equivalent instants |
|--------------|-----------------------------------|---------------------|
| `[a, b)`     | `[a, b)` (unchanged)              | same                |
| `[a, b]`     | `[a, b + 1s)`                     | same                |
| `(a, b)`     | `[a + 1s, b)`                     | same                |
| `(a, b]`     | `[a + 1s, b + 1s)`                | same                |

For a range of whole seconds, which is what `tempo_sql` writes for an expression of whole seconds, the one-second shift is exact — the loaded interval covers the same instants as the stored range. So `tempo_sql` columns are safe to share with writers that use any bracket convention at whole seconds.

On the dump side, `tempo_sql` always emits `[lower_inclusive: true, upper_inclusive: false]`, matching Tempo's convention.

## Composite mode — `tempo_range` and `tempo_multirange`

The composite types keep the whole expression. Use them when the plain-range mode's losses would hurt — recurrences, qualifications (`:uncertain`, `:approximate`), calendars other than the Gregorian, zones, the resolution a value was written to, metadata.

### Setup

One-time migration for the Postgres composite types:

```elixir
defmodule MyApp.Repo.Migrations.CreateTempoTypes do
  use Ecto.Migration
  import Tempo.SQL.Migration

  def up,   do: create_tempo_types()
  def down, do: drop_tempo_types()
end
```

This creates:

```sql
CREATE TYPE tempo_range AS (
  range      tstzrange,
  resolution text,
  meta       jsonb
);

CREATE TYPE tempo_multirange AS (
  ranges     tstzmultirange,
  resolution text,
  meta       jsonb
);
```

The three fields: `range`/`ranges` holds the queryable span; `resolution` records the column's declared resolution (for documentation); `meta` is a JSON document holding the expression's ISO 8601 text, its metadata, and each member's metadata for a set.

The application's Postgrex needs to know how to encode the `jsonb` column. `tempo_sql` ships a `Tempo.SQL.PostgresTypes` module that configures `:json` (OTP 27+):

```elixir
config :my_app, MyApp.Repo, types: Tempo.SQL.PostgresTypes
```

Alternatively, define your own types module via `Postgrex.Types.define(MyApp.PostgresTypes, [], json: Tempo.SQL.JSON)`.

### Schema

```elixir
schema "meetings" do
  field :window, Tempo.Ecto.TempoRange
end

schema "calendars" do
  field :busy_times, Tempo.Ecto.TempoMultirange
end
```

The Ecto API is the same as the plain-range types': cast, dump and load take and return `t:Tempo.t/0` expressions. A composite takes any expression that has ISO 8601 text and a place on the time line, and keeps it as it was given.

### What round-trips

A composite column keeps the expression's ISO 8601 text, which Tempo reads back as it was written:

* **Resolution.** A stored `~o"2026"` loads as `~o"2026"`, not as an interval between two instants. This is the headline difference from the plain-range mode.

* **Qualifications.** `~o"1984?/2004~"` loads as it was stored.

* **Recurrences.** `~o"R5/2022-01-01/P1M"` loads back as the same recurrence, and `~o"R/2022-01-01/P1M"`, which has no end, is stored with a range from its first occurrence on, unbounded above.

* **Calendars.** `~o"5786-01-01/5786-01-10[u-ca=hebrew]"` loads back in the Hebrew calendar; its range is the Gregorian instants it covers.

* **Zones.** IANA names (`[America/New_York]`) survive, not just UTC offsets.

* **Sets.** A set loads back with its members as they were, each with its own metadata.

* **Metadata**, on the expression and on each member of a set, provided the map is JSON-serialisable (strings, numbers, booleans, nested maps/lists). It comes back with string keys.

The range a composite stores is the stretch the expression covers: from the start of its first span to the end of its last, so a set's range includes the gaps between its members, and range queries find the expression wherever any of it lies.

### Queries

The standard Postgres range operators (`@>`, `&&`, `-|-`) don't apply directly to composite columns — they must reach into the `range` field. Use the parallel query API:

```elixir
import Tempo.Ecto.QueryAPI.Composite

from m in FidelityMeeting,
  where: overlaps(m.window, ^search_range)
```

The macros expand to `fragment("(?).range && ?", m.window, search_range)` — same operator names and Allen-algebra semantics as `Tempo.Ecto.QueryAPI`, just auto-unwrapping.

Mixing `Tempo.Ecto.QueryAPI` (plain-range macros) with a composite column produces a SQL error. Mixing `Tempo.Ecto.QueryAPI.Composite` with a plain `tstzrange` column also fails. Choose one import per query module; a query module that mixes columns should qualify both imports.

### What the composite still cannot do

* **Fully-unbounded intervals** (`~o"../.."`) are still rejected. The range field needs a bound on at least one side for any Postgres range-operator query to be meaningful. Use a NULL column if you need "no interval".

* **Expressions with no place on the time line**: a value with no year (`~o"T09/T17"`), a duration on its own, and a recurrence counted back with no start (`~o"R/P1W/2026-06-01"`).

* **An empty set** is still rejected. Use NULL.

* **Metadata that contains non-JSON-serialisable terms** (tuples, pids, structs) will raise on dump. Convert them at the application layer before storing.

### Version 1 and 2 rows

`tempo_sql` 0.2.0 and earlier, on Tempo 1.x, wrote the `meta` column as version 1 or 2: each end of an interval on its own. Tempo 1.x read an interval's end as the instant it stops before, where Tempo 2.0 reads an end written to a date through it, so those rows are read as they were written to mean: `{"from": "2022Y1M1D", "to": "2022Y1M5D"}` is `~o"2022-01-01/2022-01-04"`, the same four days. A recurrence is rebuilt from its start, its cadence and its count. No migration is needed; a row is written as version 3 when it is next stored.

### Trade-offs

Composite types are not a free upgrade:

* **Storage.** Every row carries a `jsonb` blob in addition to the range column. For homogeneous-shape data where you don't need fidelity, the plain-range mode is cheaper.

* **Indexes.** GiST indexes apply to the range field, not the whole composite. Index the sub-field explicitly: `CREATE INDEX ON meetings USING gist (((window).range))`. The test suite skips this for simplicity; production workloads should add it.

* **Third-party tooling.** A plain `tstzrange` column is understood by every Postgres client, ORM, and BI tool. A `tempo_range` composite is not — downstream systems need to either know about the type or unwrap it via `(column).range` in a view.

The guidance is: plain-range for the common case, composite when the schema has load-bearing Tempo shape that matters.

## Summary

| Fact about a Tempo expression    | Plain range            | Composite |
|----------------------------------|------------------------|-----------|
| Start and end instants           | Yes, at UTC on load    | Yes       |
| Open ends                        | Yes                    | Yes       |
| The order of a set's spans       | Yes, touching spans joined | Yes   |
| Zone                             | No, UTC on load        | Yes       |
| Metadata                         | No                     | Yes       |
| The resolution written to        | With `:resolution`     | Yes       |
| Recurrence                       | Its occurrences, if it ends | Yes  |
| Qualification                    | No (rejected)          | Yes       |
| Calendar other than the Gregorian | No (rejected)         | Yes       |
| A value with no year             | No (rejected)          | No (rejected) |
| Unbounded at both ends           | No (rejected)          | No (rejected) |

If all the caller cares about is the span — its start, end, and overlap relationships — the plain range round-trips faithfully. If the column holds data of one resolution, declare `:resolution` on the field. If the column holds mixed resolutions, or the expression matters, use a composite column.
