# TODO

The work planned for `ex_tempo_sql`. Designs are in [plans/](plans/).

## In progress

* [ ] **Release 0.4.0** — the floating frame, SQLite storage and the fixes since 0.3.0. Reviewed 2026-11-01, every gate green; it waits on its commit, tag and publish.

## Done

* [x] **SQLite storage** — `Tempo.Ecto.SQLite.TempoRange`, its query macros and migration helpers; design in [plans/sqlite.md](plans/sqlite.md). 2026-11-01.

* [x] **A frame refused by `cast/2`** — a value of the other frame is a changeset error naming the frame to declare. 2026-11-01.

* [x] **The floating frame** — `frame: :floating` stores floating values in `tsrange` columns and their kin, each column refusing the other frame. 2026-11-01.

* [x] **No `MatchError` placing a stretch at UTC** — an instant that cannot be placed is an `UnsupportedValueError`. 2026-11-01.
