<#
.SYNOPSIS
    Compress and expire IIS (and optionally HTTP.sys) logs before they fill the system drive.

.DESCRIPTION
    IIS never deletes its own logs. This finds the log directories configured in
    applicationHost.config (site defaults plus any per-site override), zips each log
    older than -CompressAfterDays into an _archive folder next to it, and deletes
    archives older than -DeleteAfterDays.

    Design choices worth knowing:
      - One zip per log file, not a monthly zip. Appending to a large zip in place
        loads it into memory, and a crash mid-write can take a month of logs with it.
      - The zip is written as .partial, re-opened and checked against the source size,
        then renamed. The original is only deleted after that check passes.
      - The zip keeps the source file's LastWriteTime, so retention follows the age
        of the log, not the date it was archived.
      - Files still open for writing by IIS are skipped and reported, never forced.

    Discovery reads the config file directly, so the WebAdministration module is not
    required. Pass -Path to clean arbitrary directories instead (or as well).

.PARAMETER Path
    Log root(s) to process. The root and its immediate subfolders (W3SVC1, FTPSVC2 ...)
    are scanned. When omitted, directories are discovered from IIS configuration.

.PARAMETER IncludeHttpErr
    Also process %windir%\System32\LogFiles\HTTPERR.

.PARAMETER CompressAfterDays
    Zip logs last written more than this many days ago. Default 7, minimum 1.

.PARAMETER DeleteAfterDays
    Delete archives (and any uncompressed log) older than this. Default 90. Must be
    greater than -CompressAfterDays. 0 keeps archives forever.

.PARAMETER ArchivePath
    Put archives under <ArchivePath>\<log folder name> instead of <log folder>\_archive,
    e.g. a data drive. Folder names must then be unique across the processed roots.

.PARAMETER Filter
    Log file pattern. Default *.log.

.PARAMETER WhatIf
    Dry run: report what would be compressed and deleted without touching anything.

.EXAMPLE
    .\Invoke-IISLogCleanup.ps1 -WhatIf

.EXAMPLE
    .\Invoke-IISLogCleanup.ps1 -CompressAfterDays 3 -DeleteAfterDays 180 -IncludeHttpErr

.EXAMPLE
    .\Invoke-IISLogCleanup.ps1 -Path D:\Logs\IIS -ArchivePath E:\LogArchive -Verbose

.EXAMPLE
    # Scheduled task action (daily, as SYSTEM)
    powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\ops\Invoke-IISLogCleanup.ps1 -IncludeHttpErr

.NOTES
    Output: one object per log directory with counts and bytes reclaimed.
    Exit codes:
      0  everything eligible was processed (or would be, under -WhatIf)
      1  some files were skipped (locked) or failed to compress/delete
      2  bad usage, no log directories found, or a -Path does not exist
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string[]]$Path,
    [switch]$IncludeHttpErr,
    [ValidateRange(1, 3650)][int]$CompressAfterDays = 7,
    [ValidateRange(0, 36500)][int]$DeleteAfterDays = 90,
    [string]$ArchivePath,
    [string]$Filter = '*.log'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($DeleteAfterDays -ne 0 -and $DeleteAfterDays -le $CompressAfterDays) {
    Write-Error "-DeleteAfterDays ($DeleteAfterDays) must be greater than -CompressAfterDays ($CompressAfterDays), or 0 to keep archives." -ErrorAction Continue
    exit 2
}

Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

function Get-IISLogRoot {
    $config = Join-Path $env:windir 'System32\inetsrv\config\applicationHost.config'
    if (-not (Test-Path -LiteralPath $config)) {
        Write-Verbose "IIS config not found at $config"
        return
    }
    [xml]$xml = Get-Content -LiteralPath $config -Raw
    $sites = $xml.configuration.'system.applicationHost'.sites

    $dirs = New-Object System.Collections.Generic.List[string]
    # IIS default when siteDefaults has no directory attribute.
    $default = '%SystemDrive%\inetpub\logs\LogFiles'
    $siteDefaults = $sites.SelectSingleNode('siteDefaults/logFile')
    if ($siteDefaults -and $siteDefaults.GetAttribute('directory')) {
        $default = $siteDefaults.GetAttribute('directory')
    }
    $dirs.Add($default)

    foreach ($node in $sites.SelectNodes('site/logFile[@directory]')) {
        $dirs.Add($node.GetAttribute('directory'))
    }
    # FTP sites log under ftpServer/logFile.
    foreach ($node in $sites.SelectNodes('site/ftpServer/logFile[@directory]')) {
        $dirs.Add($node.GetAttribute('directory'))
    }
    $dirs | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\') } | Sort-Object -Unique
}

function Test-FileLocked([string]$FullName) {
    # IIS holds the active log open for writing; asking for exclusive write access fails.
    try {
        $fs = [IO.File]::Open($FullName, 'Open', 'Read', 'Read')
        $fs.Dispose()
        return $false
    } catch [IO.IOException] {
        return $true
    }
}

function Compress-LogFile([IO.FileInfo]$File, [string]$Destination) {
    $partial = "$Destination.partial"
    if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }

    $zip = [IO.Compression.ZipFile]::Open($partial, 'Create')
    try {
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $zip, $File.FullName, $File.Name, [IO.Compression.CompressionLevel]::Optimal)
    } finally {
        $zip.Dispose()
    }

    $check = [IO.Compression.ZipFile]::OpenRead($partial)
    try {
        $entry = $check.GetEntry($File.Name)
        if (-not $entry -or $entry.Length -ne $File.Length) {
            throw "verification failed for $partial (entry size mismatch)"
        }
    } finally {
        $check.Dispose()
    }

    Move-Item -LiteralPath $partial -Destination $Destination -Force
    (Get-Item -LiteralPath $Destination).LastWriteTime = $File.LastWriteTime
}

# --- collect directories -----------------------------------------------------

$roots = New-Object System.Collections.Generic.List[string]
$missing = 0
if ($Path) {
    foreach ($p in $Path) {
        if (Test-Path -LiteralPath $p -PathType Container) {
            $roots.Add((Resolve-Path -LiteralPath $p).ProviderPath.TrimEnd('\'))
        } else {
            Write-Warning "Path not found: $p"
            $missing++
        }
    }
} else {
    foreach ($r in @(Get-IISLogRoot)) {
        if (-not $r) { continue }
        try {
            if (Test-Path -LiteralPath $r -PathType Container) { $roots.Add($r) }
            else { Write-Verbose "Configured log directory does not exist (yet): $r" }
        } catch [UnauthorizedAccessException] {
            # IIS log folders are admin-only by default.
            Write-Warning "Access denied to $r; run elevated or as SYSTEM."
            $missing++
        }
    }
}
if ($IncludeHttpErr) {
    $httpErr = Join-Path $env:windir 'System32\LogFiles\HTTPERR'
    if (Test-Path -LiteralPath $httpErr) { $roots.Add($httpErr) }
    else { Write-Warning "HTTPERR directory not found: $httpErr" }
}

if ($missing -gt 0) { exit 2 }

# The root itself plus one level of site folders; never descend into archives.
$logDirs = foreach ($root in ($roots | Sort-Object -Unique)) {
    $root
    Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne '_archive' } |
        ForEach-Object { $_.FullName }
}
$logDirs = @($logDirs | Sort-Object -Unique)

if ($logDirs.Count -eq 0) {
    Write-Error 'No log directories found. Is IIS installed? Use -Path to point at log folders.' -ErrorAction Continue
    exit 2
}

if ($ArchivePath) {
    $dupes = $logDirs | Group-Object { Split-Path $_ -Leaf } | Where-Object Count -gt 1
    if ($dupes) {
        Write-Error ("-ArchivePath needs unique folder names; duplicated: " + (($dupes | ForEach-Object Name) -join ', ')) -ErrorAction Continue
        exit 2
    }
}

# --- process -----------------------------------------------------------------

$now = Get-Date
$compressCutoff = $now.AddDays(-$CompressAfterDays)
$deleteCutoff = if ($DeleteAfterDays -gt 0) { $now.AddDays(-$DeleteAfterDays) } else { $null }
$problems = 0

foreach ($dir in $logDirs) {
    $archiveDir = if ($ArchivePath) { Join-Path $ArchivePath (Split-Path $dir -Leaf) } else { Join-Path $dir '_archive' }
    $stat = [ordered]@{
        Directory       = $dir
        ArchiveDir      = $archiveDir
        Compressed      = 0
        DeletedLogs     = 0
        DeletedArchives = 0
        Skipped         = 0
        Failed          = 0
        BytesReclaimed  = [long]0
    }

    $logs = @(Get-ChildItem -LiteralPath $dir -Filter $Filter -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $compressCutoff })

    foreach ($log in $logs) {
        # Already past retention: archiving it just to delete it later is wasted I/O.
        if ($deleteCutoff -and $log.LastWriteTime -lt $deleteCutoff) {
            if ($PSCmdlet.ShouldProcess($log.FullName, 'Delete expired log')) {
                try {
                    Remove-Item -LiteralPath $log.FullName -Force
                } catch {
                    Write-Warning "Delete failed: $($log.FullName): $($_.Exception.Message)"
                    $stat.Failed++; continue
                }
            }
            $stat.DeletedLogs++
            $stat.BytesReclaimed += $log.Length
            continue
        }

        if (Test-FileLocked $log.FullName) {
            Write-Verbose "Locked, skipping: $($log.FullName)"
            $stat.Skipped++
            continue
        }

        $dest = Join-Path $archiveDir ([IO.Path]::ChangeExtension($log.Name, '.zip'))
        if ($PSCmdlet.ShouldProcess($log.FullName, "Compress to $dest")) {
            try {
                if (-not (Test-Path -LiteralPath $archiveDir)) {
                    New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null
                }
                Compress-LogFile -File $log -Destination $dest
                $zipSize = (Get-Item -LiteralPath $dest).Length
                Remove-Item -LiteralPath $log.FullName -Force
                $stat.BytesReclaimed += ($log.Length - $zipSize)
            } catch {
                Write-Warning "Compress failed: $($log.FullName): $($_.Exception.Message)"
                $stat.Failed++; continue
            }
        } else {
            # Dry run has no zip to measure; logs typically compress ~90%.
            $stat.BytesReclaimed += [long]($log.Length * 0.9)
        }
        $stat.Compressed++
    }

    if ($deleteCutoff -and (Test-Path -LiteralPath $archiveDir)) {
        $expired = Get-ChildItem -LiteralPath $archiveDir -Filter '*.zip' -File |
            Where-Object { $_.LastWriteTime -lt $deleteCutoff }
        foreach ($zip in $expired) {
            if ($PSCmdlet.ShouldProcess($zip.FullName, 'Delete expired archive')) {
                try {
                    Remove-Item -LiteralPath $zip.FullName -Force
                } catch {
                    Write-Warning "Delete failed: $($zip.FullName): $($_.Exception.Message)"
                    $stat.Failed++; continue
                }
            }
            $stat.DeletedArchives++
            $stat.BytesReclaimed += $zip.Length
        }
    }

    $problems += $stat.Skipped + $stat.Failed
    if ($logs.Count -gt 0 -or $stat.DeletedArchives -gt 0 -or $VerbosePreference -ne 'SilentlyContinue') {
        [pscustomobject]$stat
    }
}

$mode = if ($WhatIfPreference) { ' (dry run, estimated)' } else { '' }
Write-Verbose ("Done{0}. Directories scanned: {1}. Problems: {2}." -f $mode, $logDirs.Count, $problems)

if ($problems -gt 0) { exit 1 }
exit 0
