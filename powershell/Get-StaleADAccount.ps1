<#
.SYNOPSIS
    Report stale Active Directory user and computer accounts, and optionally disable
    them with a hard cap on how many one run may touch.

.DESCRIPTION
    An account is stale when it is enabled and its last logon is older than
    -InactiveDays. Accounts that never logged on count as stale once they are older
    than -NeverLoggedOnGraceDays, which catches provisioned-but-unused accounts
    without flagging this week's new starters.

    Last logon comes from lastLogonTimestamp, the replicated attribute. It lags real
    logons by up to ~14 days (ms-DS-Logon-Time-Sync-Interval), so thresholds under
    30 days are refused. For computers, pwdLastSet is used as a second signal: a
    domain member rotates its machine password every 30 days by default, so an
    account whose logon AND password are both old is genuinely gone.

    Skipped by default, because disabling them breaks things rather than tidying:
      - built-in accounts (Administrator, Guest, krbtgt, by RID)
      - accounts with a servicePrincipalName (service accounts), unless
        -IncludeServiceAccounts
      - managed service accounts (sMSA/gMSA)
      - members (recursive) of any -ExcludeGroup, and names matching -ExcludeName

    Report mode is the default and changes nothing. -Disable disables each stale
    account, stamps its description with the date and reason, and moves it to
    -TargetOU if given. It honours -WhatIf/-Confirm, and refuses to act at all when
    more than -MaxDisable accounts qualify: a sudden flood usually means a broken
    DC, a bad search base or a wrong threshold, not a real clean-up.

    Requires the ActiveDirectory module (RSAT). Reading needs only a domain user;
    -Disable needs rights on the target OUs.

    Exit codes: 0 no stale accounts, 1 stale accounts reported (or disabled),
    2 usage error, AD unreachable, -MaxDisable tripped or a disable failed.

.PARAMETER Type
    User, Computer or All. Default All.

.PARAMETER InactiveDays
    Days since last logon before an account is stale. Minimum 30, default 90.

.PARAMETER NeverLoggedOnGraceDays
    Age (days since creation) after which a never-used account is stale. Default 30.

.PARAMETER SearchBase
    Distinguished name to search under. Default is the whole domain.

.PARAMETER Server
    Domain controller or domain to query. Default lets the module choose.

.PARAMETER ExcludeGroup
    Groups whose members (recursive) are never reported, e.g. an exemption group.

.PARAMETER ExcludeName
    sAMAccountName wildcard patterns to skip, e.g. 'svc-*', 'breakglass*'.

.PARAMETER IncludeServiceAccounts
    Also report user accounts that carry a servicePrincipalName.

.PARAMETER Disable
    Disable the stale accounts found. Without it the script only reports. Prompts per
    account (ConfirmImpact High); pass -Confirm:$false for unattended runs.

.PARAMETER TargetOU
    With -Disable, move disabled accounts into this OU.

.PARAMETER MaxDisable
    Refuse to disable anything if more than this many accounts qualify. Default 25.

.PARAMETER CsvPath
    Also write the report to this CSV file.

.EXAMPLE
    .\Get-StaleADAccount.ps1 -InactiveDays 120 | Format-Table -AutoSize

.EXAMPLE
    .\Get-StaleADAccount.ps1 -Type Computer -SearchBase 'OU=Workstations,DC=corp,DC=example,DC=com' -CsvPath .\stale-computers.csv

.EXAMPLE
    # Review first, then disable and park them
    .\Get-StaleADAccount.ps1 -Type User -ExcludeGroup 'Stale-Sweep-Exempt' -ExcludeName 'breakglass*' -Disable -TargetOU 'OU=Disabled,DC=corp,DC=example,DC=com' -WhatIf

.NOTES
    Accounts are disabled, never deleted. Deletion belongs to a later, separate
    review once nobody has complained for a retention period.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidateSet('User', 'Computer', 'All')]
    [string]$Type = 'All',

    [ValidateRange(30, 3650)]
    [int]$InactiveDays = 90,

    [ValidateRange(1, 3650)]
    [int]$NeverLoggedOnGraceDays = 30,

    [string]$SearchBase,

    [string]$Server,

    [string[]]$ExcludeGroup = @(),

    [string[]]$ExcludeName = @(),

    [switch]$IncludeServiceAccounts,

    [switch]$Disable,

    [string]$TargetOU,

    [ValidateRange(1, 10000)]
    [int]$MaxDisable = 25,

    [string]$CsvPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($TargetOU -and -not $Disable) {
    Write-Error '-TargetOU only makes sense together with -Disable.' -ErrorAction Continue
    exit 2
}

try {
    Import-Module ActiveDirectory -ErrorAction Stop
} catch {
    Write-Error "ActiveDirectory module not available (install RSAT): $($_.Exception.Message)" -ErrorAction Continue
    exit 2
}

$adParams = @{}
if ($Server) { $adParams.Server = $Server }

$now          = Get-Date
$cutoff       = $now.AddDays(-$InactiveDays)
$graceCutoff  = $now.AddDays(-$NeverLoggedOnGraceDays)
# Built-in RIDs: 500 Administrator, 501 Guest, 502 krbtgt, 503 DefaultAccount.
$builtinRids  = '500', '501', '502', '503'

function ConvertFrom-FileTime([object]$Value) {
    if ($null -eq $Value -or [int64]$Value -le 0) { return $null }
    [DateTime]::FromFileTime([int64]$Value)
}

try {
    $domain = Get-ADDomain @adParams
    if (-not $SearchBase) { $SearchBase = $domain.DistinguishedName }
    if ($TargetOU) { $null = Get-ADOrganizationalUnit -Identity $TargetOU @adParams }
} catch {
    Write-Error "Cannot query Active Directory: $($_.Exception.Message)" -ErrorAction Continue
    exit 2
}

$exemptDns = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($group in $ExcludeGroup) {
    try {
        Get-ADGroupMember -Identity $group -Recursive @adParams |
            ForEach-Object { [void]$exemptDns.Add($_.distinguishedName) }
    } catch {
        # A misspelt exemption group must not silently widen the sweep.
        Write-Error "Exclude group '$group' could not be read: $($_.Exception.Message)" -ErrorAction Continue
        exit 2
    }
}

$properties = 'lastLogonTimestamp', 'whenCreated', 'pwdLastSet', 'description',
              'servicePrincipalName', 'objectClass', 'objectSid'

$candidates = New-Object System.Collections.Generic.List[object]
try {
    if ($Type -in 'User', 'All') {
        Get-ADUser -Filter 'Enabled -eq $true' -SearchBase $SearchBase -Properties $properties @adParams |
            ForEach-Object { $candidates.Add([pscustomobject]@{ Kind = 'User'; Ad = $_ }) }
    }
    if ($Type -in 'Computer', 'All') {
        Get-ADComputer -Filter 'Enabled -eq $true' -SearchBase $SearchBase -Properties ($properties + 'operatingSystem') @adParams |
            ForEach-Object { $candidates.Add([pscustomobject]@{ Kind = 'Computer'; Ad = $_ }) }
    }
} catch {
    Write-Error "AD search under '$SearchBase' failed: $($_.Exception.Message)" -ErrorAction Continue
    exit 2
}

$stale = foreach ($c in $candidates) {
    $a   = $c.Ad
    $sam = $a.SamAccountName

    if ($a.objectSid.Value.Split('-')[-1] -in $builtinRids) { continue }
    if ($exemptDns.Contains($a.DistinguishedName)) { continue }
    if ($ExcludeName | Where-Object { $sam -like $_ }) { continue }
    if ($a.objectClass -match 'ManagedServiceAccount') { continue }

    $hasSpn = @($a.servicePrincipalName).Count -gt 0
    if ($c.Kind -eq 'User' -and $hasSpn -and -not $IncludeServiceAccounts) { continue }

    $lastLogon = ConvertFrom-FileTime $a.lastLogonTimestamp
    $pwdSet    = ConvertFrom-FileTime $a.pwdLastSet

    $reason = $null
    if ($lastLogon) {
        if ($lastLogon -lt $cutoff) {
            # A computer that still rotates its password is alive, whatever the
            # logon timestamp says (e.g. it only talks to an RODC).
            if ($c.Kind -eq 'Computer' -and $pwdSet -and $pwdSet -ge $cutoff) { continue }
            $reason = "No logon for $([int]($now - $lastLogon).TotalDays) days"
        }
    } elseif ($a.whenCreated -lt $graceCutoff) {
        $reason = "Never logged on, created $([int]($now - $a.whenCreated).TotalDays) days ago"
    }
    if (-not $reason) { continue }

    [pscustomobject]@{
        Type            = $c.Kind
        SamAccountName  = $sam
        LastLogon       = $lastLogon
        PasswordLastSet = $pwdSet
        Created         = $a.whenCreated
        Reason          = $reason
        OperatingSystem = if ($c.Kind -eq 'Computer') { $a.operatingSystem } else { $null }
        HasSpn          = $hasSpn
        Description     = $a.description
        Action          = 'Reported'
        DistinguishedName = $a.DistinguishedName
    }
}
$stale = @($stale | Sort-Object Type, LastLogon)

Write-Verbose ("Scanned {0} enabled accounts under {1}; {2} stale (cutoff {3:yyyy-MM-dd})." -f
    $candidates.Count, $SearchBase, $stale.Count, $cutoff)

$exitCode = if ($stale.Count -gt 0) { 1 } else { 0 }

if ($Disable -and $stale.Count -gt 0) {
    if ($stale.Count -gt $MaxDisable) {
        Write-Error ("{0} accounts qualify, above -MaxDisable {1}. Nothing was disabled; check the search base and threshold, or raise -MaxDisable deliberately." -f
            $stale.Count, $MaxDisable) -ErrorAction Continue
        $exitCode = 2
    } else {
        $stamp = "Disabled {0:yyyy-MM-dd} by stale-account sweep" -f $now
        foreach ($s in $stale) {
            $target = "$($s.Type) $($s.SamAccountName) ($($s.Reason))"
            if (-not $PSCmdlet.ShouldProcess($target, 'Disable account')) {
                $s.Action = 'WhatIf'
                continue
            }
            try {
                Disable-ADAccount -Identity $s.DistinguishedName @adParams
                $desc = if ($s.Description) { "$stamp; was: $($s.Description)" } else { $stamp }
                if ($desc.Length -gt 1024) { $desc = $desc.Substring(0, 1024) }
                Set-ADObject -Identity $s.DistinguishedName -Replace @{ description = $desc } @adParams
                if ($TargetOU) {
                    Move-ADObject -Identity $s.DistinguishedName -TargetPath $TargetOU @adParams
                }
                $s.Action = 'Disabled'
            } catch {
                $s.Action = "Failed: $($_.Exception.Message)"
                $exitCode = 2
            }
        }
    }
}

if ($CsvPath) {
    $stale | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
}

$stale
exit $exitCode
