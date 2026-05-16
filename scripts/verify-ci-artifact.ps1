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
    [string]$GitHubToken = "",
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
$Script:TestServerProcesses = New-Object System.Collections.Generic.List[System.Diagnostics.Process]

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
Require-Command python

$RepoRootRaw = (& git rev-parse --show-toplevel).Trim()
if ([string]::IsNullOrWhiteSpace($RepoRootRaw)) {
    throw "Unable to resolve git repository root"
}
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRootRaw)
Set-Location $RepoRoot
Write-Log "Repository root: $RepoRoot"

if ([string]::IsNullOrWhiteSpace($GitHubToken)) {
    if (-not [string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
        $GitHubToken = $env:GH_TOKEN
        Write-Log "Using GitHub token from GH_TOKEN"
    } elseif (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
        $GitHubToken = $env:GITHUB_TOKEN
        Write-Log "Using GitHub token from GITHUB_TOKEN"
    } else {
        Write-Log "No GitHub token found; trying unauthenticated GitHub API requests"
    }
}

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
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            try {
                Remove-Item -LiteralPath $full -Recurse -Force
                return
            } catch {
                if ($attempt -eq 5) {
                    throw
                }
                Write-Log "Failed to remove $full; retrying in 1 second ($attempt/5): $($_.Exception.Message)"
                Start-Sleep -Seconds 1
            }
        }
    }
}

function Invoke-PythonScript {
    param(
        [string]$Script,
        [string[]]$Arguments = @(),
        [string]$Description = "Python helper"
    )

    $pythonArgs = @("-") + $Arguments
    $output = $Script | & python @pythonArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed: $($output -join [Environment]::NewLine)"
    }

    $output
}

function Get-RepoParts {
    if ($Repo -notmatch "^[^/]+/[^/]+$") {
        throw "Repo must be in owner/name format, got: $Repo"
    }

    $parts = $Repo.Split("/", 2)
    [pscustomobject]@{
        Owner = $parts[0]
        Name = $parts[1]
    }
}

function Get-GitHubHeaders {
    $headers = @{
        Accept = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
        "User-Agent" = "aw-server-rust-artifact-verifier"
    }

    if (-not [string]::IsNullOrWhiteSpace($GitHubToken)) {
        $headers.Authorization = "Bearer $GitHubToken"
    }

    $headers
}

function Get-ResponseHeader {
    param(
        [object]$Response,
        [string]$Name
    )

    if (-not $Response -or -not $Response.Headers) {
        return ""
    }

    $values = $null
    try {
        if ($Response.Headers.TryGetValues($Name, [ref]$values)) {
            return ($values -join ", ")
        }
    } catch {
        return ""
    }

    ""
}

function Format-RateLimitReset {
    param([string]$ResetEpoch)

    if ([string]::IsNullOrWhiteSpace($ResetEpoch)) {
        return ""
    }

    try {
        $reset = [DateTimeOffset]::FromUnixTimeSeconds([int64]$ResetEpoch).LocalDateTime
        return $reset.ToString("yyyy-MM-dd HH:mm:ss")
    } catch {
        return ""
    }
}

function Invoke-GitHubApi {
    param([string]$PathAndQuery)

    $uri = if ($PathAndQuery.StartsWith("https://", [System.StringComparison]::OrdinalIgnoreCase)) {
        $PathAndQuery
    } else {
        "https://api.github.com$PathAndQuery"
    }

    try {
        $request = @{
            Uri = $uri
            Headers = (Get-GitHubHeaders)
            TimeoutSec = 60
        }

        Invoke-RestMethod @request
    } catch {
        $statusCode = $null
        $response = $null
        $responseProperty = $_.Exception.PSObject.Properties["Response"]
        if ($responseProperty -and $responseProperty.Value -and $responseProperty.Value.StatusCode) {
            $response = $responseProperty.Value
            $statusCode = [int]$responseProperty.Value.StatusCode
        }

        $rateRemaining = Get-ResponseHeader -Response $response -Name "x-ratelimit-remaining"
        $rateReset = Get-ResponseHeader -Response $response -Name "x-ratelimit-reset"
        $rateResetLocal = Format-RateLimitReset -ResetEpoch $rateReset
        $message = $_.Exception.Message
        $isRateLimited = $statusCode -eq 403 -and (
            $message -match "rate limit" -or
            $rateRemaining -eq "0"
        )

        if ($isRateLimited -and [string]::IsNullOrWhiteSpace($GitHubToken)) {
            $resetHint = if ([string]::IsNullOrWhiteSpace($rateResetLocal)) {
                ""
            } else {
                " The anonymous limit resets around $rateResetLocal."
            }
            throw "GitHub anonymous API rate limit exceeded for $uri.$resetHint Set a token for this PowerShell session, then rerun: `$env:GH_TOKEN = '<github-token>'"
        }

        $authHint = if ([string]::IsNullOrWhiteSpace($GitHubToken)) {
            " Set GH_TOKEN or GITHUB_TOKEN if GitHub rejects anonymous artifact access."
        } else {
            " Check that the token has Actions read access for $Repo."
        }
        throw "GitHub API request failed ($statusCode): $uri.$authHint $message"
    }
}

function Resolve-WorkflowId {
    $repoParts = Get-RepoParts
    $encodedOwner = [System.Uri]::EscapeDataString($repoParts.Owner)
    $encodedRepo = [System.Uri]::EscapeDataString($repoParts.Name)
    $workflows = Invoke-GitHubApi "/repos/$encodedOwner/$encodedRepo/actions/workflows?per_page=100"

    $workflowMatch = $workflows.workflows |
        Where-Object {
            $_.name -eq $Workflow -or
            $_.path -eq ".github/workflows/$Workflow" -or
            [System.IO.Path]::GetFileName($_.path) -eq $Workflow -or
            [string]$_.id -eq $Workflow
        } |
        Select-Object -First 1

    if (-not $workflowMatch) {
        $available = ($workflows.workflows | ForEach-Object { "$($_.name) ($([System.IO.Path]::GetFileName($_.path)))" }) -join ", "
        throw "Workflow '$Workflow' was not found in $Repo. Available workflows: $available"
    }

    Write-Log "Resolved workflow '$Workflow' to id $($workflowMatch.id) ($($workflowMatch.name))"
    $workflowMatch.id
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
    $repoParts = Get-RepoParts
    $encodedOwner = [System.Uri]::EscapeDataString($repoParts.Owner)
    $encodedRepo = [System.Uri]::EscapeDataString($repoParts.Name)
    $encodedBranch = [System.Uri]::EscapeDataString($script:Branch)
    $workflowId = Resolve-WorkflowId
    $runs = Invoke-GitHubApi "/repos/$encodedOwner/$encodedRepo/actions/workflows/$workflowId/runs?branch=$encodedBranch&status=success&per_page=1"
    $run = $runs.workflow_runs | Select-Object -First 1

    if (-not $run) {
        throw "No successful '$Workflow' workflow run found for branch '$script:Branch'. Pass -RunId after CI completes."
    }

    Write-Log "Using run $($run.id): $($run.display_title) at $($run.head_sha)"
    Write-Log "Run URL: $($run.html_url)"
    [string]$run.id
}

function Download-Artifact {
    param(
        [string]$ResolvedRunId,
        [string]$Destination
    )

    Remove-InRepoDirectory $Destination
    $downloadPath = Resolve-InRepo $Destination
    New-Item -ItemType Directory -Force $downloadPath | Out-Null

    Write-Log "Resolving artifact metadata before download"
    $repoParts = Get-RepoParts
    $encodedOwner = [System.Uri]::EscapeDataString($repoParts.Owner)
    $encodedRepo = [System.Uri]::EscapeDataString($repoParts.Name)
    $artifacts = Invoke-GitHubApi "/repos/$encodedOwner/$encodedRepo/actions/runs/$ResolvedRunId/artifacts?per_page=100"
    $artifact = $artifacts.artifacts |
        Where-Object { $_.name -eq $ArtifactName } |
        Select-Object -First 1

    if (-not $artifact) {
        throw "Artifact '$ArtifactName' was not found in run $ResolvedRunId"
    }
    if ($artifact.expired) {
        throw "Artifact '$ArtifactName' from run $ResolvedRunId has expired"
    }
    $artifactSizeMb = [math]::Round($artifact.size_in_bytes / 1MB, 2)
    Write-Log "Artifact id: $($artifact.id); compressed size: $artifactSizeMb MB"

    $zipPath = Join-Path $downloadPath "$ArtifactName.zip"
    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }
    Write-Log "Downloading artifact zip into $zipPath"
    Write-Log "Download timeout: $DownloadTimeoutSeconds seconds"

    $downloadStarted = [System.Diagnostics.Stopwatch]::StartNew()
    $downloadJob = Start-Job -ScriptBlock {
        param($Uri, $OutFile, $Headers)
        Invoke-WebRequest -Uri $Uri -Headers $Headers -OutFile $OutFile -MaximumRedirection 10
    } -ArgumentList $artifact.archive_download_url, $zipPath, (Get-GitHubHeaders)

    $nextNoticeSeconds = 30
    while ($downloadJob.State -in @("NotStarted", "Running")) {
        Start-Sleep -Seconds 5
        $elapsedSeconds = [int]$downloadStarted.Elapsed.TotalSeconds
        if ($elapsedSeconds -ge $DownloadTimeoutSeconds) {
            Stop-Job -Job $downloadJob
            Remove-Job -Job $downloadJob -Force
            throw "Timed out downloading artifact '$ArtifactName' from run $ResolvedRunId after $DownloadTimeoutSeconds seconds"
        }

        if ($elapsedSeconds -ge $nextNoticeSeconds) {
            $partialSize = if (Test-Path -LiteralPath $zipPath) {
                [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1MB, 2)
            } else {
                0
            }
            Write-Log "Still downloading artifact '$ArtifactName' ($elapsedSeconds seconds elapsed)"
            Write-Log "Current zip size: $partialSize MB"
            $nextNoticeSeconds += 30
        }
    }

    try {
        Receive-Job -Job $downloadJob -ErrorAction Stop | Out-Null
    } finally {
        Remove-Job -Job $downloadJob -Force
    }
    Write-Log "Artifact download finished in $($downloadStarted.Elapsed.ToString('hh\:mm\:ss'))"

    $zipSizeMb = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1MB, 2)
    Write-Log "Downloaded zip size: $zipSizeMb MB"
    Write-Log "Extracting artifact zip"
    Expand-Archive -LiteralPath $zipPath -DestinationPath $downloadPath -Force

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

    $Script:TestServerProcesses.Add($process)

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
        Write-Log "Stopping aw-server process $($Process.Id)"
        Stop-Process -Id $Process.Id -Force
        Wait-Process -Id $Process.Id -Timeout 10 -ErrorAction SilentlyContinue
        $Process.Refresh()
        if ($Process.HasExited) {
            Write-Log "aw-server process $($Process.Id) stopped"
        } else {
            Write-Log "aw-server process $($Process.Id) did not exit within 10 seconds"
        }
    }
}

function Stop-AllTestServers {
    foreach ($process in @($Script:TestServerProcesses)) {
        Stop-TestServer -Process $process
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

    $output = Invoke-PythonScript `
        -Script $script `
        -Arguments @($Database) `
        -Description "SQLite schema/index check"
    $output | ConvertFrom-Json -DateKind String
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

    $output = Invoke-PythonScript `
        -Script $script `
        -Arguments @($Source, $Destination) `
        -Description "SQLite production database backup"
    [double]$output
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

    $output = Invoke-PythonScript `
        -Script $script `
        -Arguments @($Database, $Bucket, $Start, $End) `
        -Description "Representative query selection"
    $output | ConvertFrom-Json -DateKind String
}

function Wait-ForSqliteIndex {
    param([string]$Database)

    $lastError = ""
    for ($attempt = 1; $attempt -le 12; $attempt++) {
        try {
            return Test-SqliteIndex -Database $Database
        } catch {
            $lastError = $_.Exception.Message
            Write-Log "SQLite migration/index is not visible yet ($attempt/12): $lastError"
            Start-Sleep -Seconds 3
        }
    }

    throw "SQLite migration/index did not become visible in $Database. Last check: $lastError"
}

function Test-ProductionCopyQuery {
    param(
        [string]$Database,
        [pscustomobject]$Query
    )

    $encodedBucket = [System.Uri]::EscapeDataString($Query.bucket)
    $encodedStart = [System.Uri]::EscapeDataString([string]$Query.start)
    $encodedEnd = [System.Uri]::EscapeDataString([string]$Query.end)
    $uri = "http://127.0.0.1:$Port/api/0/buckets/$encodedBucket/events?start=$encodedStart&end=$encodedEnd&limit=$Limit"
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

    $output = Invoke-PythonScript `
        -Script $script `
        -Arguments @($Database, $Query.bucket, $Query.start, $Query.end, [string]$Limit) `
        -Description "SQLite production query plan check"
    $plan = $output | ConvertFrom-Json -DateKind String
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
            $copyCheck = Wait-ForSqliteIndex -Database $copyDb
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
    Stop-AllTestServers
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
