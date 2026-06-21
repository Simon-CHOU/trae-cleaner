<#
.SYNOPSIS
    Analyze SpaceSniffer "Group by Folder" report for stale build-tool
    caches, then optionally move them to the Recycle Bin.

.DESCRIPTION
    Parses a SpaceSniffer .txt report to identify known cache directories
    (Maven, Gradle, npm, pnpm, Yarn, Cargo, pip, uv).  For each existing
    cache, checks the filesystem to decide whether the directory has been
    touched in the last 30 days — if not, it is "fully stale."

    Dry-run shows a report; -Execute sends fully-stale directories to the
    Recycle Bin via SHFileOperationW (FOF_ALLOWUNDO).

.PARAMETER Report
    Path to a SpaceSniffer .txt report exported with "Group by Folder".

.PARAMETER Execute
    Move fully-stale cache directories to the Recycle Bin.

.PARAMETER ThresholdDays
    Age threshold in days (default 30).
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$Report,

    [switch]$Execute,

    [int]$ThresholdDays = 30
)

$ErrorActionPreference = "Continue"

# ── Recycle Bin API ──────────────────────────────
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class ShellNative {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct SHFILEOPSTRUCT {
        public IntPtr   hwnd;
        public uint     wFunc;
        public string   pFrom;
        public string   pTo;
        public ushort   fFlags;
        public bool     fAnyOperationsAborted;
        public IntPtr   hNameMappings;
        public string   lpszProgressTitle;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern int SHFileOperation(ref SHFILEOPSTRUCT lpFileOp);

    public const uint   FO_DELETE          = 3;
    public const ushort FOF_ALLOWUNDO      = 0x0040;
    public const ushort FOF_NOCONFIRMATION = 0x0010;
    public const ushort FOF_NOERRORUI      = 0x0400;
    public const ushort FOF_SILENT         = 0x0004;
}
'@

function SendToRecycleBin {
    param([string]$Path)
    $f = [ShellNative+SHFILEOPSTRUCT]::new()
    $f.wFunc  = [ShellNative]::FO_DELETE
    $f.pFrom  = $Path + "`0`0"
    $f.fFlags = [ShellNative]::FOF_ALLOWUNDO `
              -bor [ShellNative]::FOF_NOCONFIRMATION `
              -bor [ShellNative]::FOF_NOERRORUI `
              -bor [ShellNative]::FOF_SILENT
    $rc = [ShellNative]::SHFileOperation([ref]$f)
    if ($rc -ne 0) {
        Write-Warning "  SHFileOperation failed (0x$($rc.ToString('X8'))) for: $Path"
        return $false
    }
    return $true
}

# ── Helpers ──────────────────────────────────────
function Format-Bytes {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return "$([math]::Round($Bytes/1GB, 2)) GB" }
    if ($Bytes -ge 1MB) { return "$([math]::Round($Bytes/1MB, 2)) MB" }
    if ($Bytes -ge 1KB) { return "$([math]::Round($Bytes/1KB, 2)) KB" }
    return "$Bytes B"
}

# Parse a SpaceSniffer size string like "4.3GB", "600.2MB", "126.2MB"
function Parse-SpaceSnifferSize {
    param([string]$Raw)
    if ($Raw -match '([\d.]+)\s*(GB|MB|KB|B)') {
        $val = [double]$Matches[1]
        switch ($Matches[2]) {
            'GB' { return [long]($val * 1GB) }
            'MB' { return [long]($val * 1MB) }
            'KB' { return [long]($val * 1KB) }
            'B'  { return [long]$val }
        }
    }
    return 0L
}

$Cutoff = (Get-Date).AddDays(-$ThresholdDays)

# Check staleness: find the NEWEST file in the directory tree.
# If the newest file is older than the cutoff -> fully stale.
# Returns @{ NewestDate=...; NewestFile=...; TotalFiles=...; TotalSize=...; FullyStale=$bool }
function Get-StalenessInfo {
    param([string]$DirPath)
    $newestDate = [DateTime]::MinValue
    $newestFile = $null
    $totalFiles  = 0L
    $totalSize   = 0L

    try {
        $items = Get-ChildItem -Path $DirPath -Recurse -File -ErrorAction Stop
        foreach ($item in $items) {
            $totalFiles++
            $totalSize += $item.Length
            $t = $item.LastWriteTime
            if ($t -gt $newestDate) {
                $newestDate = $t
                $newestFile = $item.FullName
            }
        }
    } catch {
        Write-Warning "  Cannot scan: $DirPath — $_"
    }

    return [PSCustomObject]@{
        NewestDate  = $newestDate
        NewestFile  = $newestFile
        TotalFiles  = $totalFiles
        TotalSize   = $totalSize
        FullyStale  = ($newestDate -ne [DateTime]::MinValue) -and ($newestDate -lt $Cutoff)
    }
}

# ── Parse SpaceSniffer report → path → size lookup ──
function Parse-SpaceSnifferReport {
    param([string]$FilePath)

    $dirSizes = @{}   # normalized path → size in bytes
    $lines = Get-Content -Path $FilePath -Encoding UTF8

    # Lines that are directories:  ^(spaces) C:\full\path [...] [size]
    # Files look like:             ^(spaces) [size] filename
    $dirRegex = '^\s*(?<path>[A-Za-z]:\\.+?)\s+\[(?<size>[\d.]+[KMGT]?B)\]'

    foreach ($line in $lines) {
        if ($line -match $dirRegex) {
            $normalized = $Matches['path'].TrimEnd('\')
            $dirSizes[$normalized] = Parse-SpaceSnifferSize $Matches['size']
        }
    }
    return $dirSizes
}

# ── Known cache roots ────────────────────────────
$KnownCaches = @(
    @{Path="$env:USERPROFILE\.m2\repository";    Name="Maven repository"},
    @{Path="$env:USERPROFILE\.m2\wrapper";       Name="Maven wrapper"},
    @{Path="$env:USERPROFILE\.gradle\caches";    Name="Gradle caches"},
    @{Path="$env:LOCALAPPDATA\npm-cache";        Name="npm cache"},
    @{Path="$env:LOCALAPPDATA\pnpm-cache";       Name="pnpm cache"},
    @{Path="$env:LOCALAPPDATA\Yarn";             Name="Yarn (classic)"},
    @{Path="$env:USERPROFILE\.yarn\berry\cache"; Name="Yarn (berry)"},
    @{Path="$env:USERPROFILE\.cargo\registry";   Name="Cargo registry"},
    @{Path="$env:USERPROFILE\.cargo\git";        Name="Cargo git"},
    @{Path="$env:LOCALAPPDATA\pip\cache";        Name="pip cache"},
    @{Path="$env:LOCALAPPDATA\uv\cache";         Name="uv cache"}
)

# ═══════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════

if (-not (Test-Path $Report -PathType Leaf)) {
    Write-Error "Report not found: $Report"
    exit 1
}

Write-Host "============================================"
Write-Host " Build-Tool Cache Staleness Analyzer"
Write-Host " Report:  $Report"
Write-Host " Threshold: $ThresholdDays days"
Write-Host " Mode:    $(if ($Execute) { 'EXECUTE (-> Recycle Bin)' } else { 'DRY-RUN (report only)' })"
Write-Host "============================================"
Write-Host ""

# Step 1 — parse SpaceSniffer report
Write-Host "[1/3] Parsing SpaceSniffer report..." -ForegroundColor Cyan
$ssSizes = Parse-SpaceSnifferReport $Report
Write-Host "      Extracted $($ssSizes.Count) directory entries." -ForegroundColor DarkGray
Write-Host ""

# Step 2 — cross-reference with known caches + staleness check
Write-Host "[2/3] Checking known cache directories..." -ForegroundColor Cyan
Write-Host ""

$results = @()
$grandTotal = 0L
$grandStale = 0L
$grandStaleCount = 0

foreach ($cache in $KnownCaches) {
    $cachePath = $cache.Path
    $cacheName = $cache.Name

    if (-not (Test-Path $cachePath -PathType Container)) {
        Write-Host "  [ABSENT] $cacheName — $cachePath" -ForegroundColor DarkGray
        continue
    }

    # Check staleness (quick filesystem scan)
    Write-Host "  [CHECK] $cacheName ..." -ForegroundColor DarkYellow -NoNewline
    $stale = Get-StalenessInfo $cachePath
    Write-Host " $(Format-Bytes $stale.TotalSize)  ($($stale.TotalFiles) files)" -ForegroundColor White

    $reportedSize = $ssSizes[$cachePath]
    # Use max of filesystem scan and report (report may be more accurate for total)
    $displaySize = if ($reportedSize -gt 0) { $reportedSize } else { $stale.TotalSize }

    if ($stale.TotalFiles -eq 0) {
        Write-Host "           (empty directory)" -ForegroundColor DarkGray
        continue
    }

    $grandTotal += $displaySize

    $verdict = ""
    $verdictColor = "White"
    if ($stale.FullyStale) {
        $verdict = "FULLY STALE — candidate for cleanup"
        $verdictColor = "Green"
        $grandStale += $displaySize
        $grandStaleCount++
    } else {
        $age = [math]::Round(((Get-Date) - $stale.NewestDate).TotalDays, 0)
        $verdict = "ACTIVE — newest file ${age}d ago  ($($stale.NewestFile))"
        $verdictColor = "DarkYellow"
    }

    Write-Host "           $verdict" -ForegroundColor $verdictColor

    $results += [PSCustomObject]@{
        Name        = $cacheName
        Path        = $cachePath
        ReportedSize = $displaySize
        TotalFiles  = $stale.TotalFiles
        NewestDate  = $stale.NewestDate
        NewestFile  = $stale.NewestFile
        FullyStale  = $stale.FullyStale
    }
}

Write-Host ""

# Step 3 — summary / execute
Write-Host "[3/3] $(if ($Execute) { 'Executing' } else { 'Summary' })" -ForegroundColor Cyan
Write-Host ""

$foundCount = $results.Count
$staleResults = $results | Where-Object { $_.FullyStale }
$activeResults = $results | Where-Object { -not $_.FullyStale }

Write-Host "  Caches found:  $foundCount"
Write-Host "  Total size:    $(Format-Bytes $grandTotal)"
Write-Host "  Fully stale:   $grandStaleCount  ($(Format-Bytes $grandStale))"
Write-Host "  Active:        $($activeResults.Count)"
Write-Host ""

if ($staleResults.Count -eq 0) {
    Write-Host "  No fully-stale caches to clean." -ForegroundColor DarkGray
    exit 0
}

if (-not $Execute) {
    # Dry-run report
    Write-Host "  DRY-RUN — the following would be moved to Recycle Bin:" -ForegroundColor Cyan
    Write-Host ""
    foreach ($r in $staleResults) {
        Write-Host "    $($r.Name):  $(Format-Bytes $r.ReportedSize)  — $($r.Path)" -ForegroundColor Green
    }
    Write-Host ""
    Write-Host "  To execute:  powershell -File scan-caches.ps1 -Report `"$Report`" -Execute" -ForegroundColor Cyan
} else {
    # Execute — move to recycle bin
    Write-Host "  Moving to Recycle Bin..." -ForegroundColor Magenta
    Write-Host ""
    $recycled = 0L
    $errors = 0
    foreach ($r in $staleResults) {
        Write-Host "  [RECYCLE] $($r.Name): $($r.Path)" -ForegroundColor Yellow
        if (SendToRecycleBin $r.Path) {
            $recycled += $r.ReportedSize
        } else {
            $errors++
        }
    }
    Write-Host ""
    Write-Host "  Recycled: $(Format-Bytes $recycled)" -ForegroundColor Green
    if ($errors -gt 0) { Write-Warning "  $errors failures — check output above." }
    Write-Host "  Items can be restored from the Recycle Bin." -ForegroundColor Green
}
