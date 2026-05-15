## 1. Schema Migration

- [x] 1.1 Update `aw-datastore/src/datastore.rs` database version from `4` to `5`.
- [x] 1.2 Add `_migrate_v4_to_v5(conn)` that creates `events_bucketrow_endtime_starttime_index` on `events(bucketrow, endtime, starttime)` with `CREATE INDEX IF NOT EXISTS`.
- [x] 1.3 Wire `_migrate_v4_to_v5(conn)` into `_create_tables` so existing v4 databases and fresh databases reach version 5 through the migration chain.

## 2. Indexed Query Path

- [x] 2.1 Update `get_events` SQL to reference `events_bucketrow_endtime_starttime_index` with SQLite `INDEXED BY`.
- [x] 2.2 Update `get_event_count` SQL to reference `events_bucketrow_endtime_starttime_index` with SQLite `INDEXED BY`.
- [x] 2.3 Confirm event ordering, clipping, limit, and count behavior remain unchanged.

## 3. Tests

- [x] 3.1 Add datastore test coverage that a fresh database contains `events_bucketrow_endtime_starttime_index`.
- [x] 3.2 Add datastore test coverage that a v4 database is migrated to v5 and the composite index exists after initialization.
- [x] 3.3 Add query-plan or SQL-level regression coverage proving `get_events` and `get_event_count` use the composite index.
- [x] 3.4 Ensure the added tests are included in the repository's normal Rust test targets so GitHub Actions can execute them.

## 4. Verification

- [x] 4.1 Do not rely on local Rust tooling; assume no local `cargo`, `rustc`, or Rust formatter is available.
- [x] 4.2 Review the changed Rust files textually for obvious syntax, import, and formatting issues before pushing.
- [ ] 4.3 Push the implementation branch and use GitHub Actions CI as the authoritative formatting, build, and test verification path.
- [x] 4.4 Confirm CI runs the relevant Rust formatting, build, and test jobs for `aw-datastore` or the workspace.
- [ ] 4.5 Inspect failed CI logs, adjust the implementation or tests locally as plain text edits, and rerun CI until the required jobs pass.
- [x] 4.6 Document manual production rollout precautions: stop ActivityWatch, back up `sqlite.db`, start the GitHub Actions-built server binary, and verify representative `EXPLAIN QUERY PLAN` output.
