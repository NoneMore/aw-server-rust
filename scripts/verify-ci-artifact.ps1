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
    [int]$DownloadTimeoutSeconds = 180,
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
    }
    if ([string]::IsNullOrWhiteSpace($script:Branch)) {
        throw "Unable to infer current git branch. Pass -Branch or -RunId."
    }

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
    Write-Host "Using run $($run.databaseId) for $($run.displayTitle) at $($run.headSha)"
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
    $downloadProcess = Start-Process `
        -FilePath "gh" `
        -ArgumentList $downloadArgs `
        -RedirectStandardOutput $downloadStdout `
        -RedirectStandardError $downloadStderr `
        -WindowStyle Hidden `
        -PassThru

    if (-not $downloadProcess.WaitForExit($DownloadTimeoutSeconds * 1000)) {
        Stop-Process -Id $downloadProcess.Id -Force
        throw "Timed out downloading artifact '$ArtifactName' from run $ResolvedRunId after $DownloadTimeoutSeconds seconds. Logs: $downloadStdout / $downloadStderr"
    }
    if ($downloadProcess.ExitCode -ne 0) {
        $stderr = if (Test-Path -LiteralPath $downloadStderr) { Get-Content -Raw $downloadStderr } else { "" }
        throw "Failed to download artifact '$ArtifactName' from run $ResolvedRunId. $stderr"
    }

    $binary = Get-ChildItem -LiteralPath $downloadPath -Recurse -Filter aw-server.exe |
        Select-Object -First 1
    if (-not $binary) {
        throw "Artifact '$ArtifactName' did not contain aw-server.exe under $downloadPath"
    }

    $binary.FullName
}

function Wait-ForServer {
    param(
        [System.Diagnostics.Process]$Process,
        [int]$ServerPort
    )

    for ($i = 0; $i -lt $TimeoutSeconds; $i++) {
        if ($Process.HasExited) {
            throw "aw-server exited early with code $($Process.ExitCode)"
        }

        try {
            return Invoke-RestMethod -Uri "http://127.0.0.1:$ServerPort/api/0/info" -TimeoutSec 2
        } catch {
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

    for ($i = 1; $i -le 3; $i++) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $response = Invoke-WebRequest -Uri $uri -TimeoutSec 60
        $sw.Stop()
        $results += [pscustomobject]@{
            Run = $i
            StatusCode = $response.StatusCode
            Milliseconds = $sw.ElapsedMilliseconds
            ContentLength = $response.Content.Length
        }
    }

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

try {
    if ([string]::IsNullOrWhiteSpace($RunId)) {
        $RunId = Get-LatestSuccessfulRunId
    }

    $binary = Download-Artifact -ResolvedRunId $RunId -Destination $DownloadDir
    Write-Host "Downloaded aw-server.exe: $binary"

    Remove-InRepoDirectory $WorkDir
    New-Item -ItemType Directory -Force $WorkPath | Out-Null

    $freshDb = Join-Path $WorkPath "sqlite-smoke.db"
    $freshServer = Start-TestServer -Binary $binary -Database $freshDb -Label "fresh"
    try {
        $freshCheck = Test-SqliteIndex -Database $freshDb
        Write-Host "Fresh database verification passed"
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

        $copyDb = Join-Path $WorkPath "sqlite-prod-copy.db"
        $backupSeconds = Backup-SqliteDatabase -Source $ProductionDbPath -Destination $copyDb
        Write-Host "Production database copy created in $backupSeconds seconds"

        $prodServer = Start-TestServer -Binary $binary -Database $copyDb -Label "production-copy"
        try {
            $copyCheck = Test-SqliteIndex -Database $copyDb
            $query = Get-DefaultQuery -Database $copyDb
            $queryResult = Test-ProductionCopyQuery -Database $copyDb -Query $query

            Write-Host "Production copy verification passed"
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
    }
} finally {
    if ($Cleanup) {
        Remove-InRepoDirectory $DownloadDir
        Remove-InRepoDirectory $WorkDir
    }
}
