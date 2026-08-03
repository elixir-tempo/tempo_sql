# Changelog

All notable changes to `ex_tempo_sql` are documented here, following [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

* Requires `ex_tempo ~> 1.1`. The previous `~> 0.16` constraint could not resolve alongside Tempo 1.x, so the two libraries could not be used together. Verified against Tempo 1.1.0 with the full suite passing; no API changes were needed.

* Repository links point at the `elixir-tempo` organisation, and the README links the storage-contract guide on HexDocs rather than a GitHub blob.

## [0.1.0] — 2026-07-05

### Highlights

* Tempo SQL persists Tempo intervals and interval sets as PostgreSQL range types, wiring the half-open `[from, to)` convention through to `tstzrange` / `tstzmultirange` natively.

* **Ecto types.** `Tempo.Ecto.Interval` stores a `%Tempo.Interval{}` as `tstzrange`; `Tempo.Ecto.IntervalSet` stores a `%Tempo.IntervalSet{}` as `tstzmultirange` (PG 14+); `Tempo.Ecto.Tempo` materialises a bare `%Tempo{}` implicit span before delegating to the interval type.

* **Storage contract.** Each type is explicit about what it refuses to store: recurrence rules, qualifications, non-Gregorian calendars, multi-valued token slots, and ordinal/week-date endpoints all return `:error` from `dump/1` rather than silently losing information. See the "Storage contract" section of the README.

* **Migration helpers.** `Tempo.SQL.Migration` exposes `add_interval/2`, `add_interval_set/2`, and `create_interval_index/3`. Range queries require GiST indexes for speed; the helper handles that.

* **Query API.** `Tempo.Ecto.QueryAPI` wraps Postgres range operators (`@>`, `&&`, `-|-`, `<<`, `>>`) under Allen's interval-algebra names — `contains`, `overlaps`, `meets`, `strictly_before`, `strictly_after`.

* **Round-trip note.** The plain-range types (`Tempo.Ecto.Interval`, `.IntervalSet`, `.Tempo`) are lossy on metadata — qualifications, recurrence rules, calendars, zone identifiers, and the implicit-vs-explicit-span distinction are dropped on store. Partial resolution is recoverable via the `:resolution` field option. For full round-trip fidelity, use the composite types below.

* **Composite `tempo_range` / `tempo_multirange` types.** `Tempo.Ecto.TempoRange` and `Tempo.Ecto.TempoMultirange` persist the full Tempo shape byte-for-byte via a PostgreSQL composite type pairing a `tstzrange` / `tstzmultirange` with a `jsonb` meta column. One-time migration creates the types (`Tempo.SQL.Migration.create_tempo_types/0`); field helpers (`add_tempo_range/2`, `add_tempo_multirange/2`) declare the columns; `Tempo.Ecto.QueryAPI.Composite` provides auto-unwrapping query macros. Uses Erlang's built-in `:json` (OTP 27+) via the `Tempo.SQL.PostgresTypes` module — no Jason dependency.
