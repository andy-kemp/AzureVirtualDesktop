#requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$v2Root = Split-Path $PSScriptRoot -Parent
$cliPath = Join-Path $v2Root 'avd.ps1'
$examplePath = Join-Path $v2Root 'config/avd.example.json'
$configuration = Get-Content -LiteralPath $examplePath -Raw | ConvertFrom-Json -AsHashtable
$temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
[System.IO.Directory]::CreateDirectory($temporaryDirectory) | Out-Null
$script:passed = 0

Import-Module (Join-Path $v2Root 'lib/AvdSizing.psm1') -Force

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}

function Write-Pass {
    param([string]$Message)
    $script:passed++
    Write-Host "PASS: $Message"
}

function Copy-Configuration {
    param([System.Collections.IDictionary]$Source = $configuration)
    return ($Source | ConvertTo-Json -Depth 32 | ConvertFrom-Json -AsHashtable -Depth 32)
}

function Save-Configuration {
    param([System.Collections.IDictionary]$Value, [string]$Name)
    $path = Join-Path $temporaryDirectory "$Name.json"
    [System.IO.File]::WriteAllText($path, ($Value | ConvertTo-Json -Depth 32))
    return $path
}

function Invoke-InvalidConfigurationCase {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Value,
        [Parameter(Mandatory)]
        [string]$Name,
        [string]$Expected = 'does not satisfy'
    )

    $path = Save-Configuration -Value $Value -Name $Name
    $caughtError = $null
    try {
        $null = & $cliPath -Mode Validate -ConfigurationFile $path 2>&1
    } catch {
        $caughtError = $_.Exception.Message
    }
    Assert-True ($caughtError -match $Expected) "$Name was not rejected by the V2 CLI with '$Expected'. Actual: $caughtError"
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Expected, [string]$Name)
    $caughtError = $null
    try {
        & $Action
    } catch {
        $caughtError = $_.Exception.Message
    }
    Assert-True ($caughtError -match $Expected) "$Name did not fail with '$Expected'. Actual: $caughtError"
}

try {
    # Contract and existing behaviour
    $validOutput = & $cliPath -Mode Validate -ConfigurationFile $examplePath
    $validText = $validOutput -join "`n"
    Assert-True ($validText -match 'Configuration valid') 'Valid example configuration was not accepted.'
    Assert-True ($validText -match 'Sizing: 40 Standard user\(s\), shared at 80% peak - matches recommendation') 'Example sizing was not reported as matching.'
    Assert-True ($validText -match 'Scaling plan: enabled, 2 schedule') 'Example scaling plan was not reported.'
    Write-Pass 'versioned example validates offline and reports sizing and scaling.'

    $plaintextSecret = Copy-Configuration
    $plaintextSecret.sessionHosts.adminPassword = 'must-not-be-stored'
    Invoke-InvalidConfigurationCase -Value $plaintextSecret -Name 'plaintext-secret'
    Write-Pass 'plaintext secrets are rejected.'

    $invalidHostCount = Copy-Configuration
    $invalidHostCount.sessionHosts.count = 0
    Invoke-InvalidConfigurationCase -Value $invalidHostCount -Name 'invalid-host-count'
    Write-Pass 'invalid host count is rejected.'

    $sameGroups = Copy-Configuration
    $sameGroups.accessGroups.adminsObjectId = $sameGroups.accessGroups.usersObjectId
    Invoke-InvalidConfigurationCase -Value $sameGroups -Name 'duplicate-groups' -Expected 'must have different'
    Write-Pass 'duplicate access groups are rejected.'

    $wrongIdentitySubscription = Copy-Configuration
    $wrongIdentitySubscription.execution.deploymentIdentityResourceId = $wrongIdentitySubscription.execution.deploymentIdentityResourceId.Replace(
        $wrongIdentitySubscription.subscriptionId,
        '88888888-8888-4888-8888-888888888888'
    )
    Invoke-InvalidConfigurationCase -Value $wrongIdentitySubscription -Name 'wrong-identity-subscription' -Expected 'deployment UAMI must be in the configured customer subscription'
    Write-Pass 'deployment UAMI is bound to the configured subscription.'

    $legacy = Copy-Configuration
    'scaling', 'workload', 'hostPool' | ForEach-Object { $legacy.Remove($_) }
    $legacy.schemaVersion = '1.0.0'
    $legacyText = (& $cliPath -Mode Validate -ConfigurationFile (Save-Configuration -Value $legacy -Name 'legacy-1.0.0')) -join "`n"
    Assert-True ($legacyText -match 'Scaling plan: not configured') 'A 1.0.0 configuration without scaling was not accepted.'
    Assert-True ($legacyText -match 'legacy default: max 5 sessions') 'A 1.0.0 configuration did not keep the legacy pooled host-pool default.'
    Write-Pass '1.0.0 configurations remain valid with the legacy pooled default.'

    # Scaling
    $scalingOnOldVersion = Copy-Configuration
    'workload', 'hostPool' | ForEach-Object { $scalingOnOldVersion.Remove($_) }
    $scalingOnOldVersion.schemaVersion = '1.0.0'
    Invoke-InvalidConfigurationCase -Value $scalingOnOldVersion -Name 'scaling-on-1.0.0'
    Write-Pass 'scaling requires schema version 1.1.0 or later.'

    $invalidTimeFormat = Copy-Configuration
    $invalidTimeFormat.scaling.schedules[0].peak.startTime = '9am'
    Invoke-InvalidConfigurationCase -Value $invalidTimeFormat -Name 'invalid-time-format' -Expected 'peak.startTime'
    Write-Pass 'invalid scaling time format is rejected.'

    $outOfOrder = Copy-Configuration
    $outOfOrder.scaling.schedules[0].rampDown.startTime = '08:00'
    Invoke-InvalidConfigurationCase -Value $outOfOrder -Name 'out-of-order-phases' -Expected 'must start in order'
    Write-Pass 'out-of-order scaling phases are rejected.'

    $overlappingDays = Copy-Configuration
    $overlappingDays.scaling.schedules[1].daysOfWeek = @('Friday', 'Saturday')
    Invoke-InvalidConfigurationCase -Value $overlappingDays -Name 'overlapping-days' -Expected 'overlap on Friday'
    Write-Pass 'overlapping scaling schedule days are rejected.'

    $unknownTimeZone = Copy-Configuration
    $unknownTimeZone.scaling.timeZone = 'Not A Real Zone'
    Invoke-InvalidConfigurationCase -Value $unknownTimeZone -Name 'unknown-time-zone' -Expected 'time zone'
    Write-Pass 'unknown scaling time zone is rejected.'

    $badThreshold = Copy-Configuration
    $badThreshold.scaling.schedules[0].rampUp.capacityThresholdPct = 0
    Invoke-InvalidConfigurationCase -Value $badThreshold -Name 'invalid-capacity-threshold' -Expected 'capacityThresholdPct'
    Write-Pass 'out-of-range scaling capacity threshold is rejected.'

    # Persona sizing rules
    $standard = Get-AvdSizingRecommendation -Hosting Shared -Persona Standard -Users 100 -PeakConcurrencyPct 80
    Assert-True ($standard.sessionHosts.count -eq 4 -and $standard.sessionHosts.vmSize -eq 'Standard_D8s_v5' -and $standard.hostPool.maxSessionLimit -eq 32 -and $standard.hostPool.type -eq 'Pooled') 'Shared Standard 100 users @80% should be 4 x D8s_v5 at 32 sessions.'
    $frontline = Get-AvdSizingRecommendation -Hosting Shared -Persona Frontline -Users 200
    Assert-True ($frontline.sessionHosts.count -eq 6 -and $frontline.hostPool.maxSessionLimit -eq 48) 'Shared Frontline 200 users should be 6 hosts at 48 sessions.'
    $heavy = Get-AvdSizingRecommendation -Hosting Shared -Persona Heavy -Users 10
    Assert-True ($heavy.sessionHosts.count -eq 2 -and $heavy.hostPool.maxSessionLimit -eq 16) 'Shared Heavy 10 users should be 2 hosts at 16 sessions.'
    Write-Pass 'shared sizing follows Microsoft users-per-vCPU guidance plus one spare host.'

    $dedicated = Get-AvdSizingRecommendation -Hosting Dedicated -Persona Standard -Users 10 -PeakConcurrencyPct 50
    Assert-True ($dedicated.sessionHosts.count -eq 10 -and $dedicated.sessionHosts.vmSize -eq 'Standard_D4s_v5' -and $dedicated.hostPool.type -eq 'Personal' -and -not $dedicated.hostPool.Contains('maxSessionLimit')) 'Dedicated Standard 10 users should be 10 personal D4s_v5 hosts regardless of concurrency.'
    Write-Pass 'dedicated sizing is one persona-sized personal VM per user.'

    Assert-Throws -Name 'dedicated-over-limit' -Expected 'exceeds the V2 maximum' -Action { Get-AvdSizingRecommendation -Hosting Dedicated -Persona Frontline -Users 101 }
    Assert-Throws -Name 'shared-over-limit' -Expected 'exceeds the V2 maximum' -Action { Get-AvdSizingRecommendation -Hosting Shared -Persona Heavy -Users 5000 }
    Write-Pass 'sizing beyond the 100-host pool limit is rejected.'

    # Shared-pool scaling behaviour, checked against Microsoft's formula: hosts = ceil(sessions / (limit x threshold%)).
    foreach ($sessionLimit in 48, 32, 16) {
        $threshold = Get-AvdSpareHostThreshold -MaxSessionLimit $sessionLimit
        for ($sessions = 1; $sessions -le 24; $sessions++) {
            $requiredHosts = [Math]::Ceiling($sessions / ($sessionLimit * $threshold / 100.0))
            Assert-True ($requiredHosts -eq $sessions + 1) "With $sessionLimit sessions/host and a $threshold% threshold, $sessions session(s) should need $($sessions + 1) hosts, not $requiredHosts."
        }
    }
    Write-Pass 'business-hours threshold keeps one empty host ready (sessions + 1) for every persona.'

    $exampleSummary = $validText
    Assert-True ($exampleSummary -match "weekdays': working hours BreadthFirst; a new host starts whenever every running host has a user") 'Example weekday schedule should use the spare-host rule.'
    Assert-True ($exampleSummary -match 'never shut down' -and $exampleSummary -notmatch 'Warning: schedule') 'Example should never shut down hosts with sessions and should keep one host on.'
    $zeroMinimum = Copy-Configuration
    $zeroMinimum.scaling.schedules[0].rampDown.minimumHostsPct = 0
    $zeroText = (& $cliPath -Mode Validate -ConfigurationFile (Save-Configuration -Value $zeroMinimum -Name 'zero-minimum')) -join "`n"
    Assert-True ($zeroText -match "Warning: schedule 'weekdays' can stop every host") 'A schedule that can stop every host should be warned about.'
    Write-Pass 'summary explains scaling behaviour and warns when no host stays on.'

    # Host pool contract rules
    $workloadOnOldVersion = Copy-Configuration
    $workloadOnOldVersion.schemaVersion = '1.1.0'
    Invoke-InvalidConfigurationCase -Value $workloadOnOldVersion -Name 'workload-on-1.1.0'
    Write-Pass 'workload and hostPool require schema version 1.2.0.'

    $workloadWithoutPool = Copy-Configuration
    $workloadWithoutPool.Remove('hostPool')
    Invoke-InvalidConfigurationCase -Value $workloadWithoutPool -Name 'workload-without-host-pool'
    Write-Pass 'workload requires an explicit hostPool.'

    $hostingMismatch = Copy-Configuration
    $hostingMismatch.workload.hosting = 'Dedicated'
    Invoke-InvalidConfigurationCase -Value $hostingMismatch -Name 'hosting-mismatch' -Expected 'requires a Personal host pool'
    Write-Pass 'workload hosting must match the host pool type.'

    $personalWithSessions = Copy-Configuration
    $personalWithSessions.workload.hosting = 'Dedicated'
    $personalWithSessions.hostPool = [ordered]@{ type = 'Personal'; assignmentType = 'Automatic'; maxSessionLimit = 4 }
    $personalWithSessions.Remove('scaling')
    Invoke-InvalidConfigurationCase -Value $personalWithSessions -Name 'personal-with-session-limit'
    Write-Pass 'personal host pools reject pooled-only settings.'

    $personalWithPooledSchedule = Copy-Configuration
    $personalWithPooledSchedule.workload.hosting = 'Dedicated'
    $personalWithPooledSchedule.hostPool = [ordered]@{ type = 'Personal'; assignmentType = 'Automatic' }
    Invoke-InvalidConfigurationCase -Value $personalWithPooledSchedule -Name 'personal-with-pooled-schedule'
    Write-Pass 'personal host pools reject pooled scaling schedules.'

    # Questionnaire (New mode, non-interactive)
    $sharedPath = Join-Path $temporaryDirectory 'new-shared.json'
    $sharedText = (& $cliPath -Mode New -Offline -OutputFile $sharedPath -Hosting Shared -Persona Frontline -Users 120 -PeakConcurrencyPct 75 -UserIdentity Hybrid -ScalingPreset BusinessHours -TimeZone 'GMT Standard Time' -WorkdayStart '07:30' -WorkdayEnd '17:30' 6>$null) -join "`n"
    $shared = Get-Content -LiteralPath $sharedPath -Raw | ConvertFrom-Json -AsHashtable
    Assert-True ($sharedText -match 'Configuration written' -and $shared.schemaVersion -eq '1.3.0' -and $shared.profile -eq 'AzureFilesHybridKerberos') 'New shared hybrid configuration was not written as 1.3.0 with hybrid FSLogix.'
    Assert-True ($shared.hostPool.type -eq 'Pooled' -and $shared.hostPool.maxSessionLimit -eq 48 -and $shared.sessionHosts.count -eq 3) 'New shared Frontline 120 users @75% should be 3 hosts at 48 sessions.'
    Assert-True ($shared.scaling.schedules[0].rampUp.startTime -eq '06:30' -and $shared.scaling.schedules[0].offPeak.startTime -eq '18:30') 'Business-hours schedule did not follow the working day.'
    Assert-True ($shared.scaling.schedules[0].rampUp.capacityThresholdPct -eq 2 -and $shared.scaling.schedules[0].rampUp.loadBalancing -eq 'BreadthFirst') 'Shared Frontline (48 sessions) should start a spare host at a 2% threshold with breadth-first.'
    Assert-True (@($shared.scaling.schedules | Where-Object { $_.rampUp.minimumHostsPct -lt 1 -or $_.rampDown.minimumHostsPct -lt 1 }).Count -eq 0) 'Shared schedules must keep at least one host on in every phase.'
    Assert-True (@($shared.scaling.schedules | Where-Object { $_.rampDown.forceLogoffUsers -or $_.rampDown.stopHostsWhen -ne 'ZeroSessions' }).Count -eq 0) 'Shared schedules must never stop hosts with active or disconnected sessions.'
    Assert-True ($shared.tenantId -eq $configuration.tenantId -and $shared.network.virtualNetworkName -eq $configuration.network.virtualNetworkName) 'New mode did not preserve base configuration values.'
    Write-Pass 'New mode writes a valid shared configuration from the questionnaire answers.'

    $dedicatedPath = Join-Path $temporaryDirectory 'new-dedicated.json'
    $null = & $cliPath -Mode New -Offline -OutputFile $dedicatedPath -Hosting Dedicated -Persona Heavy -Users 8 -ScalingPreset BusinessHours -TimeZone 'GMT Standard Time' -WorkdayStart '08:00' -WorkdayEnd '18:00' 6>$null
    $dedicatedConfig = Get-Content -LiteralPath $dedicatedPath -Raw | ConvertFrom-Json -AsHashtable
    Assert-True ($dedicatedConfig.hostPool.type -eq 'Personal' -and $dedicatedConfig.sessionHosts.count -eq 8 -and $dedicatedConfig.sessionHosts.vmSize -eq 'Standard_D8s_v5') 'New dedicated Heavy 8 users should be 8 personal D8s_v5 hosts.'
    Assert-True ($dedicatedConfig.scaling.schedules[0].rampUp.autoStartHosts -eq 'None' -and $dedicatedConfig.scaling.schedules[0].peak.startVMOnConnect) 'Dedicated schedule should rely on Start VM on Connect.'
    Assert-True ($dedicatedConfig.profile -eq 'LocalProfile' -and -not $dedicatedConfig.ContainsKey('storage') -and -not $dedicatedConfig.identity.ContainsKey('kerberosDomainName') -and $dedicatedConfig.hostPool.assignmentType -eq 'Direct') 'Dedicated pools should use local profiles, no storage and direct assignment.'
    Write-Pass 'New mode writes a valid dedicated configuration with local profiles, direct assignment and personal schedules.'

    $cloudPath = Join-Path $temporaryDirectory 'new-cloud-only.json'
    $cloudText = (& $cliPath -Mode New -Offline -OutputFile $cloudPath -Hosting Shared -Persona Standard -Users 60 -PeakConcurrencyPct 80 -UserIdentity CloudOnly -ScalingPreset None 6>$null) -join "`n"
    $cloud = Get-Content -LiteralPath $cloudPath -Raw | ConvertFrom-Json -AsHashtable
    Assert-True ($cloud.profile -eq 'AzureFilesEntraKerberosCloudOnly' -and $cloud.storage.acknowledgePreview -and -not $cloud.identity.ContainsKey('kerberosDomainGuid')) 'Cloud-only shared pools should acknowledge the preview and drop hybrid domain details.'
    Assert-True ($cloudText -match 'cloud-only identities - Microsoft PREVIEW') 'Cloud-only summary should flag the Microsoft preview.'
    Write-Pass 'New mode writes a cloud-only FSLogix configuration flagged as preview.'

    # Profile and identity contract rules
    $unacknowledged = Copy-Configuration -Source $cloud
    $unacknowledged.storage.Remove('acknowledgePreview')
    Invoke-InvalidConfigurationCase -Value $unacknowledged -Name 'cloud-only-unacknowledged'
    $cloudWithDomain = Copy-Configuration -Source $cloud
    $cloudWithDomain.identity.kerberosDomainName = 'corp.example.invalid'
    Invoke-InvalidConfigurationCase -Value $cloudWithDomain -Name 'cloud-only-with-domain'
    $hybridWithoutDomain = Copy-Configuration
    $hybridWithoutDomain.identity.Remove('kerberosDomainGuid')
    Invoke-InvalidConfigurationCase -Value $hybridWithoutDomain -Name 'hybrid-without-domain'
    Write-Pass 'cloud-only needs a preview acknowledgement and no AD domain; hybrid needs domain details.'

    $pooledLocal = Copy-Configuration
    $pooledLocal.schemaVersion = '1.3.0'
    $pooledLocal.profile = 'LocalProfile'
    $pooledLocal.Remove('storage')
    $pooledLocal.identity.Remove('kerberosDomainName')
    $pooledLocal.identity.Remove('kerberosDomainGuid')
    Invoke-InvalidConfigurationCase -Value $pooledLocal -Name 'pooled-local-profile'
    $personalFslogix = Copy-Configuration -Source $dedicatedConfig
    $personalFslogix.profile = 'AzureFilesHybridKerberos'
    $personalFslogix.storage = [ordered]@{ accountName = 'avdexample123456' }
    $personalFslogix.identity.kerberosDomainName = 'corp.example.invalid'
    $personalFslogix.identity.kerberosDomainGuid = '33333333-3333-4333-8333-333333333333'
    Invoke-InvalidConfigurationCase -Value $personalFslogix -Name 'personal-fslogix'
    $localWithStorage = Copy-Configuration -Source $dedicatedConfig
    $localWithStorage.storage = [ordered]@{ accountName = 'avdexample123456' }
    Invoke-InvalidConfigurationCase -Value $localWithStorage -Name 'local-with-storage'
    Write-Pass 'shared pools need FSLogix storage and dedicated pools use local profiles without storage.'

    # Expanding an existing V2 deployment
    $expandPath = Join-Path $temporaryDirectory 'expand.json'
    Copy-Item -LiteralPath $sharedPath -Destination $expandPath
    $expandText = (& $cliPath -Mode Expand -ConfigurationFile $expandPath -AddHosts 2 6>&1) -join "`n"
    $expanded = Get-Content -LiteralPath $expandPath -Raw | ConvertFrom-Json -AsHashtable
    Assert-True ($expanded.sessionHosts.count -eq 5 -and $expanded.sessionHosts.vmSize -eq $shared.sessionHosts.vmSize -and $expanded.hostPool.maxSessionLimit -eq 48) 'Expand -AddHosts 2 should add two hosts without changing size or session limit.'
    Assert-True ($expandText -match 'AVDHOST-3, AVDHOST-4') 'Expand should name the new hosts.'
    Write-Pass 'Expand adds pooled hosts in place with stable names and unchanged size.'

    $null = & $cliPath -Mode Expand -ConfigurationFile $expandPath -Users 400 6>$null
    $resized = Get-Content -LiteralPath $expandPath -Raw | ConvertFrom-Json -AsHashtable
    Assert-True ($resized.sessionHosts.count -eq 8 -and $resized.workload.users -eq 400) 'Expand -Users 400 (Frontline @75%) should grow to 8 hosts.'
    $shrinkText = (& $cliPath -Mode Expand -ConfigurationFile $expandPath -Users 10 6>&1) -join "`n"
    Assert-True ((Get-Content -LiteralPath $expandPath -Raw | ConvertFrom-Json -AsHashtable).sessionHosts.count -eq 8 -and $shrinkText -match 'never drains or deletes') 'Expand must never reduce the host count.'
    Write-Pass 'Expand re-sizes from a new user count but never reduces hosts.'

    Assert-Throws -Name 'expand-direct-personal' -Expected 'Use -Mode AddUser' -Action { & $cliPath -Mode Expand -ConfigurationFile $dedicatedPath -AddHosts 1 6>$null }
    Assert-Throws -Name 'expand-requires-file' -Expected 'needs -ConfigurationFile' -Action { & $cliPath -Mode Expand -AddHosts 1 6>$null }
    Write-Pass 'Expand refuses direct-assignment dedicated pools and needs an explicit saved configuration.'

    # Dedicated user assignment
    $assignPath = Join-Path $temporaryDirectory 'assign.json'
    $null = & $cliPath -Mode New -Offline -OutputFile $assignPath -Hosting Dedicated -Persona Standard -Users 1 -ScalingPreset None 6>$null
    Remove-Item Function:\Get-MgContext, Function:\Invoke-MgGraphRequest -ErrorAction SilentlyContinue
    if (-not (Get-Command Get-MgContext -ErrorAction SilentlyContinue)) {
        Assert-Throws -Name 'adduser-without-graph' -Expected 'Connect-MgGraph' -Action { & $cliPath -Mode AddUser -ConfigurationFile $assignPath -UserPrincipalName 'jane.doe@example.com' 6>$null }
    }
    function global:Get-MgContext { [pscustomobject]@{ TenantId = '99999999-9999-4999-8999-999999999999' } }
    function global:Invoke-MgGraphRequest { param($Method, $Uri, $OutputType) @{ id = 'aaaaaaaa-0000-4000-8000-000000000001'; userPrincipalName = 'Jane.Doe@example.com'; displayName = 'Jane Doe' } }
    Assert-Throws -Name 'adduser-wrong-tenant' -Expected 'but this configuration targets tenant' -Action { & $cliPath -Mode AddUser -ConfigurationFile $assignPath -UserPrincipalName 'jane.doe@example.com' 6>$null }
    function global:Get-MgContext { [pscustomobject]@{ TenantId = '11111111-1111-4111-8111-111111111111' } }
    $addText = (& $cliPath -Mode AddUser -ConfigurationFile $assignPath -UserPrincipalName 'jane.doe@example.com' 6>&1) -join "`n"
    $assignedConfig = Get-Content -LiteralPath $assignPath -Raw | ConvertFrom-Json -AsHashtable
    Assert-True ($assignedConfig.sessionHosts.count -eq 1 -and $assignedConfig.assignments[0].objectId -eq 'aaaaaaaa-0000-4000-8000-000000000001' -and $assignedConfig.assignments[0].hostIndex -eq 0) 'AddUser should resolve the UPN and assign the existing unassigned host.'
    Assert-True ($addText -match 'Found Jane Doe' -and $addText -match 'AVDHOST-0 -> Jane.Doe@example.com') 'AddUser should report the resolved user and assignment.'
    Write-Pass 'AddUser resolves the UPN with a tenant-checked Graph lookup and fills an unassigned host.'

    $null = & $cliPath -Mode AddUser -ConfigurationFile $assignPath -UserPrincipalName 'bob@example.com' -UserObjectId 'bbbbbbbb-0000-4000-8000-000000000002' 6>$null
    $twoUsers = Get-Content -LiteralPath $assignPath -Raw | ConvertFrom-Json -AsHashtable
    Assert-True ($twoUsers.sessionHosts.count -eq 2 -and $twoUsers.assignments[1].hostIndex -eq 1 -and $twoUsers.workload.users -eq 2) 'AddUser should add a new host when every host is assigned.'
    Assert-Throws -Name 'adduser-duplicate' -Expected 'already assigned' -Action { & $cliPath -Mode AddUser -ConfigurationFile $assignPath -UserPrincipalName 'BOB@example.com' -UserObjectId 'dddddddd-0000-4000-8000-000000000004' 6>$null }
    Assert-Throws -Name 'adduser-pooled' -Expected 'AddUser needs a dedicated' -Action { & $cliPath -Mode AddUser -ConfigurationFile $sharedPath -UserPrincipalName 'eve@example.com' -UserObjectId 'eeeeeeee-0000-4000-8000-000000000005' 6>$null }
    Remove-Item Function:\Get-MgContext, Function:\Invoke-MgGraphRequest -ErrorAction SilentlyContinue
    Write-Pass 'AddUser adds a host when needed and rejects duplicate users and shared pools.'

    $badIndex = Copy-Configuration -Source $twoUsers
    $badIndex.assignments[1].hostIndex = 5
    Invoke-InvalidConfigurationCase -Value $badIndex -Name 'assignment-index-out-of-range' -Expected 'only 2 host'
    $pooledAssignments = Copy-Configuration
    $pooledAssignments.schemaVersion = '1.3.0'
    $pooledAssignments.assignments = $twoUsers.assignments
    Invoke-InvalidConfigurationCase -Value $pooledAssignments -Name 'pooled-assignments'
    $automaticAssignments = Copy-Configuration -Source $twoUsers
    $automaticAssignments.hostPool.assignmentType = 'Automatic'
    Invoke-InvalidConfigurationCase -Value $automaticAssignments -Name 'automatic-assignments'
    Write-Pass 'assignments must target configured hosts in a direct-assignment dedicated pool.'

    $hibernate = Copy-Configuration -Source $dedicatedConfig
    $hibernate.scaling.schedules[0].offPeak.actionOnDisconnect = 'Hibernate'
    Invoke-InvalidConfigurationCase -Value $hibernate -Name 'personal-hibernate'
    Write-Pass 'hibernate is rejected because FSLogix profiles do not support it.'

    $noScalingPath = Join-Path $temporaryDirectory 'new-no-scaling.json'
    $null = & $cliPath -Mode New -Offline -OutputFile $noScalingPath -Hosting Shared -Persona Standard -Users 20 -PeakConcurrencyPct 100 -UserIdentity Hybrid -ScalingPreset None 6>$null
    Assert-True (-not (Get-Content -LiteralPath $noScalingPath -Raw | ConvertFrom-Json -AsHashtable).ContainsKey('scaling')) 'Always-available preset should not write a scaling plan.'
    Assert-Throws -Name 'overwrite' -Expected 'already exists' -Action {
        & $cliPath -Mode New -Offline -OutputFile $noScalingPath -Hosting Shared -Persona Standard -Users 20 -PeakConcurrencyPct 100 -UserIdentity Hybrid -ScalingPreset None 6>$null
    }
    Write-Pass 'always-available preset omits scaling and existing files are not overwritten without -Force.'

    # Bicep
    $buildOutput = & $cliPath -Mode Build -ConfigurationFile $examplePath
    Assert-True (($buildOutput | Where-Object { $_ -match '^Bicep compiled:' }).Count -eq 3) 'Build did not compile the foundation, platform and session-host templates.'
    Write-Pass 'foundation, platform and session-host Bicep entry points compile offline.'

    $bicep = Get-Command bicep -ErrorAction SilentlyContinue
    $compileTemplate = {
        param([string]$Path)
        $output = if ($bicep) { & $bicep.Source build $Path --stdout } else { & (Get-Command az).Source bicep build --file $Path --stdout }
        return ($output -join "`n")
    }
    $platformText = & $compileTemplate (Join-Path $v2Root 'infra/avd/platform.bicep')
    Assert-True ($platformText -match 'Microsoft\.DesktopVirtualization/scalingPlans"') 'Platform template does not contain a scaling plan.'
    Assert-True ($platformText -match 'Microsoft\.DesktopVirtualization/scalingPlans/personalSchedules') 'Platform template does not contain personal scaling schedules.'
    Assert-True ($platformText -match 'Persistent') 'Personal host pools must use the Persistent load balancer.'
    Assert-True ($platformText -match '489581de-a3bd-480d-9518-53dea7416b33') 'Start VM on Connect does not use the Power On Contributor role ID.'
    Assert-True ($platformText -notmatch '40c5ff49-9181-41f8-ae61-143b0e78555e') 'Workload template must not grant the subscription-scope Power On Off Contributor role.'
    Write-Pass 'platform template covers pooled/personal host pools, scaling and power-role boundaries.'

    $hostsText = & $compileTemplate (Join-Path $v2Root 'infra/avd/session-hosts.bicep')
    Assert-True ($hostsText -match 'win11-24h2-ent' -and $hostsText -match 'win11-24h2-avd') 'Session hosts must select single-session images for personal pools and multi-session images for pooled pools.'
    Assert-True ($hostsText -match '-ProfileMode Local' -and $hostsText -match '-ProfileMode FSLogix') 'Session hosts must pass the profile mode to the prep script.'
    Write-Pass 'session-host template selects the image and profile mode for the host pool type.'

    Assert-True ($platformText -match "not\(equals\(parameters\('profile'\), 'LocalProfile'\)\)") 'Storage, private endpoint and FSLogix shares must be conditional on a non-local profile.'
    Assert-True ($platformText -match "equals\(parameters\('profile'\), 'AzureFilesHybridKerberos'\)") 'Only the hybrid profile should send AD domain details to Azure Files.'
    Write-Pass 'platform template deploys FSLogix storage only for shared profiles, with cloud-only omitting AD domain details.'

    # ARM rejects a template that declares the same resource twice (for example a create and an `existing` reference),
    # even though what-if accepts it. Check every compiled template, including nested module templates.
    $findDuplicates = {
        param($Template, [string]$Path)
        $resources = if ($Template.resources -is [System.Collections.IDictionary]) { @($Template.resources.Values) } else { @($Template.resources) }
        $seen = @{}
        foreach ($resource in $resources) {
            $key = "$($resource.type)|$($resource.name)"
            if ($seen.ContainsKey($key)) { "$Path declares $key twice" }
            $seen[$key] = $true
            if ($resource.type -eq 'Microsoft.Resources/deployments' -and $resource.properties.template) {
                & $findDuplicates $resource.properties.template "$Path > $($resource.name)"
            }
        }
    }
    $duplicates = foreach ($entry in 'foundation.bicep', 'platform.bicep', 'session-hosts.bicep') {
        $compiled = (& $compileTemplate (Join-Path $v2Root "infra/avd/$entry")) | ConvertFrom-Json -AsHashtable -Depth 64
        & $findDuplicates $compiled $entry
    }
    Assert-True (@($duplicates).Count -eq 0) "Templates declare a resource more than once: $(@($duplicates) -join '; ')"
    Write-Pass 'no compiled template declares the same resource twice.'
    $prepPath = Join-Path $v2Root 'scripts/session-host-prep.ps1'
    $tokens = $null
    $parseErrors = $null
    $prepAst = [System.Management.Automation.Language.Parser]::ParseFile($prepPath, [ref]$tokens, [ref]$parseErrors)
    $profileModeParameter = $prepAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'ProfileMode' }
    Assert-True ($parseErrors.Count -eq 0 -and $profileModeParameter) 'The V2 session host prep script must parse and accept -ProfileMode.'
    Write-Pass 'V2 session host prep script parses and supports FSLogix and local profile modes.'

    $prepText = [System.IO.File]::ReadAllText($prepPath)
    $preventParameter = $prepAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'PreventTempProfile' }
    Assert-True ($preventParameter -and $prepText -match "'LoadCredKeyFromProfile'" -and $prepText -match "'PreventLoginWithTempProfile'") 'Host prep must load credential keys from the profile and support blocking temporary profiles.'
    Assert-True ($prepText -notmatch "'Microsoft\.Windows\.StartMenuExperienceHost'|'Microsoft\.WindowsAppRuntime|'Microsoft\.WindowsStore'") 'Host prep must not remove shell components, framework packages or the Store.'
    Write-Pass 'host prep sets LoadCredKeyFromProfile and keeps Windows shell and framework packages.'

    $displayConfiguration = Copy-Configuration
    $displayConfiguration.display = [ordered]@{ workspaceName = 'Contoso Workspace'; desktopName = 'Contoso Desktop' }
    $displayConfiguration.fslogix = [ordered]@{ preventTempProfile = $true }
    Invoke-InvalidConfigurationCase -Value $displayConfiguration -Name 'display-needs-1-5-0'
    $displayConfiguration.schemaVersion = '1.5.0'
    $displayText = (& $cliPath -Mode Validate -ConfigurationFile (Save-Configuration -Value $displayConfiguration -Name 'display-valid')) -join "`n"
    Assert-True ($displayText -match "Users see: workspace 'Contoso Workspace', desktop 'Contoso Desktop'" -and $displayText -match 'sign-in is blocked if the profile cannot attach') 'A 1.5.0 configuration with display names and FSLogix options should validate and be summarised.'
    $displayConfiguration.display.desktopName = '<script>'
    Invoke-InvalidConfigurationCase -Value $displayConfiguration -Name 'display-markup'
    Write-Pass 'contract 1.5.0 adds display names and FSLogix options and rejects them on older versions.'

    Write-Host "$script:passed Phase 1 CLI tests passed."
} finally {
    Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
