## Why

ActivityWatch v0.13.2's Rust datastore can take over a second to read a small time range from a large events bucket because SQLite only has single-column indexes for the event query shape. The Flow Launcher investigation traced the delay to `get_events` and `/events` paths scanning large bucket portions before applying time overlap filters and sorting.

## What Changes

- Add datastore support for a composite SQLite index on event bucket and time overlap fields.
- Ensure existing databases receive the index through a controlled migration path.
- Make event range reads and event count queries use the composite index where appropriate so SQLite does not fall back to a bucket-wide scan.
- Add focused regression coverage for schema/index creation and the indexed query path.
- No API response shape changes and no direct modification of a user's production database outside normal server startup migration.

## Capabilities

### New Capabilities
- `event-query-indexing`: Datastore maintains and uses an events composite index for bucket-scoped time overlap queries.

### Modified Capabilities

None.

## Impact

- Affected crate: `aw-datastore`.
- Affected paths: database schema/migration, `get_events`, and `get_event_count`.
- Indirectly improves `aw-query` `query_bucket(...)` and HTTP `/api/0/buckets/{id}/events` because both use datastore event reads.
- Adds SQLite storage overhead for the new index and a one-time migration cost when opening an existing large database.
