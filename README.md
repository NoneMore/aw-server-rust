# aw-server-rust

[![Build](https://github.com/NoneMore/aw-server-rust/actions/workflows/build.yml/badge.svg?branch=my-v0.13.2-server-patch)](https://github.com/NoneMore/aw-server-rust/actions/workflows/build.yml?query=branch%3Amy-v0.13.2-server-patch)
[![Lint](https://github.com/NoneMore/aw-server-rust/actions/workflows/lint.yml/badge.svg?branch=my-v0.13.2-server-patch)](https://github.com/NoneMore/aw-server-rust/actions/workflows/lint.yml?query=branch%3Amy-v0.13.2-server-patch)

A reimplementation of aw-server in Rust.

## Branch notes

This branch, `my-v0.13.2-server-patch`, is tuned for a local Windows ActivityWatch v0.13.2 setup. Its main goal is to make event range queries fast on large SQLite databases, while producing a replacement `aw-server-rust.exe` that can be dropped into an installed ActivityWatch v0.13.2 directory.

### What changed

- The SQLite schema version is upgraded from `user_version = 4` to `user_version = 5`.
- A composite index was added: `events_bucketrow_endtime_starttime_index` on `events(bucketrow, endtime, starttime)`.
- `get_events` and `get_event_count` explicitly use the composite index so large-bucket queries do not fall back to inefficient plans.
- Datastore tests cover fresh database creation, v4 to v5 migration, index column order, and the SQL index constraint.
- GitHub Actions was reduced to a focused CI setup: Windows builds a release `aw-server-rust.exe` with the v0.13.2 web UI embedded and runs `aw-datastore` tests; Linux runs `fmt` and `clippy`.
- `scripts/verify-ci-artifact.ps1` downloads the cloud-built artifact and verifies it locally against a fresh database, with an optional production database copy check.

### Why this changed

The previous schema only had bucket-oriented indexing. On databases where one bucket contains a very large number of events, SQLite could scan many rows from that bucket before applying the time range filter and ordering. This made endpoints such as `/api/0/buckets/<bucket>/events` slow on large local datasets.

This branch puts the common query shape, `bucketrow + endtime/starttime`, into one index. That lets SQLite locate the bucket and narrow the scan by time range. The CI setup was also reduced to the checks that are useful for this fork, which lowers wait time and Actions usage.

### Observed result

The v4 to v5 migration and query plan were verified on a local copy of a production database. On that database, the largest bucket had about 2.88 million events. A direct SQL query over a 24-hour range went from about 1.2 to 1.5 seconds when forced onto the old index to about 5 ms with the new composite index. Warmed HTTP queries were about 10 to 21 ms.

These numbers are local validation results, not a cross-machine performance guarantee. The important checks are that the query plan uses `events_bucketrow_endtime_starttime_index` and that large-bucket time range queries no longer perform broad scans.

## Build

### Cloud build

The GitHub Actions `Build` workflow creates a binary compatible with the official ActivityWatch v0.13.2 Windows install. It checks out the `aw-webui` submodule, builds `aw-webui/dist`, makes the Rust server report version `0.13.2`, then builds the release server:

```bash
cd aw-webui
npm ci
mkdir -p static
cp media/logo/logo.png static/logo.png
cp media/logo/logo.svg static/logo.svg
npm run build
cd ..
cargo build -p aw-server --release --bin aw-server --verbose
cargo test -p aw-datastore --verbose
```

On success, it uploads this artifact:

```text
binaries-Windows/aw-server-rust.exe
```

Trigger a cloud build for this branch:

```powershell
gh workflow run Build --repo NoneMore/aw-server-rust --ref my-v0.13.2-server-patch
gh run watch --repo NoneMore/aw-server-rust
```

The `Lint` workflow runs formatting and clippy checks separately:

```powershell
gh workflow run Lint --repo NoneMore/aw-server-rust --ref my-v0.13.2-server-patch
gh run watch --repo NoneMore/aw-server-rust
```

### Local build

Development build:

```powershell
cargo build -p aw-server
```

Installer-compatible replacement build:

```powershell
git submodule update --init --recursive aw-webui

Push-Location .\aw-webui
npm ci
New-Item -ItemType Directory -Force .\static
Copy-Item .\media\logo\logo.png .\static\logo.png
Copy-Item .\media\logo\logo.svg .\static\logo.svg
npm run build
Pop-Location

$manifest = "aw-server\Cargo.toml"
$lines = Get-Content -LiteralPath $manifest
for ($i = 0; $i -lt $lines.Count; $i++) {
  if ($lines[$i] -match '^version = ') {
    $lines[$i] = 'version = "0.13.2"'
    break
  }
}
Set-Content -LiteralPath $manifest -Value $lines

cargo build -p aw-server --release --bin aw-server
Copy-Item .\target\release\aw-server.exe .\target\release\aw-server-rust.exe
```

Run datastore tests:

```powershell
cargo test -p aw-datastore
```

Run the server locally:

```powershell
cargo run --bin aw-server
```

Note: `cargo run --bin aw-server` from the repository root starts in testing mode on port `5666`, not the normal `5600` port.

## Verification and testing

### Rust checks

Minimum local check:

```powershell
cargo test -p aw-datastore
```

More complete local check:

```powershell
cargo fmt -- --check
cargo clippy --workspace
cargo test -p aw-datastore
```

### Cloud artifact verification

The verification script requires `git` and `python`. It does not require GitHub CLI for normal artifact verification.

For public repositories, the script first tries unauthenticated GitHub API requests. If GitHub rejects anonymous artifact access or rate limits the request, set one of these environment variables before running it:

```powershell
$env:GH_TOKEN = "<github-token>"
```

or:

```powershell
$env:GITHUB_TOKEN = "<github-token>"
```

A fine-grained token with read access to repository Actions is enough. The token is only used for GitHub API and artifact download requests.

Download the latest successful `Build` artifact for the current branch, then verify server startup, `user_version = 5`, and the new index column order on a temporary fresh database:

```powershell
.\scripts\verify-ci-artifact.ps1 -Cleanup
```

Verify a specific workflow run:

```powershell
.\scripts\verify-ci-artifact.ps1 -RunId <run-id> -Cleanup
```

Also verify a production database copy:

```powershell
.\scripts\verify-ci-artifact.ps1 -VerifyProductionCopy -Cleanup
```

By default, production-copy verification reads:

```text
%LOCALAPPDATA%\activitywatch\aw-server-rust\sqlite.db
```

The script does not modify the production database directly. It copies the database to `tmp-local-test\sqlite-prod-copy.db` with SQLite's backup API, starts the downloaded server binary against that copy, then checks the schema, index, HTTP query timing, and SQLite query plan.

Common parameters:

- `-Branch <name>`: select the branch used to find the latest successful build.
- `-RunId <id>`: download the artifact from a specific Actions run.
- `-ArtifactName <name>`: override the artifact name, defaulting to `binaries-Windows`.
- `-Port <port>`: override the test server port, defaulting to `5666`.
- `-GitHubToken <token>`: pass a token directly instead of using `GH_TOKEN` or `GITHUB_TOKEN`.
- `-ProductionDbPath <path>`: use a specific production database path.
- `-Bucket <name>`, `-Start <iso>`, `-End <iso>`, `-Limit <n>`: control the production-copy query range.
- `-Cleanup`: remove `.ci-bin` and `tmp-local-test` after verification.

## Migration

Migration is automatic when `aw-server` opens the database. When an existing v4 database is first started with a binary from this branch, it creates `events_bucketrow_endtime_starttime_index` and updates `PRAGMA user_version` to `5`.

Recommended flow:

1. Stop the running ActivityWatch / aw-server process.
2. Back up the production database:

   ```powershell
   Copy-Item "$env:LOCALAPPDATA\activitywatch\aw-server-rust\sqlite.db" "$env:LOCALAPPDATA\activitywatch\aw-server-rust\sqlite.db.bak"
   ```

3. Run the verification script against a production database copy:

   ```powershell
   .\scripts\verify-ci-artifact.ps1 -VerifyProductionCopy -Cleanup
   ```

4. Replace the installed `aw-server-rust.exe` with the `aw-server-rust.exe` built from this branch, then start ActivityWatch so it migrates the real database.
5. Confirm the schema version and index after migration:

   ```powershell
   python -c "import sqlite3, os; db=os.path.expandvars(r'%LOCALAPPDATA%\activitywatch\aw-server-rust\sqlite.db'); c=sqlite3.connect(db); print(c.execute('PRAGMA user_version').fetchone()[0]); print(c.execute('PRAGMA index_info(events_bucketrow_endtime_starttime_index)').fetchall())"
   ```

Creating the index can take some time on large databases. Keep the backup until the migrated server has been verified. Older binaries may not accept a database with `user_version = 5`; to roll back, stop the service and restore the backup database file.

## Upstream notes

Compared with the Python implementation of aw-server, the Rust version is still missing:

- API explorer (Swagger/OpenAPI)

For details about aw-sync-rust, see the [README](./aw-sync/README.md) in its subdirectory.
