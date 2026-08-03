# Storage contract

How Tempo types map to PostgreSQL range types, what survives a store-and-load cycle, and — importantly — what does not.

This is a reference document. Every claim here is enforced by [`Tempo.SQL.Conversion`](https://github.com/elixir-tempo/tempo_sql/blob/main/lib/tempo/sql/conversion.ex) / [`Tempo.SQL.Meta`](https://github.com/elixir-tempo/tempo_sql/blob/main/lib/tempo/sql/meta.ex) and covered by the test suite.

## Two storage modes

`tempo_sql` offers two parallel storage strategies. Pick one per column:

| Strategy             | Ecto types                                  | PG types                          | Round-trip fidelity |
|----------------------|---------------------------------------------|-----------------------------------|---------------------|
| **Plain range**      | `Tempo.Ecto.Interval` / `.IntervalSet` / `.Tempo` | `tstzrange` / `tstzmultirange`    | Lossy (span only)   |
| **Composite**        | `Tempo.Ecto.TempoRange` / `.TempoMultirange`      | `tempo_range` / `tempo_multirange` | Full (byte-exact)   |

**Pick plain range when** the downstream workflow only cares about the span — start, end, overlap relationships. Queries are native Postgres operators. Minimal schema overhead.

**Pick composite when** you need round-trip fidelity — qualifications, non-Gregorian calendars, recurrence rules, zone identifiers, or the implicit-vs-explicit-span distinction. The composite stores a queryable `tstzrange` *and* a `jsonb` meta column that captures everything else the Tempo struct knows. Costs: a `CREATE TYPE` migration, a different column type, composite-aware query macros, and one extra column's worth of storage per row.

Most of the rest of this guide is about the plain-range mode, because the composite mode is lossless by design — the one-paragraph summary is "whatever you put in comes back exactly, and range queries still work via `(column).range`". Composites have their own section at the end.

## The plain-range mapping

| Tempo type              | Ecto type                     | PostgreSQL column   |
|-------------------------|-------------------------------|---------------------|
| `%Tempo.Interval{}`     | `Tempo.Ecto.Interval`         | `tstzrange`         |
| `%Tempo.IntervalSet{}`  | `Tempo.Ecto.IntervalSet`      | `tstzmultirange`    |
| bare `%Tempo{}`         | `Tempo.Ecto.Tempo`            | `tstzrange`         |

`tstzrange` is a timezone-aware range of two `timestamptz` values. `tstzmultirange` (PostgreSQL 14+) is an ordered, disjoint set of `tstzrange` values. Both follow the half-open `[lower, upper)` convention, which is the same convention Tempo uses for `%Tempo.Interval{}` — so adjacency, ordering, and emptiness all compose cleanly across the boundary.

## What a round-trip looks like

A minimal setup, three Tempo values, pipeline through the type module:

```elixir
original_year     = ~o"2026Y"
original_meeting  = Tempo.Interval.new!(
  from: Tempo.from_iso8601!("2026-06-15T09:00:00"),
  to:   Tempo.from_iso8601!("2026-06-15T10:00:00")
)
original_zoned    = %Tempo.Interval{
  from: Tempo.from_date_time(~U[2026-06-15 09:00:00Z]),
  to:   Tempo.from_date_time(~U[2026-06-15 10:00:00Z])
}

{:ok, year_range}    = Tempo.Ecto.Tempo.dump(original_year)
{:ok, meeting_range} = Tempo.Ecto.Interval.dump(original_meeting)
{:ok, zoned_range}   = Tempo.Ecto.Interval.dump(original_zoned)

{:ok, loaded_year}     = Tempo.Ecto.Interval.load(year_range)
{:ok, loaded_meeting}  = Tempo.Ecto.Interval.load(meeting_range)
{:ok, loaded_zoned}    = Tempo.Ecto.Interval.load(zoned_range)
```

*In prose: the year `2026Y` **materialises** to its full span, stores as a range, and loads back as a **fully-anchored interval** — the "it was just a year" fact is gone. The meeting round-trips cleanly on its endpoints. The zoned value round-trips as UTC — the `"Etc/UTC"` fact survives, any other zone identifier does not.*

That last sentence is the whole guide in one line. The rest of this document makes each claim precise.

## What is retained

**For every storable value,** the following survive a round-trip exactly:

* Both endpoints as `NaiveDateTime` moments, to second precision. Tempo values are second-resolution by design — there is no precision loss on either direction.

* The half-open `[from, to)` convention. PostgreSQL canonicalises all range outputs to `[lower, upper)` on read regardless of how they were written, which happens to match Tempo's convention exactly. Adjacent spans remain adjacent, touching spans still touch.

* Unbounded endpoints. `from: :undefined` becomes a range with `lower: :unbound` (SQL `(, upper)`), and the reverse on load. This means an open-ended booking like "everything after 2026-06-15T09:00:00" round-trips cleanly as a half-open interval.

* For `tstzmultirange`, the ordering and disjoint-ness of member intervals. A stored `Tempo.IntervalSet` loads back with its members in the same canonical order.

**For zoned values specifically,** the underlying instant survives — but see the next section for the part that does not.

## What is lost

The following are **dropped silently on store**. They cannot be recovered on load; the library makes no attempt to preserve them in this release.

### 1. Tempo resolution (the "year token" fact)

This is the most important loss and deserves its own section below. A bare `%Tempo{time: [year: 2026]}` is stored as the two-instant range `[2026-01-01T00:00:00Z, 2027-01-01T00:00:00Z)` and loads back as a `%Tempo.Interval{}` whose endpoints are second-resolution Tempo values. The original "year-only" token list is not recoverable from the range.

### 2. Time-zone identifier and wall-clock offset

A Tempo value built from a zoned `DateTime` carries both an offset (`:shift`) and an IANA zone identifier (`extended.zone_id`). PostgreSQL's `tstzrange` stores every value as UTC regardless of how it was written, and the zone name is discarded at the database level. On load we return UTC (`shift: [hour: 0]`, `zone_id: "Etc/UTC"`) — the *instant* is preserved but the "it was originally `America/New_York`" fact is not.

### 3. Qualifications and extended metadata

`Tempo.qualification` (`:uncertain`, `:approximate`), `Tempo.qualifications`, and the entire `Tempo.extended` map (IXDTF `u-ca`, `u-rg`, custom tags) have no Postgres representation. Values carrying any of these are **rejected on store** — see the next section. A value that happens to have `qualification: nil` and an empty `extended` map dumps cleanly; anything non-empty does not.

### 4. Interval metadata

`Tempo.Interval.metadata` and `Tempo.IntervalSet.metadata` are user-controlled maps that ride along with set-algebra operations. They are dropped on store and loaded values come back with `metadata: %{}`.

### 5. Implicit-vs-explicit span distinction

Tempo draws a line between *implicit* spans (a bare `%Tempo{}` that represents its own span, like `~o"2026Y"`) and *explicit* spans (`%Tempo.Interval{}` with materialised endpoints). Postgres ranges are always explicit. Storing through `Tempo.Ecto.Tempo` silently materialises the implicit side before writing, and the loaded value is always an explicit `%Tempo.Interval{}`. See the resolution section for what this means in practice.

## What is rejected

The storage contract distinguishes between *dropped* (silently lost on store) and *rejected* (the `dump/1` callback returns `:error`, Ecto raises `Ecto.ChangeError` on insert). Rejection is the library's way of saying "this value has no faithful representation in a `tstzrange` — the caller must make a decision".

The rejected cases, from [`Tempo.SQL.Conversion`](https://github.com/elixir-tempo/tempo_sql/blob/main/lib/tempo/sql/conversion.ex):

* **Recurrence rules.** A `Tempo.Interval` with `recurrence != 1` or a `repeat_rule` is a specification for an infinite (or N-bounded) set of occurrences, not a single range. Callers should materialise via `Tempo.to_interval/1`, which returns a `Tempo.IntervalSet`, then store that under `Tempo.Ecto.IntervalSet`.

* **Qualifications.** `%Tempo{qualification: :uncertain}` has no Postgres-range analogue — ranges are precise, uncertainty is not. Callers who need to persist uncertainty should strip the qualification first and store it in a sibling column if the semantic is load-bearing.

* **Non-Gregorian calendars.** Tempo values on `Calendrical.Hebrew`, `Calendrical.Persian`, etc. are rejected. The library does not guess at calendar conversion; callers should convert to the Gregorian calendar — materialise the date via `Tempo.to_date/1`, `Date.convert/2` it to `Calendar.ISO`, and rebuild the Tempo — before storing.

* **Multi-valued token slots.** A `%Tempo{time: [day_of_week: [1, 3, 5]]}` specifies Monday, Wednesday, or Friday — it is a *set of instants*, not an interval. Materialise via `Tempo.to_interval/1` into an `IntervalSet` and store that.

* **Ordinal-date and week-date endpoints.** A `%Tempo{time: [year: 2026, day: 75]}` (day-of-year) or `%Tempo{time: [year: 2026, week: 10, day_of_week: 3]}` (ISO week date) requires calendar conversion to become a `NaiveDateTime`. The library rejects rather than silently converts. Callers should materialise via `Tempo.to_date/1` and rebuild the Tempo from the resulting `Date`.

* **Fully-unbounded intervals.** A `%Tempo.Interval{from: :undefined, to: :undefined}` would serialise to the Postgres range `(,)` — a range that contains every instant. This is almost always a caller error (unset fields), so we reject rather than store silently. Callers who genuinely want the universal range can store `NULL` in a nullable column.

* **Empty `Tempo.IntervalSet`.** An empty set serialises to `'{}'::tstzmultirange`, which is valid Postgres but usually indicates a caller error. Callers who want "no set" should use a `NULL` column.

## Resolution and round-trip

Tempo's core design decision is that the **absence** of a time field establishes the resolution of a value:

```elixir
~o"2026Y"                       # year resolution
~o"2026-06"                     # month resolution
~o"2026-06-15"                  # day resolution
~o"2026-06-15T09"               # hour resolution
~o"2026-06-15T09:30:00"         # second resolution
```

Each of these is a valid Tempo value and each has a *different* semantics under `to_interval/1`, set algebra, and comparison. `~o"2026Y"` represents the whole of 2026; `~o"2026-06-15T09:30:00"` represents a one-second span.

**PostgreSQL ranges cannot express this distinction.** Every `tstzrange` is two timestamps — the "resolution" of the source value simply does not exist in the type system. `'[2026-01-01 00:00:00+00, 2027-01-01 00:00:00+00)'::tstzrange` is the storage representation of:

* `~o"2026Y"` — a year-resolution Tempo

* `%Tempo.Interval{from: ~o"2026Y", to: ~o"2027Y"}` — an explicit interval with year-resolution endpoints

* A one-year booking explicitly written with second-resolution endpoints

All three store as the exact same sixteen-byte range. On load we return the third form — a `%Tempo.Interval{}` with second-resolution endpoints — because that is the only shape the loaded range actually guarantees.

**This means:** if the caller stores `~o"2026Y"` and loads it back, they do not get `~o"2026Y"`. They get `%Tempo.Interval{from: ~o"2026-01-01T00:00:00Z", to: ~o"2027-01-01T00:00:00Z"}`. Semantically the interval is identical — it covers the same instants, produces the same answers to `contains?/2`, `overlaps?/2`, `within?/2`. But the *shape* is different and code that pattern-matches on the Tempo's token list will not match.

### Preserving resolution — the options

**Option 1 — the `:resolution` field option.** Declare the resolution the column holds, and loaded values come back at that resolution:

```elixir
schema "reports" do
  field :reporting_year,    Tempo.Ecto.Interval, resolution: :year
  field :reporting_quarter, Tempo.Ecto.Interval, resolution: :month
  field :daily_window,      Tempo.Ecto.Interval, resolution: :day
  field :meeting_window,    Tempo.Ecto.Interval   # defaults to :second
end
```

The option takes a Tempo time component: `:year`, `:month`, `:day`, `:hour`, `:minute`, or `:second`. On load, both endpoints are truncated to the named resolution and all sub-components are dropped from the token list:

```elixir
# Stored via a column declared `resolution: :year`
~U[2026-01-01 00:00:00Z] .. ~U[2027-01-01 00:00:00Z]
#=> %Tempo.Interval{
#     from: %Tempo{time: [year: 2026]},
#     to:   %Tempo{time: [year: 2027]}
#   }
```

*"Load the range **as a year-resolution interval** — year 2026 through year 2027."*

This is **an assertion by the caller about what the column holds**, not a heuristic. The loader truncates unconditionally — it does not peek at the bytes and guess. A column declared `resolution: :year` always loads as year-resolution Tempos, regardless of what was actually stored.

**Caveats:**

* **`:resolution` only affects `load/3`, not `dump/3`.** A stored value always serialises at full precision (whatever the Tempo endpoints happen to contain after any materialisation). The option is purely a load-time *widening* of the output shape.

* **A column with mixed-resolution data is a footgun.** If some rows were written as `~o"2026Y"` and others as `~o"2026-06-15T09:30:00Z"`, declaring any single `:resolution` will flatten both sides — genuine second-precision instants come back as truncated Tempos. The option is for columns that hold *homogeneous-resolution* data, which is the common schema-level case but not universal.

* **`:resolution` does not change the stored bytes.** A `tstzrange` always occupies the same storage regardless of `:resolution`. Switching the option later is a safe schema change — no data migration needed.

* **Sub-resolution boundaries.** With `resolution: :day`, a stored range of `[2026-06-15T09:00:00Z, 2026-06-15T10:00:00Z)` loads as `[~o"2026-06-15", ~o"2026-06-15")` — a zero-width interval at day resolution. The option assumes your writers respect the declared resolution; it cannot undo bad data.

**Option 2 — sibling text column.** For columns that hold mixed-resolution data or need full metadata, carry the original ISO 8601 string alongside the range:

```elixir
schema "reports" do
  field :period,            Tempo.Ecto.Interval
  field :period_iso8601,    :string    # "2026Y" vs "2026-01-01T00:00:00Z/2027-01-01T00:00:00Z"
end
```

The `text` column carries the original shape; the range column carries the queryable span. A future release will bundle this into a single Ecto type — see the [`ideas_for_the_future.md`](https://github.com/elixir-tempo/tempo/blob/main/plans/ideas_for_the_future.md) entry on a `:text` variant.

**Option 3 — wait for the metadata-preserving variant.** The v0.1.0 release is deliberately lossy on round-trip. The [TODO entry in the parent library](https://github.com/elixir-tempo/tempo/blob/main/TODO.md) flags a round-2 milestone that will add a composite-type variant carrying both the range and the original ISO 8601 string. When it lands, callers who need perfect round-trip can opt in with no schema changes beyond a column swap.

## Bracket conventions

Tempo intervals are half-open `[from, to)` — inclusive first, exclusive last. PostgreSQL ranges support all four bracket shapes: `[]`, `[)`, `(]`, `()`. Unlike **discrete** range types (`int4range`, `daterange`) which Postgres canonicalises to `[)` on output, `tstzrange` and `tstzmultirange` **preserve the bracket shape** you wrote. A column populated by another writer can therefore hand you a `[a, b]` or `(a, b)` range.

`tempo_sql` normalises anything non-half-open to `[)` on load by shifting the offending endpoint one second:

| Stored shape | Normalised to                     | Equivalent instants |
|--------------|-----------------------------------|---------------------|
| `[a, b)`     | `[a, b)` (unchanged)              | same                |
| `[a, b]`     | `[a, b + 1s)`                     | same                |
| `(a, b)`     | `[a + 1s, b)`                     | same                |
| `(a, b]`     | `[a + 1s, b + 1s)`                | same                |

Tempo is second-resolution, so the one-second shift is exact — the loaded interval covers the same instants as the stored range. This means `tempo_sql` columns are safe to share with writers that use any bracket convention.

On the dump side, `tempo_sql` always emits `[lower_inclusive: true, upper_inclusive: false]`, matching Tempo's convention.

## Composite mode — `tempo_range` and `tempo_multirange`

The composite types preserve the full Tempo shape. Use them when the plain-range mode's losses would hurt — recurrence rules, qualifications (`:uncertain`, `:approximate`), non-Gregorian calendars, implicit-span shape, per-interval metadata.

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

The three fields: `range`/`ranges` holds the queryable span; `resolution` records the declared truncation (for documentation); `meta` is a JSON document with every Tempo-shape fact the range column cannot express.

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

The Ecto API is identical — cast/dump/load take and return `%Tempo.Interval{}` / `%Tempo.IntervalSet{}` values, just like the plain-range types.

### What round-trips

A composite column preserves:

* **Token-list resolution.** A stored `~o"2026Y"` loads as `~o"2026Y"`, not a materialised second-resolution interval. This is the headline difference from the plain-range mode.

* **Qualifications.** `:uncertain`, `:approximate`, and IXDTF qualification strings survive.

* **Recurrence rules.** `Interval.recurrence`, `direction`, `duration`, and `repeat_rule` all round-trip via their ISO 8601 representations in the meta column. A stored `R5/2022-01-01/P1M` loads back as the same recurring interval.

* **Non-Gregorian calendars.** Whatever calendar the stored Tempo uses round-trips through the ISO 8601 / IXDTF encoding in `meta`.

* **Zone identifiers.** IANA names (`"America/New_York"`) survive, not just UTC offsets.

* **`Interval.metadata`** and **`IntervalSet.metadata`**, provided the user map is JSON-serialisable (strings, numbers, booleans, nested maps/lists).

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

* **Fully-unbounded intervals** (`from: :undefined, to: :undefined`) are still rejected. The range field needs a bound on at least one side for any Postgres range-operator query to be meaningful. Use a NULL column if you need "no interval".

* **Empty `IntervalSet`** is still rejected. Use NULL.

* **User `metadata` that contains non-JSON-serialisable terms** (atoms other than `nil`, structs, tuples, pids) will raise on dump. If the map contains atoms you care about, convert them to strings at the application layer before storing.

### Trade-offs

Composite types are not a free upgrade:

* **Storage.** Every row carries a `jsonb` blob in addition to the range column. For homogeneous-shape data where you don't need fidelity, the plain-range mode is cheaper.

* **Indexes.** GiST indexes apply to the range field, not the whole composite. Index the sub-field explicitly: `CREATE INDEX ON meetings USING gist (((window).range))`. The test suite skips this for simplicity; production workloads should add it.

* **Third-party tooling.** A plain `tstzrange` column is understood by every Postgres client, ORM, and BI tool. A `tempo_range` composite is not — downstream systems need to either know about the type or unwrap it via `(column).range` in a view.

The guidance is: plain-range for the common case, composite when the schema has load-bearing Tempo shape that matters.

## Summary

| Fact about a Tempo value        | Retained on round-trip | Note                                               |
|----------------------------------|------------------------|----------------------------------------------------|
| Start and end instants           | Yes                    | Second precision, UTC on load                      |
| Half-open `[from, to)` convention | Yes                    | Canonical on both sides                            |
| Unbounded endpoints              | Yes                    | `:undefined` ↔ `:unbound`                           |
| IntervalSet member ordering      | Yes                    | Canonical on both sides                            |
| Time-zone identifier             | No                     | Becomes `"Etc/UTC"` on load; instant preserved     |
| `:qualification`                 | No (rejected)          | Store separately if load-bearing                   |
| `:extended` metadata             | No                     | `extended: %{}` on load                            |
| `Interval.metadata`              | No                     | `metadata: %{}` on load                            |
| Implicit-span shape (`~o"2026Y"`)| No                     | Becomes fully-anchored `%Tempo.Interval{}` on load |
| Token-list resolution            | Partial                | Opt in with `:resolution` field option              |
| Calendar (non-Gregorian)         | No (rejected)          | Convert to `Calendar.ISO` first                    |
| Multi-valued token slots         | No (rejected)          | Materialise via `Tempo.to_interval/1` first        |

If all the caller cares about is the span — its start, end, and overlap relationships — `tempo_sql` round-trips faithfully. If the caller cares about the *shape* of the Tempo value and the column holds homogeneous-resolution data, declare `:resolution` on the field. If the column holds mixed-resolution data or needs full Tempo metadata, use a sibling text column or wait for the metadata-preserving variant.
