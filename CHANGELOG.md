# Changelog

All notable changes to `ex_tempo_sql` are documented here, following [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.2.0] — 2026-08-03

### Added

* Every public function now carries an `### Examples` section, and every example that can run without a database runs as a doctest on each test build. The library previously had none, so its documentation was never checked against its code.

### Fixed

* Recurring intervals stored in a `tempo_range` or `tempo_multirange` column now load back intact. The meta format could not tell an open-ended endpoint from an absent one, so a value like `R5/2022-01-01/P1M` returned with `to: :undefined` and could no longer be rendered at all.

* Documented the storage contract accurately for week and day-of-year endpoints. Ordinal dates and full week dates are resolved to calendar dates while parsing and store normally; only a value still carrying those tokens — such as a bare `~o"2026-W10"` — is refused.

### Changed

* The composite `meta` format is now version 2, which writes `".."` for an explicitly open-ended endpoint. Version 1 rows keep decoding exactly as before, so no migration is required, but a recurring interval written by 0.1.0 should be rewritten to regain its endpoint.

* Requires `ex_tempo ~> 1.1 and >= 1.1.1`. The previous `~> 0.16` constraint could not resolve alongside Tempo 1.x, so the two libraries could not be used together. The 1.1.1 floor matters on its own: before it, casting a list whose members are not intervals raised rather than returning `:error`, so bad changeset input crashed instead of failing validation.

* Repository links point at the `elixir-tempo` organisation, and the README links the storage-contract guide on HexDocs rather than a GitHub blob.

* **Requires Erlang/OTP 27 or later**, inherited from `ex_tempo` — OTP 26 is no longer supported and has been dropped from CI.

## [0.1.0] — 2026-07-05

### Highlights

* Tempo SQL persists Tempo intervals and interval sets as PostgreSQL range types, wiring the half-open `[from, to)` convention through to `tstzrange` / `tstzmultirange` natively.

* **Ecto types.** `Tempo.Ecto.Interval` stores a `%Tempo.Interval{}` as `tstzrange`; `Tempo.Ecto.IntervalSet` stores a `%Tempo.IntervalSet{}` as `tstzmultirange` (PG 14+); `Tempo.Ecto.Tempo` materialises a bare `%Tempo{}` implicit span before delegating to the interval type.

* **Storage contract.** Each type is explicit about what it refuses to store: recurrence rules, qualifications, non-Gregorian calendars, multi-valued token slots, and ordinal/week-date endpoints all return `:error` from `dump/1` rather than silently losing information. See the "Storage contract" section of the README.

* **Migration helpers.** `Tempo.SQL.Migration` exposes `add_interval/2`, `add_interval_set/2`, and `create_interval_index/3`. Range queries require GiST indexes for speed; the helper handles that.

* **Query API.** `Tempo.Ecto.QueryAPI` wraps Postgres range operators (`@>`, `&&`, `-|-`, `<<`, `>>`) under Allen's interval-algebra names — `contains`, `overlaps`, `meets`, `strictly_before`, `strictly_after`.

* **Round-trip note.** The plain-range types (`Tempo.Ecto.Interval`, `.IntervalSet`, `.Tempo`) are lossy on metadata — qualifications, recurrence rules, calendars, zone identifiers, and the implicit-vs-explicit-span distinction are dropped on store. Partial resolution is recoverable via the `:resolution` field option. For full round-trip fidelity, use the composite types below.

* **Composite `tempo_range` / `tempo_multirange` types.** `Tempo.Ecto.TempoRange` and `Tempo.Ecto.TempoMultirange` persist the full Tempo shape byte-for-byte via a PostgreSQL composite type pairing a `tstzrange` / `tstzmultirange` with a `jsonb` meta column. One-time migration creates the types (`Tempo.SQL.Migration.create_tempo_types/0`); field helpers (`add_tempo_range/2`, `add_tempo_multirange/2`) declare the columns; `Tempo.Ecto.QueryAPI.Composite` provides auto-unwrapping query macros. Uses Erlang's built-in `:json` (OTP 27+) via the `Tempo.SQL.PostgresTypes` module — no Jason dependency.
