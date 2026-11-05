<#
.SYNOPSIS
    Restart stopped Windows services, with a circuit breaker so a crash-looping
    service doesn't get restarted forever.

.DESCRIPTION
    Meant to run from Task Scheduler every few minutes as SYSTEM or a service admin.
    Each stopped service gets a restart, then a short stability check, because plenty
    of broken services reach Running and die a second later.

    Restart attempts are recorded in a state file. Once a service has used up
    -MaxRestarts within -WindowMinutes the watchdog leaves it alone and reports it as
    Critical, so the crash dump, event log and logs survive for whoever picks it up.
    Restarts resume by themselves when old attempts age out of the window; delete the
    service's entry from the state file to retry sooner.

    Left alone on purpose: Disabled services (someone disabled them) and Paused
    services. Both report Warning. Services stuck in a pending state report Critical;
    killing the process is a human decision.

.PARAMETER Name
    Service names to watch; wildcards allowed. A name or pattern matching nothing is
    Critical, so a typo can't silently watch nothing.

.PARAMETER Exclude
    Service names to skip; wildcards allowed.

.PARAMETER MaxRestarts
    Restart attempts allowed per service within the window. Default 3.

.PARAMETER WindowMinutes
    Length of the circuit breaker window. Default 60.

.PARAMETER StartTimeoutSeconds
    How long to wait for a service to leave a pending state. Default 60.

.PARAMETER StabilizeSeconds
    How long a restarted service must stay Running to count as recovered. Default 5.

.PARAMETER StateFile
    Where attempts are recorded. Default %ProgramData%\ServiceWatchdog\state.json.

.PARAMETER WebhookUrl
    Slack or Teams style incoming webhook, sent {"text": "..."}. One message per run,
    only when something needs attention.

.PARAMETER WhatIf
    Dry run: report what would be restarted. Starts nothing, writes no state and sends
    no webhook.

.EXAMPLE
    .\Invoke-ServiceWatchdog.ps1 -Name Spooler, W3SVC -WhatIf

.EXAMPLE
    .\Invoke-ServiceWatchdog.ps1 -Name 'Contoso*' -Exclude 'ContosoUpdater' -MaxRestarts 5 -WindowMinutes 30

.EXAMPLE
    # Scheduled task action
    powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\ops\Invoke-ServiceWatchdog.ps1 -Name W3SVC,WAS -WebhookUrl https://hooks.example.com/services/PLACEHOLDER

.NOTES
    Exit codes:
      0  all watched services running
      1  warning: a service was restarted and recovered (or would be, under -WhatIf),
         is disabled or paused, or state could not be saved
      2  critical: restart failed, breaker open, stuck pending, service not found,
         or bad usage
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string[]]$Name,
    [string[]]$Exclude = @(),
    [ValidateRange(1, 100)][int]$MaxRestarts = 3,
    [ValidateRange(1, 10080)][int]$WindowMinutes = 60,
    [ValidateRange(1, 3600)][int]$StartTimeoutSeconds = 60,
    [ValidateRange(0, 600)][int]$StabilizeSeconds = 5,
    [string]$StateFile = (Join-Path $env:ProgramData 'ServiceWatchdog\state.json'),
    [ValidatePattern('^https://')][string]$WebhookUrl
)

$ErrorActionPreference = 'Stop'

# powershell.exe -File hands "W3SVC,WAS" over as one string, and that's how scheduled tasks call us.
$Name = @($Name | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$Exclude = @($Exclude | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($Name.Count -eq 0) {
    Write-Host 'Usage: Invoke-ServiceWatchdog.ps1 -Name <service>[,<service>...] [-WhatIf]. See Get-Help for details.'
    exit 2
}

function Read-WatchdogState {
    param([string]$Path, [datetime]$Cutoff)

    $state = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $state }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($entry in $raw.PSObject.Properties) {
            $attempts = @(@($entry.Value.attempts) | Where-Object { $_ } |
                ForEach-Object { ([datetime]$_).ToUniversalTime() } |
                Where-Object { $_ -gt $Cutoff })
            $state[$entry.Name] = @{ attempts = $attempts; notified = [bool]$entry.Value.notified }
        }
    }
    catch {
        # Losing history only resets the breaker; not worth refusing to watch services over.
        Write-Warning "Ignoring unreadable state file ${Path}: $($_.Exception.Message)"
        return @{}
    }
    return $state
}

function Save-WatchdogState {
    param([hashtable]$State, [string]$Path)

    $out = @{}
    foreach ($key in $State.Keys) {
        $item = $State[$key]
        if ($item.attempts.Count -eq 0 -and -not $item.notified) { continue }
        $out[$key] = @{
            attempts = @($item.attempts | ForEach-Object { $_.ToString('o') })
            notified = $item.notified
        }
    }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    # Write then rename, so a run killed mid-write can't leave half a file behind.
    $tmp = "$Path.tmp"
    [IO.File]::WriteAllText($tmp, ($out | ConvertTo-Json -Depth 4))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Wait-ServiceSettled {
    param($Service, [int]$TimeoutSeconds)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $Service.Refresh()
    while ("$($Service.Status)" -like '*Pending' -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $Service.Refresh()
    }
}

function New-Result {
    param([string]$Name, [string]$Status, [string]$StartType, [string]$Action, [string]$Severity, [string]$Detail)

    [pscustomobject]@{
        Name = $Name; Status = $Status; StartType = $StartType
        Action = $Action; Severity = $Severity; Detail = $Detail
    }
}

function Send-WatchdogAlert {
    param([string]$Url, [string[]]$Lines)

    $text = "Service watchdog on $env:COMPUTERNAME`n" + ($Lines -join "`n")
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-RestMethod -Method Post -Uri $Url -ContentType 'application/json' -TimeoutSec 15 `
            -Body (@{ text = $text } | ConvertTo-Json) | Out-Null
    }
    catch {
        Write-Warning "Webhook failed: $($_.Exception.Message)"
    }
}

$cutoff = [datetime]::UtcNow.AddMinutes(-$WindowMinutes)
$state = Read-WatchdogState -Path $StateFile -Cutoff $cutoff

$results = New-Object System.Collections.Generic.List[object]
$alerts = New-Object System.Collections.Generic.List[string]
$seen = @{}

foreach ($pattern in $Name) {
    $matched = @(Get-Service -Name $pattern -ErrorAction SilentlyContinue)
    if ($matched.Count -eq 0) {
        $results.Add((New-Result $pattern 'Missing' '-' 'None' 'Critical' 'No service matches this name'))
        $alerts.Add("CRITICAL ${pattern}: no service matches this name")
        continue
    }

    foreach ($svc in $matched) {
        $svcName = $svc.Name
        if ($seen.ContainsKey($svcName)) { continue }
        $seen[$svcName] = $true
        if ($Exclude | Where-Object { $svcName -like $_ }) { continue }

        if (-not $state.ContainsKey($svcName)) { $state[$svcName] = @{ attempts = @(); notified = $false } }
        $entry = $state[$svcName]

        # Don't react to a restart somebody else is in the middle of.
        Wait-ServiceSettled -Service $svc -TimeoutSeconds $StartTimeoutSeconds
        $status = "$($svc.Status)"
        $startType = "$($svc.StartType)"

        if ($status -eq 'Running') {
            $entry.notified = $false
            $results.Add((New-Result $svcName $status $startType 'None' 'OK' ''))
            continue
        }
        if ($status -like '*Pending') {
            $detail = "Stuck in $status after ${StartTimeoutSeconds}s"
            $results.Add((New-Result $svcName $status $startType 'None' 'Critical' $detail))
            $alerts.Add("CRITICAL ${svcName}: $detail")
            continue
        }
        if ($status -eq 'Paused') {
            $results.Add((New-Result $svcName $status $startType 'None' 'Warning' 'Paused, not touching it'))
            continue
        }
        if ($startType -eq 'Disabled') {
            $results.Add((New-Result $svcName $status $startType 'None' 'Warning' 'Disabled, not restarting'))
            continue
        }

        if ($entry.attempts.Count -ge $MaxRestarts) {
            $detail = "Breaker open: $($entry.attempts.Count) restarts in the last ${WindowMinutes}m"
            $results.Add((New-Result $svcName $status $startType 'None' 'Critical' $detail))
            # Paged once per outage; the exit code keeps reporting it on every run.
            if (-not $entry.notified) {
                $alerts.Add("CRITICAL ${svcName}: $detail, needs a human")
                $entry.notified = $true
            }
            continue
        }

        if (-not $PSCmdlet.ShouldProcess($svcName, 'Start service')) {
            $results.Add((New-Result $svcName $status $startType 'WouldRestart' 'Warning' 'Dry run'))
            continue
        }

        # Counted before starting: a start that hangs or throws has still used an attempt.
        $entry.attempts = @($entry.attempts) + [datetime]::UtcNow
        $attemptNote = "attempt $($entry.attempts.Count)/$MaxRestarts"
        try {
            # ServiceController instead of Start-Service, which can wait forever on a hung start.
            $svc.Start()
            Wait-ServiceSettled -Service $svc -TimeoutSeconds $StartTimeoutSeconds
            if ("$($svc.Status)" -eq 'Running' -and $StabilizeSeconds -gt 0) {
                Start-Sleep -Seconds $StabilizeSeconds
                $svc.Refresh()
            }
            $after = "$($svc.Status)"
            if ($after -eq 'Running') {
                $detail = "Restarted and stable for ${StabilizeSeconds}s ($attemptNote)"
                $results.Add((New-Result $svcName $after $startType 'Restarted' 'Warning' $detail))
                $alerts.Add("WARNING ${svcName}: $detail")
            }
            else {
                $detail = "Status is $after after restart ($attemptNote)"
                $results.Add((New-Result $svcName $after $startType 'RestartFailed' 'Critical' $detail))
                $alerts.Add("CRITICAL ${svcName}: $detail")
            }
        }
        catch {
            $reason = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
            $detail = "Start failed: $reason ($attemptNote)"
            $results.Add((New-Result $svcName $status $startType 'RestartFailed' 'Critical' $detail))
            $alerts.Add("CRITICAL ${svcName}: $detail")
        }
    }
}

$stateSaveFailed = $false
if (-not $WhatIfPreference) {
    try {
        Save-WatchdogState -State $state -Path $StateFile
    }
    catch {
        # Without saved attempts the breaker can't count, so this has to show in the exit code.
        Write-Warning "Could not save state to ${StateFile}: $($_.Exception.Message)"
        $stateSaveFailed = $true
    }
    if ($WebhookUrl -and $alerts.Count -gt 0) {
        Send-WatchdogAlert -Url $WebhookUrl -Lines $alerts.ToArray()
    }
}

$results.ToArray()

$severities = @($results | ForEach-Object { $_.Severity })
if ($severities -contains 'Critical') { exit 2 }
if ($severities -contains 'Warning' -or $stateSaveFailed) { exit 1 }
exit 0
