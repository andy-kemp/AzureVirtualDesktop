#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Validate', 'Build', 'New', 'Expand', 'AddUser', 'Preview', 'Deploy')]
    [string]$Mode,
    # New: the base configuration. Expand/AddUser: the saved configuration of the existing V2 deployment.
    [string]$ConfigurationFile = (Join-Path $PSScriptRoot 'config/avd.example.json'),
    # New: required destination. Expand/AddUser: optional; defaults to updating -ConfigurationFile in place.
    [string]$OutputFile,
    [ValidateSet('Shared', 'Dedicated')]
    [string]$Hosting,
    [ValidateSet('Frontline', 'Standard', 'Heavy')]
    [string]$Persona,
    [ValidateRange(1, 5000)]
    [int]$Users,
    [ValidateRange(1, 100)]
    [int]$PeakConcurrencyPct,
    # Shared pools: identity type for FSLogix on Azure Files. CloudOnly is a Microsoft preview.
    [ValidateSet('Hybrid', 'CloudOnly')]
    [string]$UserIdentity,
    [ValidateSet('BusinessHours', 'None')]
    [string]$ScalingPreset,
    [ValidatePattern('^([01][0-9]|2[0-3]):[0-5][0-9]$')]
    [string]$WorkdayStart,
    [ValidatePattern('^([01][0-9]|2[0-3]):[0-5][0-9]$')]
    [string]$WorkdayEnd,
    [string]$TimeZone,
    # Expand: number of pooled hosts to add (or pass -Users to re-size from the persona).
    [ValidateRange(1, 100)]
    [int]$AddHosts,
    # AddUser: the dedicated user. Without -UserObjectId the UPN is resolved with a delegated, read-only Graph lookup.
    [string]$UserPrincipalName,
    [ValidatePattern('^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$')]
    [string]$UserObjectId,
    # Preview/Deploy: plan file (defaults to <configuration>.plan.json next to the configuration).
    [string]$PlanFile,
    # Deploy: non-interactive approval; must equal the target resource group name.
    [string]$Approve,
    # Deploy: run as the signed-in user instead of the deployment managed identity (sandbox/local testing).
    [switch]$AsSignedInUser,
    [ValidateRange(0, 60)]
    [int]$RegistrationWaitMinutes = 10,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'lib/AvdSizing.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/AvdExpansion.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/AvdDeployment.psm1') -Force

$schemaPath = Join-Path $PSScriptRoot 'contracts/avd-config.schema.json'
$templatePaths = @(
    (Join-Path $PSScriptRoot 'infra/avd/platform.bicep'),
    (Join-Path $PSScriptRoot 'infra/avd/session-hosts.bicep')
)
$canonicalKeyOrder = @(
    'schemaVersion', 'tenantId', 'subscriptionId', 'target', 'profile', 'execution', 'network', 'identity',
    'storage', 'accessGroups', 'workload', 'hostPool', 'sessionHosts', 'assignments', 'artifacts', 'scaling'
)

function Read-ValidatedConfiguration {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Configuration file was not found: $Path"
    }

    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    $json = [System.IO.File]::ReadAllText($resolvedPath)
    $schemaErrors = @()
    $isValid = Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction SilentlyContinue -ErrorVariable schemaErrors
    if (-not $isValid) {
        throw "Configuration does not satisfy the V2 contract in '$schemaPath'. Schema errors: $($schemaErrors.Count)."
    }

    $configuration = ConvertFrom-Json -InputObject $json -AsHashtable -Depth 32
    $identitySubscription = [regex]::Match($configuration.execution.deploymentIdentityResourceId, '^/subscriptions/([^/]+)/', 'IgnoreCase').Groups[1].Value
    if (-not $identitySubscription -or $identitySubscription -ne $configuration.subscriptionId) {
        throw 'The deployment UAMI must be in the configured customer subscription.'
    }

    if ($configuration.accessGroups.usersObjectId -eq $configuration.accessGroups.adminsObjectId) {
        throw 'The AVD users and admins groups must have different object IDs.'
    }

    $lastHostIndex = $configuration.sessionHosts.count - 1
    $lastHostName = "$($configuration.sessionHosts.namePrefix)-$lastHostIndex"
    if ($lastHostName.Length -gt 15) {
        throw 'The configured session-host prefix and count can produce a computer name longer than 15 characters.'
    }

    if ($configuration.ContainsKey('workload')) {
        $expectedType = if ($configuration.workload.hosting -eq 'Shared') { 'Pooled' } else { 'Personal' }
        if ($configuration.hostPool.type -ne $expectedType) {
            throw "Workload hosting '$($configuration.workload.hosting)' requires a $expectedType host pool, but hostPool.type is '$($configuration.hostPool.type)'."
        }
    }

    if ($configuration.ContainsKey('assignments')) {
        $seenHosts = @{}
        $seenUsers = @{}
        foreach ($assignment in $configuration.assignments) {
            if ($assignment.hostIndex -ge $configuration.sessionHosts.count) {
                throw "Assignment for $($assignment.userPrincipalName) refers to host index $($assignment.hostIndex), but only $($configuration.sessionHosts.count) host(s) are configured."
            }
            foreach ($key in "host:$($assignment.hostIndex)", "upn:$($assignment.userPrincipalName.ToLowerInvariant())", "id:$($assignment.objectId.ToLowerInvariant())") {
                $table = if ($key.StartsWith('host:')) { $seenHosts } else { $seenUsers }
                if ($table.ContainsKey($key)) {
                    throw "Assignments must be unique per host and per user; duplicate $key."
                }
                $table[$key] = $true
            }
        }
    }

    if ($configuration.ContainsKey('scaling')) {
        Test-ScalingConfiguration -Scaling $configuration.scaling
    }

    return $configuration
}

function Test-ScalingConfiguration {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Scaling
    )

    try {
        $null = [System.TimeZoneInfo]::FindSystemTimeZoneById($Scaling.timeZone)
    } catch {
        throw "Scaling time zone '$($Scaling.timeZone)' is not a recognised Windows time zone ID."
    }

    $scheduledDays = @{}
    foreach ($schedule in $Scaling.schedules) {
        foreach ($day in $schedule.daysOfWeek) {
            if ($scheduledDays.ContainsKey($day)) {
                throw "Scaling schedules '$($scheduledDays[$day])' and '$($schedule.name)' overlap on $day."
            }
            $scheduledDays[$day] = $schedule.name
        }

        # AVD evaluates the four phases in daily order, so each must start after the previous one.
        $phaseStarts = foreach ($phase in 'rampUp', 'peak', 'rampDown', 'offPeak') {
            [TimeSpan]::ParseExact($schedule[$phase].startTime, 'hh\:mm', [System.Globalization.CultureInfo]::InvariantCulture)
        }
        for ($index = 1; $index -lt $phaseStarts.Count; $index++) {
            if ($phaseStarts[$index] -le $phaseStarts[$index - 1]) {
                throw "Scaling schedule '$($schedule.name)' phases must start in order: rampUp < peak < rampDown < offPeak."
            }
        }
    }
}

function Invoke-BicepBuild {
    param(
        [Parameter(Mandatory)]
        [string]$TemplatePath
    )

    if (-not (Test-Path -LiteralPath $TemplatePath -PathType Leaf)) {
        throw "V2 Bicep template was not found: $TemplatePath"
    }

    $bicep = Get-Command bicep -ErrorAction SilentlyContinue
    if ($bicep) {
        & $bicep.Source build $TemplatePath --stdout | Out-Null
    } else {
        $az = Get-Command az -ErrorAction SilentlyContinue
        if (-not $az) {
            throw 'Install the standalone Bicep CLI or Azure CLI with its Bicep command available before running Build.'
        }
        & $az.Source bicep build --file $TemplatePath --stdout | Out-Null
    }

    if ($LASTEXITCODE -ne 0) {
        throw "Bicep compilation failed for '$TemplatePath' (exit code $LASTEXITCODE)."
    }
}

function Read-Choice {
    param(
        [Parameter(Mandatory)]
        [string]$Question,
        [Parameter(Mandatory)]
        [System.Collections.Specialized.OrderedDictionary]$Options
    )

    $values = @($Options.Keys)
    Write-Host ''
    Write-Host $Question
    for ($index = 0; $index -lt $values.Count; $index++) {
        Write-Host "  [$($index + 1)] $($Options[$values[$index]])"
    }
    while ($true) {
        $answer = Read-Host "Choose 1-$($values.Count) (default 1)"
        if ([string]::IsNullOrWhiteSpace($answer)) {
            return $values[0]
        }
        $number = 0
        if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $values.Count) {
            return $values[$number - 1]
        }
        Write-Host 'Please enter one of the listed numbers.'
    }
}

function Read-Number {
    param(
        [Parameter(Mandatory)]
        [string]$Question,
        [int]$Minimum,
        [int]$Maximum,
        [int]$Default = 0
    )

    while ($true) {
        $prompt = if ($Default -gt 0) { "$Question (default $Default)" } else { $Question }
        $answer = Read-Host $prompt
        if ([string]::IsNullOrWhiteSpace($answer) -and $Default -gt 0) {
            return $Default
        }
        $number = 0
        if ([int]::TryParse($answer, [ref]$number) -and $number -ge $Minimum -and $number -le $Maximum) {
            return $number
        }
        Write-Host "Please enter a whole number from $Minimum to $Maximum."
    }
}

function Read-Text {
    param(
        [Parameter(Mandatory)]
        [string]$Question,
        [string]$Default = '',
        [string]$Pattern = '.+'
    )

    while ($true) {
        $prompt = if ($Default) { "$Question (default $Default)" } else { $Question }
        $answer = Read-Host $prompt
        if ([string]::IsNullOrWhiteSpace($answer) -and $Default) {
            return $Default
        }
        if ($answer -match $Pattern) {
            return $answer
        }
        Write-Host 'That value is not in the expected format.'
    }
}

function ConvertTo-CanonicalConfiguration {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Configuration
    )

    $ordered = [ordered]@{}
    foreach ($key in $canonicalKeyOrder) {
        if ($Configuration.Contains($key)) {
            $ordered[$key] = $Configuration[$key]
        }
    }
    return $ordered
}

function New-SizedConfiguration {
    param(
        [Parameter(Mandatory)]
        [string]$BasePath,
        [Parameter(Mandatory)]
        [string]$DestinationPath
    )

    if ((Test-Path -LiteralPath $DestinationPath) -and -not $Force) {
        throw "Output file already exists: $DestinationPath. Use -Force to overwrite it."
    }
    if (-not (Test-Path -LiteralPath $BasePath -PathType Leaf)) {
        throw "Base configuration file was not found: $BasePath"
    }
    $configuration = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $BasePath).Path)) -AsHashtable -Depth 32
    $sizingProfile = Get-AvdSizingProfile

    $answers = @{}
    $answers.hosting = if ($script:Hosting) { $script:Hosting } else {
        Read-Choice -Question 'Is this a shared platform or dedicated session hosts for users?' -Options ([ordered]@{
                Shared    = 'Shared - users share multi-session hosts (pooled host pool)'
                Dedicated = 'Dedicated - each user gets their own personal VM (personal host pool)'
            })
    }
    $answers.persona = if ($script:Persona) { $script:Persona } else {
        $personaOptions = [ordered]@{}
        foreach ($name in 'Frontline', 'Standard', 'Heavy') {
            $personaOptions[$name] = "$($sizingProfile.personas[$name].label) - $($sizingProfile.personas[$name].description)"
        }
        Read-Choice -Question 'Which persona best describes these users?' -Options $personaOptions
    }
    $answers.users = if ($script:Users -gt 0) { $script:Users } else {
        Read-Number -Question 'How many users need access?' -Minimum 1 -Maximum 5000
    }
    $answers.peakConcurrencyPct = if ($answers.hosting -eq 'Dedicated') { 100 } elseif ($script:PeakConcurrencyPct -gt 0) { $script:PeakConcurrencyPct } else {
        Read-Number -Question 'At peak, what percentage of those users are signed in at the same time?' -Minimum 1 -Maximum 100 -Default 100
    }

    $recommendation = Get-AvdSizingRecommendation -Hosting $answers.hosting -Persona $answers.persona -Users $answers.users -PeakConcurrencyPct $answers.peakConcurrencyPct
    Write-Host ''
    Write-Host 'Sizing recommendation (starting estimate - validate with a pilot):'
    foreach ($line in $recommendation.explanation) {
        Write-Host "  $line"
    }

    $identityChoice = $null
    if ($answers.hosting -eq 'Shared') {
        $identityChoice = if ($script:UserIdentity) { $script:UserIdentity } else {
            Read-Choice -Question 'Shared hosts store profiles with FSLogix on Azure Files. How are these users'' identities managed?' -Options ([ordered]@{
                    Hybrid    = 'Hybrid - synced from on-premises Active Directory (generally available)'
                    CloudOnly = 'Cloud-only - Microsoft Entra ID only (Microsoft preview, extra prerequisites)'
                })
        }
    }

    $preset = if ($script:ScalingPreset) { $script:ScalingPreset } else {
        Read-Choice -Question 'How should session hosts scale with demand?' -Options ([ordered]@{
                BusinessHours = 'Business hours - power hosts up for the working day and down when usage is light'
                None          = 'Always available - no scaling plan (all hosts stay running)'
            })
    }

    $hostPoolType = $recommendation.hostPool.type
    $configuration.schemaVersion = '1.3.0'
    $configuration.Remove('assignments')
    $configuration.workload = [ordered]@{
        hosting            = $answers.hosting
        persona            = $answers.persona
        users              = $answers.users
        peakConcurrencyPct = $answers.peakConcurrencyPct
    }
    $configuration.hostPool = $recommendation.hostPool
    $configuration.sessionHosts.count = $recommendation.sessionHosts.count
    $configuration.sessionHosts.vmSize = $recommendation.sessionHosts.vmSize

    switch ($identityChoice) {
        'Hybrid' {
            if (-not $configuration.ContainsKey('storage') -or -not $configuration.identity.ContainsKey('kerberosDomainName') -or -not $configuration.identity.ContainsKey('kerberosDomainGuid')) {
                throw 'Hybrid identities need storage.accountName and identity.kerberosDomainName/kerberosDomainGuid in the base configuration.'
            }
            $configuration.profile = 'AzureFilesHybridKerberos'
            $configuration.storage.Remove('acknowledgePreview')
        }
        'CloudOnly' {
            if (-not $configuration.ContainsKey('storage')) {
                throw 'Cloud-only FSLogix needs storage.accountName in the base configuration.'
            }
            $configuration.profile = 'AzureFilesEntraKerberosCloudOnly'
            $configuration.storage.acknowledgePreview = $true
            $configuration.identity.Remove('kerberosDomainName')
            $configuration.identity.Remove('kerberosDomainGuid')
            Write-Host ''
            Write-Host 'Cloud-only FSLogix uses Microsoft Entra Kerberos for cloud-only identities, which Microsoft documents as PREVIEW.'
            Write-Host 'Before users sign in, a customer administrator must: grant admin consent to the storage account''s Entra app,'
            Write-Host 'add the cloud group SID tag to its manifest, exclude it from Conditional Access MFA, and set share/folder permissions.'
            Write-Host 'Session hosts need Windows 11 24H2 with KB5079391 or later (the latest gallery image includes it).'
        }
        default {
            $configuration.profile = 'LocalProfile'
            $configuration.Remove('storage')
            $configuration.identity.Remove('kerberosDomainName')
            $configuration.identity.Remove('kerberosDomainGuid')
        }
    }

    if ($preset -eq 'BusinessHours') {
        $existingScaling = if ($configuration.ContainsKey('scaling')) { $configuration.scaling } else { @{} }
        $defaultTimeZone = if ($existingScaling.ContainsKey('timeZone')) { $existingScaling.timeZone } else { 'GMT Standard Time' }
        $selectedTimeZone = if ($script:TimeZone) { $script:TimeZone } else { Read-Text -Question 'Scaling time zone (Windows time zone ID)' -Default $defaultTimeZone }
        $timePattern = '^([01][0-9]|2[0-3]):[0-5][0-9]$'
        $start = if ($script:WorkdayStart) { $script:WorkdayStart } else { Read-Text -Question 'Working day starts (HH:mm)' -Default '08:00' -Pattern $timePattern }
        $end = if ($script:WorkdayEnd) { $script:WorkdayEnd } else { Read-Text -Question 'Working day ends (HH:mm)' -Default '18:00' -Pattern $timePattern }

        $scaling = [ordered]@{
            enabled  = $true
            timeZone = $selectedTimeZone
        }
        $scaling.exclusionTag = if ($existingScaling.ContainsKey('exclusionTag')) { $existingScaling.exclusionTag } else { 'AVD-ScalingExclude' }
        $scheduleArguments = @{ HostPoolType = $hostPoolType; WorkdayStart = $start; WorkdayEnd = $end }
        if ($hostPoolType -eq 'Pooled') {
            $scheduleArguments.MaxSessionLimit = $recommendation.hostPool.maxSessionLimit
        }
        $scaling.schedules = @(New-AvdBusinessHoursSchedule @scheduleArguments)
        $configuration.scaling = $scaling
    } else {
        $configuration.Remove('scaling')
    }

    return Save-Configuration -Configuration $configuration -Path $DestinationPath
}

function Save-Configuration {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Configuration,
        [Parameter(Mandatory)]
        [string]$Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $json = (ConvertTo-CanonicalConfiguration -Configuration $Configuration) | ConvertTo-Json -Depth 32
    $directory = Split-Path -Path $fullPath -Parent
    if (-not (Test-Path -LiteralPath $directory)) {
        [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    }
    [System.IO.File]::WriteAllText($fullPath, $json + [Environment]::NewLine)
    return $fullPath
}

function Invoke-ExistingDeploymentChange {
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,
        [string]$DestinationPath
    )

    # Validate first: expansion only applies to a valid saved V2 configuration.
    $configuration = Read-ValidatedConfiguration -Path $SourcePath
    $destination = if ($DestinationPath) { $DestinationPath } else { $SourcePath }
    if ($DestinationPath -and (Test-Path -LiteralPath $DestinationPath) -and -not $Force) {
        throw "Output file already exists: $DestinationPath. Use -Force to overwrite it."
    }

    if ($Mode -eq 'Expand') {
        $expandArguments = @{ Configuration = $configuration }
        if ($script:AddHosts -gt 0) {
            $expandArguments.AddHosts = $script:AddHosts
        } elseif ($script:Users -gt 0) {
            $expandArguments.Users = $script:Users
            if ($script:PeakConcurrencyPct -gt 0) {
                $expandArguments.PeakConcurrencyPct = $script:PeakConcurrencyPct
            }
        } else {
            $expandArguments.AddHosts = Read-Number -Question 'How many shared session hosts should be added?' -Minimum 1 -Maximum 100
        }
        $result = Add-AvdPooledCapacity @expandArguments
        foreach ($message in $result.Messages) {
            Write-Host $message
        }
        if ($result.Added -eq 0) {
            return $SourcePath
        }
    } else {
        $upn = if ($script:UserPrincipalName) { $script:UserPrincipalName } else {
            Read-Text -Question 'User principal name (UPN) of the dedicated user' -Default '' -Pattern '^[^@\s]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
        }
        $objectId = $script:UserObjectId
        if (-not $objectId) {
            $user = Resolve-AvdEntraUser -UserPrincipalName $upn -TenantId $configuration.tenantId
            Write-Host "Found $($user.DisplayName) ($($user.UserPrincipalName)), object ID $($user.ObjectId)."
            $upn = $user.UserPrincipalName
            $objectId = $user.ObjectId
        }
        $result = Add-AvdUserAssignment -Configuration $configuration -UserPrincipalName $upn -ObjectId $objectId
        Write-Host $result.Message
    }

    return Save-Configuration -Configuration $result.Configuration -Path $destination
}

function Write-ConfigurationSummary {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Configuration
    )

    Write-Output "Configuration valid: tenant $($Configuration.tenantId), subscription $($Configuration.subscriptionId), resource group $($Configuration.target.resourceGroupName), hosts $($Configuration.sessionHosts.count)."

    if ($Configuration.ContainsKey('hostPool') -and $Configuration.hostPool.type -eq 'Personal') {
        Write-Output "Host pool: Personal (dedicated, $($Configuration.hostPool.assignmentType) assignment), $($Configuration.sessionHosts.count) x $($Configuration.sessionHosts.vmSize)."
    } elseif ($Configuration.ContainsKey('hostPool')) {
        Write-Output "Host pool: Pooled (shared), max $($Configuration.hostPool.maxSessionLimit) sessions/host, $($Configuration.hostPool.loadBalancer), $($Configuration.sessionHosts.count) x $($Configuration.sessionHosts.vmSize)."
    } else {
        Write-Output "Host pool: Pooled (legacy default: max 5 sessions/host, BreadthFirst), $($Configuration.sessionHosts.count) x $($Configuration.sessionHosts.vmSize)."
    }

    switch ($Configuration.profile) {
        'AzureFilesHybridKerberos' {
            Write-Output "Profiles: FSLogix on Azure Files '$($Configuration.storage.accountName)' for hybrid identities (Microsoft Entra Kerberos, domain $($Configuration.identity.kerberosDomainName))."
        }
        'AzureFilesEntraKerberosCloudOnly' {
            Write-Output "Profiles: FSLogix on Azure Files '$($Configuration.storage.accountName)' for cloud-only identities - Microsoft PREVIEW. Prerequisites: storage app admin consent, cloud group SID manifest tag, Conditional Access MFA exclusion, share/folder permissions."
        }
        'LocalProfile' {
            Write-Output 'Profiles: local on each dedicated VM (no FSLogix or storage account), like Windows 365.'
        }
    }

    if ($Configuration.ContainsKey('hostPool') -and $Configuration.hostPool.type -eq 'Personal' -and $Configuration.hostPool.assignmentType -eq 'Direct') {
        $assigned = @(if ($Configuration.ContainsKey('assignments')) { $Configuration.assignments })
        foreach ($assignment in $assigned) {
            Write-Output "  $($Configuration.sessionHosts.namePrefix)-$($assignment.hostIndex) -> $($assignment.userPrincipalName)"
        }
        $assignedIndexes = @($assigned | ForEach-Object { [int]$_.hostIndex })
        $unassigned = @(0..($Configuration.sessionHosts.count - 1) | Where-Object { $_ -notin $assignedIndexes })
        Write-Output "Assignments: $($assigned.Count) of $($Configuration.sessionHosts.count) dedicated host(s) assigned$(if ($unassigned.Count) { "; unassigned: $(($unassigned | ForEach-Object { "$($Configuration.sessionHosts.namePrefix)-$_" }) -join ', ') (use -Mode AddUser)" })."
    }

    if ($Configuration.ContainsKey('workload')) {
        $workload = $Configuration.workload
        try {
            $recommended = Get-AvdSizingRecommendation -Hosting $workload.hosting -Persona $workload.persona -Users $workload.users -PeakConcurrencyPct $workload.peakConcurrencyPct
            $isMatch = $recommended.sessionHosts.count -eq $Configuration.sessionHosts.count -and
                $recommended.sessionHosts.vmSize -eq $Configuration.sessionHosts.vmSize -and
                (-not $recommended.hostPool.Contains('maxSessionLimit') -or $recommended.hostPool.maxSessionLimit -eq $Configuration.hostPool.maxSessionLimit)
            $state = if ($isMatch) { 'matches recommendation' } else { "OVERRIDE - recommended $($recommended.sessionHosts.count) x $($recommended.sessionHosts.vmSize)" }
            Write-Output "Sizing: $($workload.users) $($workload.persona) user(s), $($workload.hosting.ToLowerInvariant()) at $($workload.peakConcurrencyPct)% peak - $state."
        } catch {
            Write-Output "Sizing: $($_.Exception.Message)"
        }
        if ($workload.hosting -eq 'Dedicated' -and $Configuration.sessionHosts.count -lt $workload.users) {
            Write-Output "Warning: $($workload.users) dedicated users but only $($Configuration.sessionHosts.count) personal host(s); some users will not receive a desktop."
        }
    }

    if ($Configuration.ContainsKey('scaling')) {
        $scalingState = if ($Configuration.scaling.enabled) { 'enabled' } else { 'deployed disabled' }
        Write-Output "Scaling plan: $scalingState, $($Configuration.scaling.schedules.Count) schedule(s), time zone '$($Configuration.scaling.timeZone)'. Prerequisite: AVD service principal needs 'Desktop Virtualization Power On Off Contributor' at subscription scope."
        $isPersonalPool = $Configuration.ContainsKey('hostPool') -and $Configuration.hostPool.type -eq 'Personal'
        if (-not $isPersonalPool) {
            $sessionLimit = if ($Configuration.ContainsKey('hostPool')) { $Configuration.hostPool.maxSessionLimit } else { 5 }
            $spareThreshold = Get-AvdSpareHostThreshold -MaxSessionLimit $sessionLimit
            foreach ($schedule in $Configuration.scaling.schedules) {
                $minimumHosts = [Math]::Min($schedule.rampUp.minimumHostsPct, $schedule.rampDown.minimumHostsPct)
                $startRule = if ($schedule.rampUp.capacityThresholdPct -le $spareThreshold) {
                    'a new host starts whenever every running host has a user, until all hosts are on'
                } else {
                    "a new host starts above $($schedule.rampUp.capacityThresholdPct)% of running capacity"
                }
                Write-Output "  Schedule '$($schedule.name)': working hours $($schedule.rampUp.loadBalancing); $startRule; hosts with active or disconnected sessions are $(if ($schedule.rampDown.forceLogoffUsers) { 'LOGGED OFF after a warning' } else { 'never shut down' })."
                if ($minimumHosts -eq 0) {
                    Write-Output "  Warning: schedule '$($schedule.name)' can stop every host; the first user then waits for Start VM on Connect. Set minimumHostsPct to at least 1 to keep one host on."
                }
            }
        }
    } else {
        Write-Output 'Scaling plan: not configured.'
    }
}

if ($Mode -eq 'New') {
    if (-not $OutputFile) {
        throw 'New mode requires -OutputFile for the generated configuration.'
    }
    $ConfigurationFile = New-SizedConfiguration -BasePath $ConfigurationFile -DestinationPath $OutputFile
} elseif ($Mode -in 'Expand', 'AddUser') {
    if (-not $PSBoundParameters.ContainsKey('ConfigurationFile')) {
        throw "$Mode needs -ConfigurationFile pointing at the saved configuration of the existing V2 deployment."
    }
    $ConfigurationFile = Invoke-ExistingDeploymentChange -SourcePath $ConfigurationFile -DestinationPath $OutputFile
}

$configuration = Read-ValidatedConfiguration -Path $ConfigurationFile
Write-ConfigurationSummary -Configuration $configuration

if ($Mode -eq 'New') {
    Write-Output "Configuration written: $ConfigurationFile"
    Write-Output 'Next: replace any example tenant, subscription, network, group, Key Vault and artifact values with your own, then run -Mode Validate and -Mode Build.'
} elseif ($Mode -in 'Expand', 'AddUser') {
    Write-Output "Configuration updated: $ConfigurationFile"
    Write-Output 'Next: run -Mode Preview to see the Azure changes, then -Mode Deploy. Existing hosts keep their names, VM size and assignments.'
}

if ($Mode -in 'Preview', 'Deploy') {
    if (-not $PSBoundParameters.ContainsKey('ConfigurationFile')) {
        throw "$Mode needs -ConfigurationFile pointing at your own configuration (the bundled example is not deployable)."
    }
    $resolvedConfiguration = (Resolve-Path -LiteralPath $ConfigurationFile).Path
    $planPath = if ($PlanFile) { $PlanFile } else { [System.IO.Path]::ChangeExtension($resolvedConfiguration, '.plan.json') }

    if ($Mode -eq 'Preview') {
        $preview = Invoke-AvdPreview -Configuration $configuration -ConfigurationPath $resolvedConfiguration -PlanPath $planPath
        Write-Output ''
        Write-Output "Plan written: $($preview.PlanFile)"
        Write-Output "Previewed changes: $($preview.Changes)"
        foreach ($warning in $preview.Warnings) { Write-Output "Warning: $warning" }
        if ($preview.Blockers.Count -gt 0) {
            Write-Output 'BLOCKED - fix these, then run Preview again:'
            foreach ($blocker in $preview.Blockers) { Write-Output "  - $blocker" }
        } else {
            Write-Output "Ready. Deploy with: -Mode Deploy -ConfigurationFile $ConfigurationFile$(if ($PlanFile) { " -PlanFile $PlanFile" }) [-AsSignedInUser]"
        }
    } else {
        $deployArguments = @{
            Configuration           = $configuration
            ConfigurationPath       = $resolvedConfiguration
            PlanPath                = $planPath
            AsSignedInUser          = $AsSignedInUser
            RegistrationWaitMinutes = $RegistrationWaitMinutes
        }
        if ($Approve) { $deployArguments.Approve = $Approve }
        $result = Invoke-AvdDeploy @deployArguments
        Write-Output ''
        Write-Output "Deployed to $($result.ResourceGroup), host pool $($result.HostPool)."
        foreach ($sessionHost in $result.SessionHosts) { Write-Output "  Session host: $sessionHost" }
        foreach ($assignment in $result.Assignments) { Write-Output "  Assigned: $assignment" }
        foreach ($member in $result.AddedToUsersGroup) { Write-Output "  In AVD users group: $member" }
        Write-Output 'Still to do (manual):'
        foreach ($task in $result.ManualTasks) { Write-Output "  - $task" }
    }
}

if ($Mode -eq 'Build') {
    foreach ($templatePath in $templatePaths) {
        Invoke-BicepBuild -TemplatePath $templatePath
        Write-Output "Bicep compiled: $([System.IO.Path]::GetRelativePath($PSScriptRoot, $templatePath))"
    }
}