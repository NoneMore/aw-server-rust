# Event Query Indexing Specification

## Requirements

### Requirement: Events composite index migration
The datastore SHALL maintain a SQLite index named `events_bucketrow_endtime_starttime_index` on `events(bucketrow, endtime, starttime)`.

#### Scenario: Fresh database creates composite index
- **WHEN** the datastore initializes a new database
- **THEN** the database contains `events_bucketrow_endtime_starttime_index` on `events(bucketrow, endtime, starttime)`

#### Scenario: Existing v4 database migrates to v5
- **WHEN** the datastore opens a database with `PRAGMA user_version = 4`
- **THEN** the datastore creates `events_bucketrow_endtime_starttime_index`
- **AND** updates `PRAGMA user_version` to `5`

### Requirement: Event range reads use composite index
The datastore SHALL execute bucket-scoped event range reads through `events_bucketrow_endtime_starttime_index` so SQLite does not select a single-column index for the overlap query.

#### Scenario: get_events uses composite index
- **WHEN** `get_events` queries a bucket with start and end bounds
- **THEN** the SQL query references `events_bucketrow_endtime_starttime_index`
- **AND** returns the same events, clipping, ordering, and limit semantics as before

#### Scenario: get_event_count uses composite index
- **WHEN** `get_event_count` counts events for a bucket with start and end bounds
- **THEN** the SQL query references `events_bucketrow_endtime_starttime_index`
- **AND** returns the same count semantics as before

### Requirement: Public event query behavior remains compatible
The server SHALL preserve existing public behavior for datastore event queries while changing only the SQLite access strategy.

#### Scenario: HTTP events endpoint remains compatible
- **WHEN** a client calls `/api/0/buckets/{id}/events` with supported query parameters
- **THEN** the response schema, ordering, filtering, clipping, and limit behavior remain compatible with the existing v0.13.2 behavior

#### Scenario: Query language bucket reads remain compatible
- **WHEN** `query_bucket(...)` reads events through the datastore
- **THEN** the returned event data remains compatible with the existing v0.13.2 behavior
