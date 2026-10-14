#requires -Version 7.2
Set-StrictMode -Version Latest

# Expansion of an existing V2 deployment is a change to its saved configuration; the deploy stage applies it.
# Nothing here writes to Azure or Entra. The only online call is a delegated, read-only Graph user lookup.

$script:MaximumHosts = 100
Import-Module (Join-Path $PSScriptRoot 'AvdSizing.psm1')

function Get-AvdHostPoolType {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Configuration)
    if ($Configuration.Contains('hostPool')) { return $Configuration.hostPool.type }
    return 'Pooled'
}

function Assert-AvdHostNames {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Configuration, [Parameter(Mandatory)][int]$Count)
    if ($Count -gt $script:MaximumHosts) {
        throw "Expanding to $Count session hosts exceeds the V2 maximum of $script:MaximumHosts per pool."
    }
    $lastName = "$($Configuration.sessionHosts.namePrefix)-$($Count - 1)"
    if ($lastName.Length -gt 15) {
        throw "Expanding to $Count hosts produces computer name '$lastName', which is longer than 15 characters."
    }
}

function Add-AvdPooledCapacity {
    [CmdletBinding(DefaultParameterSetName = 'Hosts')]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Configuration,
        [Parameter(Mandatory, ParameterSetName = 'Hosts')]
        [ValidateRange(1, 100)]
        [int]$AddHosts,
        [Parameter(Mandatory, ParameterSetName = 'Users')]
        [ValidateRange(1, 5000)]
        [int]$Users,
        [Parameter(ParameterSetName = 'Users')]
        [ValidateRange(1, 100)]
        [int]$PeakConcurrencyPct
    )

    $hostPoolType = Get-AvdHostPoolType -Configuration $Configuration
    $isDirectPersonal = $hostPoolType -eq 'Personal' -and $Configuration.hostPool.assignmentType -eq 'Direct'
    if ($isDirectPersonal) {
        throw 'This is a dedicated pool with direct assignment. Use -Mode AddUser to add a host for a named user.'
    }

    $current = [int]$Configuration.sessionHosts.count
    $messages = [System.Collections.Generic.List[string]]::new()
    if ($PSCmdlet.ParameterSetName -eq 'Hosts') {
        $target = $current + $AddHosts
    } else {
        if (-not $Configuration.Contains('workload')) {
            throw 'Re-sizing by user count needs a workload section (schema 1.2.0 or later). Use -AddHosts instead.'
        }
        $workload = $Configuration.workload
        $peak = if ($PeakConcurrencyPct -gt 0) { $PeakConcurrencyPct } else { [int]$workload.peakConcurrencyPct }
        $recommendation = Get-AvdSizingRecommendation -Hosting $workload.hosting -Persona $workload.persona -Users $Users -PeakConcurrencyPct $peak
        foreach ($line in $recommendation.explanation) { $messages.Add($line) }
        $workload.users = $Users
        $workload.peakConcurrencyPct = $peak
        $target = [int]$recommendation.sessionHosts.count
        if ($target -le $current) {
            $messages.Add("Current $current host(s) already cover $Users users; no hosts added. Reductions are not applied because V2 never drains or deletes hosts.")
            return [pscustomobject]@{ Configuration = $Configuration; Added = 0; Messages = $messages }
        }
    }

    Assert-AvdHostNames -Configuration $Configuration -Count $target
    $Configuration.sessionHosts.count = $target
    $newNames = ($current..($target - 1) | ForEach-Object { "$($Configuration.sessionHosts.namePrefix)-$_" }) -join ', '
    $messages.Add("Adding $($target - $current) host(s): $newNames. Existing hosts, VM size and sessions per host are unchanged.")
    return [pscustomobject]@{ Configuration = $Configuration; Added = $target - $current; Messages = $messages }
}

function Resolve-AvdEntraUser {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$UserPrincipalName,
        [Parameter(Mandatory)]
        [string]$TenantId
    )

    $contextCommand = Get-Command Get-MgContext -ErrorAction SilentlyContinue
    $requestCommand = Get-Command Invoke-MgGraphRequest -ErrorAction SilentlyContinue
    if (-not $contextCommand -or -not $requestCommand) {
        throw "Looking up '$UserPrincipalName' needs the Microsoft.Graph.Authentication module. Install it and run Connect-MgGraph -TenantId $TenantId -Scopes User.ReadBasic.All, or pass -UserObjectId."
    }
    $context = Get-MgContext
    if (-not $context -and (Get-Command Connect-MgGraph -ErrorAction SilentlyContinue)) {
        Write-Host "Signing in to Microsoft Graph for tenant $TenantId (delegated User.ReadBasic.All, read-only)..."
        Connect-MgGraph -TenantId $TenantId -Scopes 'User.ReadBasic.All' -NoWelcome | Out-Null
        $context = Get-MgContext
    }
    if (-not $context) {
        throw "Not signed in to Microsoft Graph. Run Connect-MgGraph -TenantId $TenantId -Scopes User.ReadBasic.All, or pass -UserObjectId."
    }
    if ($context.TenantId -ne $TenantId) {
        throw "The Microsoft Graph sign-in is for tenant $($context.TenantId), but this configuration targets tenant $TenantId. Sign in to the configured tenant."
    }

    $encoded = [System.Uri]::EscapeDataString($UserPrincipalName)
    try {
        $user = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/users/$encoded`?`$select=id,userPrincipalName,displayName" -OutputType Hashtable
    } catch {
        throw "User '$UserPrincipalName' was not found in tenant $TenantId, or the signed-in account cannot read it."
    }
    if (-not $user -or -not $user.id) {
        throw "User '$UserPrincipalName' was not found in tenant $TenantId."
    }
    return [pscustomobject]@{
        ObjectId          = [string]$user.id
        UserPrincipalName = [string]$user.userPrincipalName
        DisplayName       = [string]$user.displayName
    }
}

function Add-AvdUserAssignment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Configuration,
        [Parameter(Mandatory)]
        [string]$UserPrincipalName,
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$')]
        [string]$ObjectId
    )

    if ((Get-AvdHostPoolType -Configuration $Configuration) -ne 'Personal' -or $Configuration.hostPool.assignmentType -ne 'Direct') {
        throw 'AddUser needs a dedicated (personal) host pool with direct assignment. Shared pools grant access through the AVD users group; use -Mode Expand to add capacity.'
    }

    $assignments = [System.Collections.Generic.List[object]]::new()
    if ($Configuration.Contains('assignments')) {
        foreach ($existing in $Configuration.assignments) { $assignments.Add($existing) }
    }
    foreach ($existing in $assignments) {
        if ($existing.userPrincipalName -ieq $UserPrincipalName -or $existing.objectId -ieq $ObjectId) {
            throw "User '$UserPrincipalName' is already assigned to $($Configuration.sessionHosts.namePrefix)-$($existing.hostIndex)."
        }
    }

    $count = [int]$Configuration.sessionHosts.count
    $usedIndexes = @($assignments | ForEach-Object { [int]$_.hostIndex })
    $hostIndex = 0..($count - 1) | Where-Object { $_ -notin $usedIndexes } | Select-Object -First 1
    $addedHost = $false
    if ($null -eq $hostIndex) {
        $hostIndex = $count
        Assert-AvdHostNames -Configuration $Configuration -Count ($count + 1)
        $Configuration.sessionHosts.count = $count + 1
        $addedHost = $true
        if ($Configuration.Contains('workload')) {
            $Configuration.workload.users = [Math]::Max([int]$Configuration.workload.users, $count + 1)
        }
    }

    $assignments.Add([ordered]@{ userPrincipalName = $UserPrincipalName; objectId = $ObjectId.ToLowerInvariant(); hostIndex = [int]$hostIndex })
    $Configuration.assignments = @($assignments | Sort-Object { [int]$_.hostIndex })
    $Configuration.schemaVersion = '1.3.0'

    $hostName = "$($Configuration.sessionHosts.namePrefix)-$hostIndex"
    $action = if ($addedHost) { "new host $hostName" } else { "unassigned host $hostName" }
    return [pscustomobject]@{
        Configuration = $Configuration
        HostName      = $hostName
        AddedHost     = $addedHost
        Message       = "Assigned $UserPrincipalName ($ObjectId) to $action. Deploy will set the host's assigned user and add the user to the AVD users group using your delegated permission."
    }
}

Export-ModuleMember -Function Add-AvdPooledCapacity, Resolve-AvdEntraUser, Add-AvdUserAssignment
