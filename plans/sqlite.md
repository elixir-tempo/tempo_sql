# SQLite storage

**Status:** implemented (v0.4.0), 2026-11-01

SQLite has four storage classes (INTEGER, REAL, TEXT, BLOB) and no range type, so a Tempo expression cannot be stored as PostgreSQL stores it. This plan stores an expression whole in one JSON column, beside the integer bounds of the time it covers, and queries those bounds with plain comparisons.

## The options

* **A JSON column with integer bounds** — one column per field, holding the expression's ISO 8601 text and the bounds of its stretch and of each of its spans as integers, indexed by expression indexes on the bounds. Works on any SQLite from 3.38, needs nothing loaded, and every Allen relation is a comparison of integers.

* **An R\*Tree index beside it** — a 1-D `rtree_i32` virtual table kept in step by triggers. Its coordinates are 32-bit, so a bound would be rounded outward to the minute and every match rechecked against the column. Worth adding only for large tables of mixed span lengths.

* **A loadable extension** — an interval type and Allen-named functions in C or Rust. An opaque function cannot use an index, so it buys no speed, and it costs a build for every platform and a `load_extensions` step for every user.

* **SQL functions defined in Elixir** — exqlite has no `sqlite3_create_function` binding (its issue 206 was closed with "write an extension"), and a callback into the BEAM from inside `sqlite3_step` would block a scheduler per row.

## Decisions

* 2026-11-01 (the user) — a JSON column with integer bounds; no extension.

* 2026-11-01 (the user) — bounds are stored to the second, as the PostgreSQL ranges are.

* 2026-11-01 (the user) — the column keeps the whole expression, as the PostgreSQL composite types do: what is written comes back as it was written.

* 2026-11-01 (the user) — separate types, under `Tempo.Ecto.SQLite`, rather than one type that switches on the repo's adapter.

* 2026-11-01 — a bound with a fraction of a second is rounded outward, so the bounds always cover the expression.

* 2026-11-01 — the SQLite test database keeps the rollback journal: switching a just-created file to WAL as the repo connects raced the connection that created it.

* 2026-11-01 — a column is on one frame, as on PostgreSQL: `frame: :utc` (the default) holds values in a zone or at a time shift, as seconds since the Unix epoch at UTC; `frame: :floating` holds values with neither, as seconds since 1970-01-01T00:00 on the wall clock. A value of the other frame is refused with `UnsupportedValueError` reason `:frame`.

## The shape

The column is `TEXT` holding a JSON object:

```json
{"v": 1, "frame": "utc", "lo": 1781514000, "hi": 1781517600, "spans": [[1781514000, 1781517600]], "meta": {"expression": "2026Y6M15DT9H0MZ/T10H0MZ", "members": null, "metadata": {}, "v": 3}}
```

* `lo` and `hi` are the half-open bounds of the stretch the expression covers, from the start of its first span to the end of its last. An open end is stored as the least or greatest 64-bit integer, so a comparison needs no `NULL` case.

* `spans` are the bounds of each span, in order, for the exact test of a set or a recurrence. A recurrence with no end keeps the spans up to its first and an open `hi`, as the composite range does.

* `meta` is the document `Tempo.SQL.Meta` writes for the PostgreSQL composite types, so an expression is read back by the same code on either database.

## The modules

* `Tempo.Ecto.SQLite.TempoRange` — an `Ecto.ParameterizedType` storing any expression with ISO 8601 text and a place on the time line, with the `:frame` option of the PostgreSQL types. It takes no `:resolution`: the expression is read back as it was written.

* `Tempo.Ecto.SQLite.QueryAPI` — `contains/2`, `overlaps/2`, `meets/2`, `strictly_before/2` and `strictly_after/2`, as fragments on `json_extract(column, '$.lo')` and `'$.hi'`, the probe a pinned value `Tempo.Ecto.SQLite.QueryAPI.probe/2` makes from an expression.

* `Tempo.SQL.SQLite.Migration` — `add_tempo_range/2` (a `:text` column) and `create_tempo_range_index/3`, the expression indexes on the bounds.

* `ecto_sqlite3` is an optional dependency, and every module is compiled only when it is present.

## Tasks

* [x] **Bounds** — the JSON document from an expression and a frame, and the expression back from it, with refusals as `UnsupportedValueError`.

* [x] **The Ecto type** — `Tempo.Ecto.SQLite.TempoRange`, tested by round trips through a SQLite repository in the test suite.

* [x] **Queries** — the five macros and `probe/2`, tested against the PostgreSQL operators' answers on the same values.

* [x] **Migrations** — the column and index helpers, and an index used by an overlap query (`EXPLAIN QUERY PLAN`).

* [x] **Documentation** — a SQLite guide, the README and the CHANGELOG.
