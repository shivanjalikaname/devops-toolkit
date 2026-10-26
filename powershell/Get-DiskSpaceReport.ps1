<#
.SYNOPSIS
    Report free disk space on one or more Windows servers and flag low volumes.

.DESCRIPTION
    Queries fixed disks via CIM (WinRM), so it works against remote servers without
    installing anything on them. Returns objects, so output can be piped to
    Export-Csv, ConvertTo-Html, or a monitoring webhook.

.PARAMETER ComputerName
    Servers to check. Defaults to the local machine.

.PARAMETER WarningPercent
    Free-space percentage at or below which a volume is marked Warning. Default 20.

.PARAMETER CriticalPercent
    Free-space percentage at or below which a volume is marked Critical. Default 10.

.EXAMPLE
    .\Get-DiskSpaceReport.ps1

.EXAMPLE
    .\Get-DiskSpaceReport.ps1 -ComputerName (Get-Content .\servers.txt) |
        Where-Object Status -ne 'OK' | Export-Csv low-disk.csv -NoTypeInformation

.NOTES
    Exits with code 2 if any volume is Critical, 1 if any is Warning, else 0,
    which makes it usable as a scheduled-task or CI health gate.
#>
[CmdletBinding()]
param(
    [string[]]$ComputerName = $env:COMPUTERNAME,
    [ValidateRange(1, 99)][int]$WarningPercent = 20,
    [ValidateRange(1, 99)][int]$CriticalPercent = 10
)

$results = foreach ($computer in $ComputerName) {
    $cimArgs = @{ ClassName = 'Win32_LogicalDisk'; Filter = 'DriveType = 3'; ErrorAction = 'Stop' }
    # Query the local machine directly; WinRM is often not enabled on workstations
    if ($computer -notin @($env:COMPUTERNAME, 'localhost', '.')) { $cimArgs.ComputerName = $computer }
    try {
        $disks = Get-CimInstance @cimArgs
    }
    catch {
        [pscustomobject]@{
            Computer = $computer; Drive = '-'; SizeGB = $null; FreeGB = $null
            FreePercent = $null; Status = 'Unreachable'
        }
        Write-Warning "${computer}: $($_.Exception.Message)"
        continue
    }

    foreach ($disk in $disks) {
        if (-not $disk.Size) { continue }
        $freePct = [math]::Round(($disk.FreeSpace / $disk.Size) * 100, 1)
        $status = if ($freePct -le $CriticalPercent) { 'Critical' }
                  elseif ($freePct -le $WarningPercent) { 'Warning' }
                  else { 'OK' }

        [pscustomobject]@{
            Computer    = $computer
            Drive       = $disk.DeviceID
            SizeGB      = [math]::Round($disk.Size / 1GB, 1)
            FreeGB      = [math]::Round($disk.FreeSpace / 1GB, 1)
            FreePercent = $freePct
            Status      = $status
        }
    }
}

$results | Sort-Object FreePercent | Format-Table -AutoSize | Out-Host
$results

if ($results.Status -contains 'Critical' -or $results.Status -contains 'Unreachable') { exit 2 }
elseif ($results.Status -contains 'Warning') { exit 1 }
exit 0
