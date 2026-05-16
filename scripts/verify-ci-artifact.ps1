[CmdletBinding()]
param(
    [string]$Repo = "NoneMore/aw-server-rust",
    [string]$Branch = "",
    [string]$Workflow = "Build",
    [string]$RunId = "",
    [string]$ArtifactName = "binaries-Windows",
    [string]$DownloadDir = ".ci-bin",
    [string]$WorkDir = "tmp-local-test",
    [int]$Port = 5666,
    [int]$TimeoutSeconds = 120,
    [int]$DownloadTimeoutSeconds = 600,
    [switch]$VerifyProductionCopy,
    [string]$ProductionDbPath = "",
    [string]$Bucket = "",
    [string]$Start = "",
    [string]$End = "",
    [int]$Limit = 100,
    [switch]$Cleanup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

function Write-Log {
    param([string]$Message)

    $elapsed = $ScriptStopwatch.Elapsed.ToString("hh\:mm\:ss")
    Write-Host "[$elapsed] $Message"
}

function Require-Command {
    param([string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command not found on PATH: $Name"
    }
}

Require-Command git
Require-Command gh
Require-Command python

$RepoRootRaw = (& git rev-parse --show-toplevel).Trim()
if ([string]::IsNullOrWhiteSpace($RepoRootRaw)) {
    throw "Unable to resolve git repository root"
}
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRootRaw)
Set-Location $RepoRoot
Write-Log "Repository root: $RepoRoot"

function Resolve-InRepo {
    param([string]$Path)

    $combined = if ([System.IO.Path]::IsPathRooted($Path)) {
        $Path
    } else {
        Join-Path $RepoRoot $Path
    }
    $full = [System.IO.Path]::GetFullPath($combined)
    $rootWithSlash = $RepoRoot.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar

    if ($full -ne $RepoRoot -and -not $full.StartsWith($rootWithSlash, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to use a path outside the repository: $full"
    }

    $full
}

function Remove-InRepoDirectory {
    param([string]$Path)

    $full = Resolve-InRepo $Path
    if (Test-Path -LiteralPath $full) {
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}

function Get-LatestSuccessfulRunId {
    if ([string]::IsNullOrWhiteSpace($Branch)) {
        $script:Branch = (& git branch --show-current).Trim()
        Write-Log "Inferred current branch: $script:Branch"
    }
    if ([string]::IsNullOrWhiteSpace($script:Branch)) {
        throw "Unable to infer current git branch. Pass -Branch or -RunId."
    }

    Write-Log "Looking for latest successful '$Workflow' run on branch '$script:Branch' in $Repo"
    $runJson = gh run list `
        --repo $Repo `
        --workflow $Workflow `
        --branch $script:Branch `
        --status success `
        --limit 1 `
        --json databaseId,headSha,url,displayTitle,updatedAt `
        --jq ".[0]"

    if ([string]::IsNullOrWhiteSpace($runJson) -or $runJson -eq "null") {
        throw "No successful '$Workflow' workflow run found for branch '$script:Branch'. Pass -RunId after CI completes."
    }

    $run = $runJson | ConvertFrom-Json
    Write-Log "Using run $($run.databaseId): $($run.displayTitle) at $($run.headSha)"
    Write-Log "Run URL: $($run.url)"
    [string]$run.databaseId
}

function Download-Artifact {
    param(
        [string]$ResolvedRunId,
        [string]$Destination
    )

    Remove-InRepoDirectory $Destination
    $downloadPath = Resolve-InRepo $Destination
    New-Item -ItemType Directory -Force $downloadPath | Out-Null

    $downloadStdout = Join-Path $downloadPath "gh-download.stdout.log"
    $downloadStderr = Join-Path $downloadPath "gh-download.stderr.log"
    $downloadArgs = @("run", "download", $ResolvedRunId, "--repo", $Repo, "-n", $ArtifactName, "-D", $downloadPath)
    Write-Log "Downloading artifact '$ArtifactName' from run $ResolvedRunId into $downloadPath"
    Write-Log "Download timeout: $DownloadTimeoutSeconds seconds; logs: $downloadStdout / $downloadStderr"
    $downloadProcess = Start-Process `
        -FilePath "gh" `
        -ArgumentList $downloadArgs `
        -RedirectStandardOutput $downloadStdout `
        -RedirectStandardError $downloadStderr `
        -WindowStyle Hidden `
        -PassThru

    $downloadStarted = [System.Diagnostics.Stopwatch]::StartNew()
    $nextNoticeSeconds = 30
    while (-not $downloadProcess.WaitForExit(5000)) {
        $elapsedSeconds = [int]$downloadStarted.Elapsed.TotalSeconds
        if ($elapsedSeconds -ge $DownloadTimeoutSeconds) {
            Stop-Process -Id $downloadProcess.Id -Force
            throw "Timed out downloading artifact '$ArtifactName' from run $ResolvedRunId after $DownloadTimeoutSeconds seconds. Logs: $downloadStdout / $downloadStderr"
        }
        if ($elapsedSeconds -ge $nextNoticeSeconds) {
            Write-Log "Still downloading artifact '$ArtifactName' ($elapsedSeconds seconds elapsed)"
            $nextNoticeSeconds += 30
        }
    }
    if ($downloadProcess.ExitCode -ne 0) {
        $stderr = if (Test-Path -LiteralPath $downloadStderr) { Get-Content -Raw $downloadStderr } else { "" }
        throw "Failed to download artifact '$ArtifactName' from run $ResolvedRunId. $stderr"
    }
    Write-Log "Artifact download finished in $($downloadStarted.Elapsed.ToString('hh\:mm\:ss'))"

    $binary = Get-ChildItem -LiteralPath $downloadPath -Recurse -Filter aw-server.exe |
        Select-Object -First 1
    if (-not $binary) {
        throw "Artifact '$ArtifactName' did not contain aw-server.exe under $downloadPath"
    }

    $binarySizeMb = [math]::Round($binary.Length / 1MB, 2)
    Write-Log "Found aw-server.exe at $($binary.FullName) ($binarySizeMb MB)"
    $binary.FullName
}

function Wait-ForServer {
    param(
        [System.Diagnostics.Process]$Process,
        [int]$ServerPort
    )

    Write-Log "Waiting up to $TimeoutSeconds seconds for aw-server on port $ServerPort"
    for ($i = 0; $i -lt $TimeoutSeconds; $i++) {
        if ($Process.HasExited) {
            throw "aw-server exited early with code $($Process.ExitCode)"
        }

        try {
            $info = Invoke-RestMethod -Uri "http://127.0.0.1:$ServerPort/api/0/info" -TimeoutSec 2
            Write-Log "aw-server responded on port $ServerPort"
            return $info
        } catch {
            if ($i -gt 0 -and ($i % 10) -eq 0) {
                Write-Log "Still waiting for aw-server on port $ServerPort ($i seconds elapsed)"
            }
            Start-Sleep -Seconds 1
        }
    }

    throw "aw-server did not respond on port $ServerPort within $TimeoutSeconds seconds"
}

function Start-TestServer {
    param(
        [string]$Binary,
        [string]$Database,
        [string]$Label
    )

    $stdoutLog = Join-Path $WorkPath "$Label.stdout.log"
    $stderrLog = Join-Path $WorkPath "$Label.stderr.log"
    if (Test-Path -LiteralPath $stdoutLog) { Remove-Item -LiteralPath $stdoutLog -Force }
    if (Test-Path -LiteralPath $stderrLog) { Remove-Item -LiteralPath $stderrLog -Force }

    $existing = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if ($existing) {
        throw "Port $Port is already in use. Pass -Port with a free port."
    }

    Write-Log "Starting aw-server for '$Label' on port $Port"
    Write-Log "Database: $Database"
    Write-Log "Server logs: $stdoutLog / $stderrLog"
    $process = Start-Process `
        -FilePath $Binary `
        -ArgumentList @("--testing", "--port", [string]$Port, "--dbpath", $Database, "--verbose") `
        -WindowStyle Hidden `
        -RedirectStandardOutput $stdoutLog `
        -RedirectStandardError $stderrLog `
        -PassThru

    try {
        $info = Wait-ForServer -Process $process -ServerPort $Port
        [pscustomobject]@{
            Process = $process
            Info = $info
            StdoutLog = $stdoutLog
            StderrLog = $stderrLog
        }
    } catch {
        if (-not $process.HasExited) {
            Stop-Process -Id $process.Id -Force
            Wait-Process -Id $process.Id -Timeout 10 -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Stop-TestServer {
    param([System.Diagnostics.Process]$Process)

    if ($Process -and -not $Process.HasExited) {
        Stop-Process -Id $Process.Id -Force
        Wait-Process -Id $Process.Id -Timeout 10 -ErrorAction SilentlyContinue
    }
}

function Test-SqliteIndex {
    param([string]$Database)

    Write-Log "Checking SQLite schema version and event query index in $Database"
    $script = @'
import json
import sqlite3
import sys

db = sys.argv[1]
conn = sqlite3.connect(db)
version = conn.execute("PRAGMA user_version").fetchone()[0]
columns = [row[2] for row in conn.execute("PRAGMA index_info(events_bucketrow_endtime_starttime_index)").fetchall()]
print(json.dumps({"user_version": version, "index_columns": columns}))
if version != 5:
    raise SystemExit(f"expected user_version 5, got {version}")
if columns != ["bucketrow", "endtime", "starttime"]:
    raise SystemExit(f"unexpected index columns: {columns}")
'@

    ($script | python - $Database) | ConvertFrom-Json
}

function Backup-SqliteDatabase {
    param(
        [string]$Source,
        [string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Production database not found: $Source"
    }
    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Force
    }

    Write-Log "Copying production database from $Source"
    Write-Log "Production copy destination: $Destination"
    $script = @'
import sqlite3
import sys
import time

src, dst = sys.argv[1], sys.argv[2]
started = time.perf_counter()
source = sqlite3.connect(f"file:{src}?mode=ro", uri=True, timeout=30)
dest = sqlite3.connect(dst)
source.backup(dest, pages=1000)
dest.close()
source.close()
print(f"{time.perf_counter() - started:.2f}")
'@

    [double]($script | python - $Source $Destination)
}

function Get-DefaultQuery {
    param([string]$Database)

    Write-Log "Selecting representative bucket and 24-hour query range"
    $script = @'
import json
import sqlite3
import sys
from datetime import datetime, timedelta, timezone

db, bucket, start, end = sys.argv[1:5]
conn = sqlite3.connect(db)
if not bucket:
    row = conn.execute("""
        SELECT buckets.name, count(events.id) AS n
        FROM buckets
        LEFT JOIN events ON buckets.id = events.bucketrow
        GROUP BY buckets.id
        ORDER BY n DESC
        LIMIT 1
    """).fetchone()
    bucket = row[0]

bucketrow, max_end = conn.execute("""
    SELECT buckets.id, max(events.endtime)
    FROM buckets
    LEFT JOIN events ON buckets.id = events.bucketrow
    WHERE buckets.name = ?
    GROUP BY buckets.id
""", (bucket,)).fetchone()

def ns_to_dt(ns):
    return datetime.fromtimestamp(ns / 1_000_000_000, timezone.utc)

if not end:
    end_dt = ns_to_dt(max_end)
    end = end_dt.isoformat().replace("+00:00", "Z")
else:
    end_dt = datetime.fromisoformat(end.replace("Z", "+00:00"))

if not start:
    start = (end_dt - timedelta(hours=24)).isoformat().replace("+00:00", "Z")

print(json.dumps({"bucket": bucket, "bucketrow": bucketrow, "start": start, "end": end}))
'@

    ($script | python - $Database $Bucket $Start $End) | ConvertFrom-Json
}

function Test-ProductionCopyQuery {
    param(
        [string]$Database,
        [pscustomobject]$Query
    )

    $encodedBucket = [System.Uri]::EscapeDataString($Query.bucket)
    $uri = "http://127.0.0.1:$Port/api/0/buckets/$encodedBucket/events?start=$($Query.start)&end=$($Query.end)&limit=$Limit"
    $results = @()

    Write-Log "Running HTTP query verification for bucket '$($Query.bucket)'"
    Write-Log "Range: $($Query.start) -> $($Query.end); limit: $Limit"
    for ($i = 1; $i -le 3; $i++) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $response = Invoke-WebRequest -Uri $uri -TimeoutSec 60
        $sw.Stop()
        Write-Log "HTTP query run $i returned $($response.StatusCode) in $($sw.ElapsedMilliseconds) ms"
        $results += [pscustomobject]@{
            Run = $i
            StatusCode = $response.StatusCode
            Milliseconds = $sw.ElapsedMilliseconds
            ContentLength = $response.Content.Length
        }
    }

    Write-Log "Checking SQLite query plan and matching row count"
    $script = @'
import json
import sqlite3
import sys
from datetime import datetime

db, bucket, start, end, limit = sys.argv[1:6]
conn = sqlite3.connect(db)
bucketrow = conn.execute("SELECT id FROM buckets WHERE name = ?", (bucket,)).fetchone()[0]

def iso_to_ns(value):
    dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    return int(dt.timestamp() * 1_000_000_000)

start_ns = iso_to_ns(start)
end_ns = iso_to_ns(end)
plan = conn.execute("""
    EXPLAIN QUERY PLAN
    SELECT id, starttime, endtime, data
    FROM events INDEXED BY events_bucketrow_endtime_starttime_index
    WHERE bucketrow = ? AND endtime >= ? AND starttime <= ?
    ORDER BY starttime DESC
    LIMIT ?
""", (bucketrow, start_ns, end_ns, int(limit))).fetchall()
count = conn.execute("""
    SELECT count(*)
    FROM events INDEXED BY events_bucketrow_endtime_starttime_index
    WHERE bucketrow = ? AND endtime >= ? AND starttime <= ?
""", (bucketrow, start_ns, end_ns)).fetchone()[0]
print(json.dumps({"count": count, "plan": plan}))
'@

    $plan = ($script | python - $Database $Query.bucket $Query.start $Query.end $Limit) | ConvertFrom-Json
    [pscustomobject]@{
        Query = $Query
        HttpResults = $results
        Sqlite = $plan
    }
}

$DownloadPath = Resolve-InRepo $DownloadDir
$WorkPath = Resolve-InRepo $WorkDir
Write-Log "GitHub repo: $Repo"
Write-Log "Workflow: $Workflow; artifact: $ArtifactName"
Write-Log "Download directory: $DownloadPath"
Write-Log "Work directory: $WorkPath"

try {
    if ([string]::IsNullOrWhiteSpace($RunId)) {
        Write-Log "No -RunId supplied; resolving latest successful workflow run"
        $RunId = Get-LatestSuccessfulRunId
    } else {
        Write-Log "Using explicit workflow run id: $RunId"
    }

    $binary = Download-Artifact -ResolvedRunId $RunId -Destination $DownloadDir
    Write-Log "Downloaded aw-server.exe: $binary"

    Remove-InRepoDirectory $WorkDir
    New-Item -ItemType Directory -Force $WorkPath | Out-Null

    Write-Log "Preparing fresh database smoke test"
    $freshDb = Join-Path $WorkPath "sqlite-smoke.db"
    $freshServer = Start-TestServer -Binary $binary -Database $freshDb -Label "fresh"
    try {
        $freshCheck = Test-SqliteIndex -Database $freshDb
        Write-Log "Fresh database verification passed"
        [pscustomobject]@{
            Kind = "fresh"
            Testing = $freshServer.Info.testing
            Hostname = $freshServer.Info.hostname
            Database = $freshDb
            UserVersion = $freshCheck.user_version
            IndexColumns = ($freshCheck.index_columns -join ", ")
        } | Format-List
    } finally {
        Stop-TestServer -Process $freshServer.Process
    }

    if ($VerifyProductionCopy) {
        if ([string]::IsNullOrWhiteSpace($ProductionDbPath)) {
            $ProductionDbPath = Join-Path $env:LOCALAPPDATA "activitywatch\aw-server-rust\sqlite.db"
        }

        Write-Log "Preparing production database copy verification"
        $copyDb = Join-Path $WorkPath "sqlite-prod-copy.db"
        $backupSeconds = Backup-SqliteDatabase -Source $ProductionDbPath -Destination $copyDb
        Write-Log "Production database copy created in $backupSeconds seconds"

        $prodServer = Start-TestServer -Binary $binary -Database $copyDb -Label "production-copy"
        try {
            $copyCheck = Test-SqliteIndex -Database $copyDb
            $query = Get-DefaultQuery -Database $copyDb
            $queryResult = Test-ProductionCopyQuery -Database $copyDb -Query $query

            Write-Log "Production copy verification passed"
            [pscustomobject]@{
                Kind = "production-copy"
                Database = $copyDb
                UserVersion = $copyCheck.user_version
                IndexColumns = ($copyCheck.index_columns -join ", ")
                Bucket = $query.bucket
                Range = "$($query.start) -> $($query.end)"
                Count = $queryResult.Sqlite.count
                Plan = ($queryResult.Sqlite.plan | ConvertTo-Json -Compress)
            } | Format-List
            $queryResult.HttpResults | Format-Table -AutoSize
        } finally {
            Stop-TestServer -Process $prodServer.Process
        }
    } else {
        Write-Log "Skipping production copy verification. Add -VerifyProductionCopy to test against a copied local ActivityWatch database."
    }
} finally {
    if ($Cleanup) {
        Write-Log "Cleanup requested; removing temporary directories"
        Remove-InRepoDirectory $DownloadDir
        Remove-InRepoDirectory $WorkDir
        Write-Log "Cleanup complete"
    } else {
        Write-Log "Temporary files kept in $DownloadPath and $WorkPath"
    }
    Write-Log "Verification script finished in $($ScriptStopwatch.Elapsed.ToString('hh\:mm\:ss'))"
}
