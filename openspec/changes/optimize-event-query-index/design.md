## Context

The ActivityWatch v0.13.2 Rust server stores events in SQLite through `aw-datastore`. The current schema has single-column indexes on `events(bucketrow)`, `events(starttime)`, and `events(endtime)`, while the hot read path filters by bucket and overlapping time range, then orders by start time. On large buckets, SQLite can choose a plan that scans all events for the bucket and sorts them before returning a small range.

The target use case is a lightweight personal fork that improves Flow Launcher responsiveness without changing ActivityWatch HTTP APIs or query-language semantics.

## Goals / Non-Goals

**Goals:**

- Add a composite index that matches bucket-scoped time overlap reads.
- Apply the index to both new databases and existing v4 databases.
- Make `get_events` and `get_event_count` reliably use the new index instead of relying on SQLite planner heuristics.
- Preserve existing event clipping, ordering, limit, count, insert, heartbeat, delete, import, and export behavior.
- Keep the implementation scoped to `aw-datastore`.

**Non-Goals:**

- Do not redesign the datastore or introduce a database backend other than SQLite.
- Do not modify Flow Launcher plugin behavior.
- Do not add direct tooling that edits a user's production ActivityWatch database outside the normal server startup path.
- Do not optimize every possible event query shape, such as dedicated latest-event fast paths, in this change.

## Decisions

1. Add a migration from database version 4 to version 5.

   The migration creates `events_bucketrow_endtime_starttime_index` on `events(bucketrow, endtime, starttime)` with `CREATE INDEX IF NOT EXISTS`, then updates `PRAGMA user_version` to `5`. This is more explicit than a startup-only helper and keeps schema state visible through the existing migration mechanism.

   Alternative considered: create the index opportunistically without bumping `user_version`. That keeps rollback to unmodified v0.13.2 easier, but it hides a persistent schema change from the migration history.

2. Use `(bucketrow, endtime, starttime)` rather than `(bucketrow, starttime, endtime)`.

   The report showed recent small-range queries benefit more from the `endtime >= query_start` predicate because `starttime <= query_end` is often broad for near-current queries. Keeping `bucketrow` first still scopes the lookup to a single bucket.

   Alternative considered: `(bucketrow, starttime, endtime)`. It may better match ordering, but it is less selective for the observed workload and can still scan most of a large recent bucket.

3. Use SQLite `INDEXED BY` for the indexed event range reads.

   `get_events` and `get_event_count` will explicitly reference `events_bucketrow_endtime_starttime_index` so the fix does not depend on SQLite choosing the desired plan after statistics change. This is acceptable because the datastore is already SQLite-specific.

   Alternative considered: add only the index and let SQLite choose. The investigation observed planner instability, so that option does not fully address the defect.

4. Keep API semantics unchanged.

   The query result order remains `ORDER BY starttime DESC`, `LIMIT` behavior remains unchanged, and overlapping events are still clipped to the requested time interval in Rust after retrieval. The index changes access strategy, not public behavior.

## Risks / Trade-offs

- Database version bump prevents unmodified v0.13.2 from opening a migrated database -> Mitigate by documenting backup/rollback expectations before using the fork on a production database.
- Creating the index on a large existing database can take seconds and increase disk usage -> Mitigate by using one migration, making it idempotent, and noting the one-time migration cost.
- `INDEXED BY` is SQLite-specific and can fail if the migration is missing -> Mitigate by creating the index in both fresh schema initialization and v4-to-v5 migration before indexed queries can run.
- For broad unbounded reads, the composite index may not be optimal for every shape -> Mitigate by preserving correctness first and limiting this change to the known hot bucket-scoped overlap paths; future work can add query-shape-specific paths if needed.

## Migration Plan

1. Update `NEWEST_DB_VERSION` from `4` to `5`.
2. Add `_migrate_v4_to_v5(conn)` and call it when `version < 5`.
3. Create `events_bucketrow_endtime_starttime_index` during the migration.
4. Ensure fresh database initialization also reaches version 5 through the same migration chain.
5. Before replacing a production server binary, stop ActivityWatch and back up `sqlite.db`.
6. Start the forked server and let the migration create the index once.
7. Verify with `EXPLAIN QUERY PLAN` on representative `get_events` and `get_event_count` shapes.

Rollback requires restoring a database backup made before the v5 migration, or manually removing the index and setting `PRAGMA user_version` back only if the operator understands the compatibility risk.

## Production Rollout Precautions

Before running the fork against a production ActivityWatch database:

1. Stop ActivityWatch so `sqlite.db` is not being written while the binary is replaced.
2. Back up the production `sqlite.db` before first startup with the v5 migration.
3. Start the server binary produced by GitHub Actions for this branch or PR.
4. Verify representative query plans after startup with `EXPLAIN QUERY PLAN` for both the event range read and event count shapes, confirming `events_bucketrow_endtime_starttime_index` appears in the plan.

## Open Questions

- Should a later upstream-oriented change split latest-event `limit=1` reads into a dedicated fast path?
- Should broad export-style reads avoid `INDEXED BY` if performance testing shows the composite index is worse for full-bucket reads?
