#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Validate', 'Build', 'New', 'Expand', 'AddUser', 'Preview', 'Deploy', 'PostDeploy', 'Web')]
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
    # New: use this VM size instead of the persona recommendation (for example when the recommended size is restricted in the region).
    [ValidatePattern('^Standard_[A-Za-z0-9_]{1,55}$')]
    [string]$VmSize,
    # New: names users see in Windows App (defaults '<prefix> Workspace' and '<prefix> Virtual Desktop').
    [string]$WorkspaceName,
    [string]$DesktopName,
    # New (shared pools): TempProfile lets users in with a temporary profile if FSLogix cannot attach; Block stops the sign-in.
    [ValidateSet('TempProfile', 'Block')]
    [string]$ProfileFailureAction,
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
    # Deploy: after the hosts register, run the PostDeploy Entra and profile-share configuration.
    [switch]$PostDeploy,
    # PostDeploy: public IPv4 of this machine, allowed on the storage firewall while folder permissions are set (detected if omitted).
    [ValidatePattern('^\d{1,3}(\.\d{1,3}){3}$')]
    [string]$OperatorPublicIp,
    # PostDeploy: Ask before excluding the storage app from MFA Conditional Access policies, Exclude without asking, or Report only.
    [ValidateSet('Ask', 'Exclude', 'Report')]
    [string]$ConditionalAccess = 'Ask',
    [ValidateRange(0, 60)]
    [int]$RegistrationWaitMinutes = 10,
    # New: skip Azure/Entra discovery and only apply sizing answers to the base configuration.
    [switch]$Offline,
    # New (discovery): answers that would otherwise be prompted for.
    [string]$SubscriptionId,
    [ValidatePattern('^[a-z0-9]+$')]
    [string]$Location,
    [ValidatePattern('^[A-Za-z][A-Za-z0-9-]{0,9}$')]
    [string]$Prefix,
    [ValidatePattern('^[A-Za-z0-9._()\-]{1,90}$')]
    [string]$ResourceGroupName,
    [ValidateSet('New', 'Existing')]
    [string]$NetworkMode,
    [string]$AddressSpace,
    [string]$VirtualNetworkName,
    [string]$SessionHostSubnet,
    [string]$PrivateEndpointSubnet,
    [string]$UsersGroup,
    [string]$AdminsGroup,
    # New (discovery): create these Entra security groups instead of choosing existing ones (you become owner).
    [string]$NewUsersGroup,
    [string]$NewAdminsGroup,
    [switch]$AddMeToUsersGroup,
    # Web: local wizard port and whether to open the browser automatically.
    [ValidateRange(1024, 65535)]
    [int]$Port = 8770,
    [switch]$NoBrowser,
    [string]$KerberosDomainName,
    [string]$KerberosDomainGuid,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:NonInteractive = $false
$script:WebVmSize = ''

Import-Module (Join-Path $PSScriptRoot 'lib/AvdSizing.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/AvdExpansion.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/AvdDeployment.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/AvdDiscovery.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/AvdPostDeploy.psm1') -Force

$schemaPath = Join-Path $PSScriptRoot 'contracts/avd-config.schema.json'
$templatePaths = @(
    (Join-Path $PSScriptRoot 'infra/avd/foundation.bicep'),
    (Join-Path $PSScriptRoot 'infra/avd/platform.bicep'),
    (Join-Path $PSScriptRoot 'infra/avd/session-hosts.bicep')
)
$canonicalKeyOrder = @(
    'schemaVersion', 'tenantId', 'subscriptionId', 'target', 'profile', 'execution', 'network', 'identity',
    'storage', 'accessGroups', 'workload', 'hostPool', 'sessionHosts', 'assignments', 'artifacts', 'foundation', 'scaling', 'display', 'fslogix'
)

function Get-SchemaErrorDetail {
    # Test-Json reports only true/false on newer PowerShell, so ask the bundled JsonSchema.Net library for details.
    param([Parameter(Mandatory)][string]$Json)
    try {
        $schema = [Json.Schema.JsonSchema]::FromText([System.IO.File]::ReadAllText($schemaPath))
        $options = [Json.Schema.EvaluationOptions]::new()
        $options.OutputFormat = [Json.Schema.OutputFormat]::List
        $result = $schema.Evaluate([System.Text.Json.Nodes.JsonNode]::Parse($Json), $options)
        $messages = foreach ($detail in @($result.Details)) {
            # Failing "if" conditions are normal branch selection, not errors.
            if ($detail.IsValid -or -not $detail.Errors -or "$($detail.EvaluationPath)" -match '(^|\s)if(\s|$)') { continue }
            $location = ("$($detail.InstanceLocation)".Trim() -replace '\s+', '.')
            foreach ($key in $detail.Errors.Keys) { "$(if ($location) { $location } else { '(root)' }): $($detail.Errors[$key])" }
        }
        return @($messages | Select-Object -Unique -First 8)
    } catch {
        return @()
    }
}

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
        $details = @(Get-SchemaErrorDetail -Json $json)
        $detailText = if ($details.Count -gt 0) { "`n - " + ($details -join "`n - ") } else { " Schema errors: $($schemaErrors.Count)." }
        throw "Configuration does not satisfy the V2 contract in '$schemaPath'.$detailText"
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

    if ($configuration.ContainsKey('foundation')) {
        $foundation = $configuration.foundation
        $targetGroup = $configuration.target.resourceGroupName
        if ($foundation.ContainsKey('network') -and $configuration.network.resourceGroupName -ne $targetGroup) {
            throw "foundation.network creates the VNet in the target resource group, so network.resourceGroupName must be '$targetGroup'."
        }
        if ($foundation.ContainsKey('network') -and -not (Test-AvdCidrAligned -Cidr $foundation.network.addressSpace)) {
            throw "foundation.network.addressSpace '$($foundation.network.addressSpace)' is not a network boundary for its prefix length (for example use 10.200.0.0/16, not 10.200.1.0/16)."
        }
        if ($foundation.ContainsKey('keyVault')) {
            $expectedPrefix = "https://$($foundation.keyVault.name).vault.azure.net/secrets/"
            $secretPath = $configuration.sessionHosts.adminPasswordSecretUri
            if (-not $secretPath.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase) -or $secretPath.Substring($expectedPrefix.Length).Contains('/')) {
                throw "foundation.keyVault creates '$($foundation.keyVault.name)', so sessionHosts.adminPasswordSecretUri must be $expectedPrefix<secret-name> without a version."
            }
        }
        if ($foundation.ContainsKey('deploymentIdentity')) {
            $expectedIdentity = "/subscriptions/$($configuration.subscriptionId)/resourceGroups/$targetGroup/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$($foundation.deploymentIdentity.name)"
            if ($configuration.execution.deploymentIdentityResourceId -ne $expectedIdentity) {
                throw "foundation.deploymentIdentity creates '$($foundation.deploymentIdentity.name)', so execution.deploymentIdentityResourceId must be $expectedIdentity."
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

function Assert-Interactive {
    param([string]$Question)
    # The web wizard supplies every answer; a prompt there would block the local web server.
    if ($script:NonInteractive) { throw "Missing answer for: $Question" }
}

function Read-Choice {
    param(
        [Parameter(Mandatory)]
        [string]$Question,
        [Parameter(Mandatory)]
        [System.Collections.Specialized.OrderedDictionary]$Options
    )

    Assert-Interactive -Question $Question
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

    Assert-Interactive -Question $Question
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

    Assert-Interactive -Question $Question
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

function Get-SuggestedTimeZone {
    param([string]$Region, [string]$Default = 'GMT Standard Time')
    $regionZones = @{
        uksouth = 'GMT Standard Time'; ukwest = 'GMT Standard Time'; northeurope = 'GMT Standard Time'; westeurope = 'W. Europe Standard Time'
        eastus = 'Eastern Standard Time'; eastus2 = 'Eastern Standard Time'; canadacentral = 'Eastern Standard Time'; canadaeast = 'Eastern Standard Time'
        centralus = 'Central Standard Time'; northcentralus = 'Central Standard Time'; southcentralus = 'Central Standard Time'; westcentralus = 'Mountain Standard Time'
        westus = 'Pacific Standard Time'; westus2 = 'Pacific Standard Time'; westus3 = 'US Mountain Standard Time'
        australiaeast = 'AUS Eastern Standard Time'; japaneast = 'Tokyo Standard Time'; japanwest = 'Tokyo Standard Time'; koreacentral = 'Korea Standard Time'
        eastasia = 'China Standard Time'; southeastasia = 'Singapore Standard Time'; centralindia = 'India Standard Time'; southafricanorth = 'South Africa Standard Time'
    }
    if ($Region -and $regionZones.ContainsKey($Region)) { return $regionZones[$Region] }
    return $Default
}

function Read-TimeZone {
    param([string]$Default = 'GMT Standard Time', [string]$Region)

    # Sensible default per AVD region; the operator can still pick any Windows time zone.
    $suggested = Get-SuggestedTimeZone -Region $Region -Default $Default
    $options = [ordered]@{}
    foreach ($zone in @($suggested, $Default, 'GMT Standard Time', 'W. Europe Standard Time', 'Eastern Standard Time', 'Central Standard Time', 'Pacific Standard Time', 'AUS Eastern Standard Time', 'UTC') | Select-Object -Unique) {
        try {
            $info = [System.TimeZoneInfo]::FindSystemTimeZoneById($zone)
            $options[$zone] = "$($info.DisplayName) [$zone]"
        } catch {
            continue
        }
    }
    $options['Other'] = 'Other - type a Windows time zone ID'
    $chosen = Read-Choice -Question 'Time zone for the scaling schedule?' -Options $options
    while ($chosen -eq 'Other') {
        $typed = Read-Text -Question 'Windows time zone ID (for example "Romance Standard Time"; Get-TimeZone -ListAvailable lists them)'
        try {
            $null = [System.TimeZoneInfo]::FindSystemTimeZoneById($typed)
            $chosen = $typed
        } catch {
            Write-Host "'$typed' is not a Windows time zone ID."
        }
    }
    return $chosen
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

function Resolve-EntraGroup {
    param([string]$Value, [Parameter(Mandatory)][string]$Question)

    while ($true) {
        $search = if ($Value) { $Value } else { Read-Text -Question $Question }
        if ($search -match '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$') {
            $group = Get-AzADGroup -ObjectId $search -ErrorAction SilentlyContinue
        } else {
            $found = @(Get-AzADGroup -DisplayNameStartsWith $search -ErrorAction SilentlyContinue | Sort-Object DisplayName | Select-Object -First 15)
            $exact = @($found | Where-Object { $_.DisplayName -eq $search })
            $group = if ($exact.Count -eq 1) { $exact[0] }
            elseif ($found.Count -eq 1) { $found[0] }
            elseif ($found.Count -gt 1) {
                $options = [ordered]@{}
                foreach ($candidate in $found) { $options[[string]$candidate.Id] = "$($candidate.DisplayName) ($($candidate.Id))" }
                $chosen = Read-Choice -Question "Several groups match '$search'. Which one?" -Options $options
                $found | Where-Object { [string]$_.Id -eq $chosen } | Select-Object -First 1
            }
        }
        if ($group) {
            Write-Host "  Using group $($group.DisplayName) ($($group.Id))."
            return [string]$group.Id
        }
        if ($Value) { throw "No Entra group matches '$Value'." }
        Write-Host "No group found starting with '$search'. Try again."
    }
}

function Select-EntraGroup {
    param(
        [string]$Existing,
        [string]$NewName,
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][string]$DefaultName,
        [string]$OwnerObjectId,
        [string]$ExcludeId
    )

    if ($Existing) {
        return [pscustomobject]@{ Id = (Resolve-EntraGroup -Value $Existing -Question "AVD $Role group"); Created = $false }
    }
    $create = if ($NewName) { $true } else {
        (Read-Choice -Question "AVD $Role group?" -Options ([ordered]@{
                Existing = 'Use an existing Entra group'
                New      = 'Create a new Entra security group (you become its owner)'
            })) -eq 'New'
    }
    if (-not $create) {
        return [pscustomobject]@{ Id = (Resolve-EntraGroup -Question "AVD $Role group (name or object ID)"); Created = $false }
    }

    $name = if ($NewName) { $NewName } else { Read-Text -Question "Name for the new AVD $Role group" -Default $DefaultName -Pattern '^[^@"\\/\[\]:|<>+=;,?*]{1,120}$' }
    $sameName = @(Get-AzADGroup -DisplayName $name -ErrorAction SilentlyContinue)
    if ($sameName.Count -gt 0) {
        if ($ExcludeId -and [string]$sameName[0].Id -eq $ExcludeId) { throw "The $Role group must differ from the users group; '$name' is already used." }
        Write-Host "  A group named '$name' already exists; using it ($($sameName[0].Id))."
        return [pscustomobject]@{ Id = [string]$sameName[0].Id; Created = $false }
    }
    $nickname = (($name -replace '[^A-Za-z0-9]', '').ToLowerInvariant() + '-' + (Get-AvdNameSuffix -Seed "$name/$([guid]::NewGuid())"))
    Write-Host "  Creating Entra security group '$name'..."
    $group = New-AzADGroup -DisplayName $name -MailNickname $nickname -SecurityEnabled -Description "Azure Virtual Desktop $Role group created by avd.ps1" -ErrorAction Stop
    if ($OwnerObjectId) {
        try {
            New-AzADGroupOwner -GroupId $group.Id -OwnerId $OwnerObjectId -ErrorAction Stop | Out-Null
        } catch {
            Write-Host "  Warning: could not make you an owner of '$name'; add an owner who will manage its membership."
        }
    }
    Write-Host "  Created $name ($($group.Id))."
    return [pscustomobject]@{ Id = [string]$group.Id; Created = $true }
}

function Resolve-StorageAccountName {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Configuration)

    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        $name = (New-AvdResourceNames -Prefix $Configuration.target.prefix -SubscriptionId $Configuration.subscriptionId -ResourceGroupName $Configuration.target.resourceGroupName -Attempt $attempt).storageAccount
        $owned = Get-AzResource -ResourceGroupName $Configuration.target.resourceGroupName -Name $name -ResourceType 'Microsoft.Storage/storageAccounts' -ErrorAction SilentlyContinue
        if ($owned -or (Test-AvdNameAvailable -SubscriptionId $Configuration.subscriptionId -Provider 'Microsoft.Storage' -Type 'Microsoft.Storage/storageAccounts' -Name $name)) {
            Write-Host "  FSLogix storage account: $name"
            return $name
        }
    }
    throw 'Could not find an available storage account name; set storage.accountName manually.'
}

function Invoke-AzureDiscovery {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Configuration)

    Assert-AvdAzureTooling
    if (-not (Get-AzContext)) {
        Write-Host 'Signing in to Azure...'
        Connect-AzAccount | Out-Null
    }
    $current = Get-AzContext

    # Subscription
    $subscriptions = @(Get-AzSubscription -ErrorAction Stop -WarningAction SilentlyContinue | Where-Object { $_.State -eq 'Enabled' } | Sort-Object Name)
    if ($subscriptions.Count -eq 0) { throw 'No enabled Azure subscriptions are visible to this account.' }
    $subscription = if ($script:SubscriptionId) {
        $subscriptions | Where-Object { $_.Id -eq $script:SubscriptionId -or $_.Name -eq $script:SubscriptionId } | Select-Object -First 1
    } elseif ($subscriptions.Count -eq 1) {
        $subscriptions[0]
    } else {
        $options = [ordered]@{}
        foreach ($candidate in @($subscriptions | Sort-Object { $_.Id -ne $current.Subscription.Id }, Name)) { $options[$candidate.Id] = "$($candidate.Name) ($($candidate.Id))" }
        $chosen = Read-Choice -Question 'Which subscription should AVD be deployed to?' -Options $options
        $subscriptions | Where-Object { $_.Id -eq $chosen } | Select-Object -First 1
    }
    if (-not $subscription) { throw "Subscription '$($script:SubscriptionId)' was not found or is not enabled." }
    Set-AzContext -Tenant $subscription.TenantId -Subscription $subscription.Id | Out-Null
    $Configuration.tenantId = [string]$subscription.TenantId
    $Configuration.subscriptionId = [string]$subscription.Id
    Write-Host "  Subscription: $($subscription.Name) ($($subscription.Id)), tenant $($subscription.TenantId)"

    # Region (AVD host pool metadata regions)
    $regions = @(Get-AvdHostPoolRegions)
    if ($regions.Count -eq 0) { throw 'Could not read the Azure Virtual Desktop regions for this subscription.' }
    $location = if ($script:Location) {
        if ($script:Location -notin @($regions | ForEach-Object { $_.Name })) { throw "Region '$($script:Location)' does not support AVD host pools." }
        $script:Location
    } else {
        $preferred = @($Configuration.target.location, 'uksouth') | Where-Object { $_ -in @($regions | ForEach-Object { $_.Name }) } | Select-Object -First 1
        $options = [ordered]@{}
        foreach ($region in @($regions | Sort-Object { $_.Name -ne $preferred }, DisplayName)) { $options[$region.Name] = "$($region.DisplayName) ($($region.Name))" }
        Read-Choice -Question 'Which Azure region?' -Options $options
    }
    $Configuration.target.location = $location

    # Prefix and resource group
    $prefixValue = if ($script:Prefix) { $script:Prefix } else { Read-Text -Question 'Short prefix for AVD resource names (letters, digits, hyphens; max 10)' -Default $Configuration.target.prefix -Pattern '^[A-Za-z][A-Za-z0-9-]{0,9}$' }
    $Configuration.target.prefix = $prefixValue
    $cleanPrefix = ($prefixValue -replace '[^A-Za-z0-9]', '')
    $Configuration.sessionHosts.namePrefix = ($cleanPrefix.ToUpperInvariant() + 'SH').Substring(0, [Math]::Min(11, $cleanPrefix.Length + 2))
    $groupName = if ($script:ResourceGroupName) { $script:ResourceGroupName } else { Read-Text -Question 'Resource group (created if it does not exist)' -Default "rg-$($cleanPrefix.ToLowerInvariant())-avd" -Pattern '^[A-Za-z0-9._()\-]{1,90}$' }
    $existingGroup = Get-AzResourceGroup -Name $groupName -ErrorAction SilentlyContinue
    if ($existingGroup -and $existingGroup.Location -ne $location) {
        throw "Resource group '$groupName' already exists in '$($existingGroup.Location)'. Choose that region or another resource group name."
    }
    $Configuration.target.resourceGroupName = $groupName
    Write-Host "  Resource group: $groupName ($(if ($existingGroup) { 'existing' } else { 'will be created' }))"

    # Key Vault and deployment identity names
    $names = $null
    for ($attempt = 0; $attempt -lt 5 -and -not $names; $attempt++) {
        $candidate = New-AvdResourceNames -Prefix $prefixValue -SubscriptionId $Configuration.subscriptionId -ResourceGroupName $groupName -Attempt $attempt
        $ownVault = if ($existingGroup) { Get-AzKeyVault -VaultName $candidate.keyVault -ResourceGroupName $groupName -ErrorAction SilentlyContinue }
        $deleted = Get-AzKeyVault -VaultName $candidate.keyVault -Location $location -InRemovedState -ErrorAction SilentlyContinue
        if ($ownVault -or (-not $deleted -and (Test-AvdNameAvailable -SubscriptionId $Configuration.subscriptionId -Provider 'Microsoft.KeyVault' -Type 'Microsoft.KeyVault/vaults' -Name $candidate.keyVault))) {
            $names = $candidate
        }
    }
    if (-not $names) { throw 'Could not find an available Key Vault name; set foundation.keyVault.name manually.' }
    $foundation = [ordered]@{ createResourceGroup = $true }

    # Network
    $allNetworks = @(Get-AzVirtualNetwork -ErrorAction SilentlyContinue)
    $regionalNetworks = @($allNetworks | Where-Object { $_.Location -eq $location })
    $mode = if ($script:NetworkMode) { $script:NetworkMode } elseif ($regionalNetworks.Count -eq 0) { 'New' } else {
        Read-Choice -Question 'Network for the session hosts?' -Options ([ordered]@{
                New      = 'Create a new VNet with NAT gateway (recommended for a self-contained or test deployment)'
                Existing = 'Use an existing VNet in this region'
            })
    }
    if ($mode -eq 'New') {
        $existingPrefixes = @($allNetworks | ForEach-Object { $_.AddressSpace.AddressPrefixes })
        $proposed = Get-AvdFreeAddressSpace -ExistingPrefixes $existingPrefixes
        $space = if ($script:AddressSpace) { $script:AddressSpace } else { Read-Text -Question 'Address space for the new VNet (/16 to /24, private range, no overlap)' -Default $proposed -Pattern '^\d+\.\d+\.\d+\.0/(1[6-9]|2[0-4])$' }
        while (-not (Test-AvdCidrAligned -Cidr $space)) {
            if ($script:AddressSpace) { throw "Address space '$space' is not a network boundary for its prefix length (for example 10.200.0.0/16, not 10.200.1.0/16)." }
            Write-Host "'$space' is not a network boundary for its prefix length (for example 10.200.0.0/16, not 10.200.1.0/16)."
            $space = Read-Text -Question 'Address space for the new VNet' -Default $proposed -Pattern '^\d+\.\d+\.\d+\.0/(1[6-9]|2[0-4])$'
        }
        foreach ($network in $allNetworks) {
            foreach ($prefixRange in @($network.AddressSpace.AddressPrefixes)) {
                if (Test-AvdCidrOverlap -First $space -Second $prefixRange) {
                    Write-Host "  Warning: $space overlaps $($network.Name) ($prefixRange). That only matters if the networks will ever be peered or connected."
                }
            }
        }
        $Configuration.network = [ordered]@{
            resourceGroupName         = $groupName
            virtualNetworkName        = $names.virtualNetwork
            privateEndpointSubnetName = $names.privateEndpointSubnet
            sessionHostSubnetName     = $names.sessionHostSubnet
            deployPrivateDns          = $true
            dnsServers                = @()
        }
        $foundation.network = [ordered]@{ addressSpace = $space }
        Write-Host "  Network: new $($names.virtualNetwork) $space with NAT gateway"
    } else {
        $vnet = if ($script:VirtualNetworkName) {
            $regionalNetworks | Where-Object { $_.Name -eq $script:VirtualNetworkName } | Select-Object -First 1
        } else {
            $options = [ordered]@{}
            foreach ($candidate in $regionalNetworks) { $options[$candidate.Id] = "$($candidate.Name) ($($candidate.ResourceGroupName), $(@($candidate.AddressSpace.AddressPrefixes) -join ', '))" }
            $chosen = Read-Choice -Question 'Which VNet?' -Options $options
            $regionalNetworks | Where-Object { $_.Id -eq $chosen } | Select-Object -First 1
        }
        if (-not $vnet) { throw "VNet '$($script:VirtualNetworkName)' was not found in $location." }
        $subnetNames = @($vnet.Subnets | ForEach-Object { $_.Name })
        $pickSubnet = {
            param([string]$Supplied, [string]$Question)
            if ($Supplied) {
                if ($Supplied -notin $subnetNames) { throw "Subnet '$Supplied' was not found in $($vnet.Name)." }
                return $Supplied
            }
            $options = [ordered]@{}
            foreach ($subnetName in $subnetNames) { $options[$subnetName] = $subnetName }
            Read-Choice -Question $Question -Options $options
        }
        $hostSubnet = & $pickSubnet $script:SessionHostSubnet 'Subnet for session hosts?'
        $endpointSubnet = & $pickSubnet $script:PrivateEndpointSubnet 'Subnet for the storage private endpoint?'
        $dnsServers = @(if ($vnet.DhcpOptions -and $vnet.DhcpOptions.DnsServers) { $vnet.DhcpOptions.DnsServers | Select-Object -First 2 })
        $Configuration.network = [ordered]@{
            resourceGroupName         = $vnet.ResourceGroupName
            virtualNetworkName        = $vnet.Name
            privateEndpointSubnetName = $endpointSubnet
            sessionHostSubnetName     = $hostSubnet
            deployPrivateDns          = $true
            dnsServers                = $dnsServers
        }
        Write-Host "  Network: existing $($vnet.Name) (hosts: $hostSubnet, private endpoint: $endpointSubnet). Make sure it has outbound internet access."
    }

    # Entra groups (existing or newly created) and the AVD service principal
    $operator = Get-AvdOperator -Context (Get-AzContext)
    $groupBase = "sg-$($cleanPrefix.ToLowerInvariant())-avd"
    $usersGroupChoice = Select-EntraGroup -Existing $script:UsersGroup -NewName $script:NewUsersGroup -Role 'users' -DefaultName "$groupBase-users" -OwnerObjectId $operator.ObjectId
    $Configuration.accessGroups.usersObjectId = $usersGroupChoice.Id
    if ($usersGroupChoice.Created -and $operator.ObjectId) {
        $addMe = if ($script:AddMeToUsersGroup) { $true } elseif ($script:NewUsersGroup) { $false } else {
            (Read-Choice -Question 'Add your account to the new users group so you can test sign-in?' -Options ([ordered]@{ Yes = 'Yes'; No = 'No' })) -eq 'Yes'
        }
        if ($addMe) {
            Add-AzADGroupMember -TargetGroupObjectId $usersGroupChoice.Id -MemberObjectId @($operator.ObjectId) -ErrorAction Stop -WarningAction SilentlyContinue
            Write-Host '  Added you to the users group.'
        }
    }
    do {
        $adminsChoice = Select-EntraGroup -Existing $script:AdminsGroup -NewName $script:NewAdminsGroup -Role 'admins' -DefaultName "$groupBase-admins" -OwnerObjectId $operator.ObjectId -ExcludeId $Configuration.accessGroups.usersObjectId
        if ($adminsChoice.Id -eq $Configuration.accessGroups.usersObjectId) {
            if ($script:AdminsGroup -or $script:NewAdminsGroup) { throw 'The AVD admins group must differ from the users group.' }
            Write-Host 'The admins group must differ from the users group.'
        }
    } while ($adminsChoice.Id -eq $Configuration.accessGroups.usersObjectId)
    $Configuration.accessGroups.adminsObjectId = $adminsChoice.Id
    $Configuration.identity.avdServicePrincipalObjectId = Get-AvdServicePrincipalObjectId

    # Key Vault, admin password secret, deployment identity and release-pinned prep script
    $foundation.keyVault = [ordered]@{ name = $names.keyVault }
    $foundation.deploymentIdentity = [ordered]@{ name = $names.deploymentIdentity }
    $Configuration.sessionHosts.adminPasswordSecretUri = "https://$($names.keyVault).vault.azure.net/secrets/$($names.secretName)"
    $Configuration.execution = [ordered]@{
        deploymentIdentityResourceId = "/subscriptions/$($Configuration.subscriptionId)/resourceGroups/$groupName/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$($names.deploymentIdentity)"
    }
    $pinned = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'contracts/artifacts.json'))) -AsHashtable
    $Configuration.artifacts = [ordered]@{ sessionHostPrepUri = $pinned.sessionHostPrep.uri; sessionHostPrepSha256 = $pinned.sessionHostPrep.sha256 }
    $Configuration.foundation = $foundation
    Write-Host "  Key Vault: $($names.keyVault) (admin password generated at deploy), deployment identity: $($names.deploymentIdentity)"
    return [pscustomobject]@{ Names = $names }
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
    $discovery = if (-not $script:Offline) { Invoke-AzureDiscovery -Configuration $configuration }

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
    $configuration.schemaVersion = if ($discovery) { '1.4.0' } else { '1.3.0' }
    $configuration.Remove('assignments')
    $configuration.workload = [ordered]@{
        hosting            = $answers.hosting
        persona            = $answers.persona
        users              = $answers.users
        peakConcurrencyPct = $answers.peakConcurrencyPct
    }
    $configuration.hostPool = $recommendation.hostPool
    $configuration.sessionHosts.count = $recommendation.sessionHosts.count
    $configuration.sessionHosts.vmSize = if ($script:WebVmSize) { $script:WebVmSize } elseif ($script:VmSize) { $script:VmSize } else { $recommendation.sessionHosts.vmSize }

    if ($discovery -and $identityChoice) {
        $configuration.storage = [ordered]@{ accountName = (Resolve-StorageAccountName -Configuration $configuration) }
        if ($identityChoice -eq 'Hybrid') {
            $domainName = if ($script:KerberosDomainName) { $script:KerberosDomainName } else {
                Read-Text -Question 'On-premises AD domain name (Get-ADDomain DNSRoot)' -Default $(if ($configuration.identity.ContainsKey('kerberosDomainName') -and $configuration.identity.kerberosDomainName -notlike '*.invalid') { $configuration.identity.kerberosDomainName } else { '' }) -Pattern '^([A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$'
            }
            $domainGuid = if ($script:KerberosDomainGuid) { $script:KerberosDomainGuid } else {
                Read-Text -Question 'On-premises AD domain GUID (Get-ADDomain ObjectGUID)' -Pattern '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'
            }
            $configuration.identity.kerberosDomainName = $domainName
            $configuration.identity.kerberosDomainGuid = $domainGuid
        }
    }

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
            Write-Host 'Before users sign in, the storage account''s Entra app needs admin consent, the cloud group SID tag and private-link'
            Write-Host 'identifier URIs, an exclusion from MFA Conditional Access, and folder permissions. -Mode Deploy -PostDeploy (or -Mode PostDeploy) does this.'
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
        $selectedTimeZone = if ($script:TimeZone) { $script:TimeZone } else { Read-TimeZone -Default $defaultTimeZone -Region $configuration.target.location }
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

    if ($discovery) {
        $prefix = $configuration.target.prefix
        $namePattern = '^[^\x00-\x1f<>]{1,64}$'
        $workspaceName = if ($script:WorkspaceName) { $script:WorkspaceName } else { Read-Text -Question 'Workspace name users see (the heading in Windows App)' -Default "$prefix Workspace" -Pattern $namePattern }
        $desktopName = if ($script:DesktopName) { $script:DesktopName } else { Read-Text -Question 'Desktop name users see (the desktop tile)' -Default "$prefix Virtual Desktop" -Pattern $namePattern }
        foreach ($name in $workspaceName, $desktopName) {
            if ($name -notmatch $namePattern) { throw "Display name '$name' must be 1-64 characters without < or >." }
        }
        $configuration.display = [ordered]@{ workspaceName = $workspaceName; desktopName = $desktopName }
        if ($identityChoice) {
            $failure = if ($script:ProfileFailureAction) { $script:ProfileFailureAction } else {
                Read-Choice -Question 'If a user''s FSLogix profile cannot load, what should happen?' -Options ([ordered]@{
                        TempProfile = 'Sign in with a temporary profile (changes are lost at sign-out)'
                        Block       = 'Block the sign-in so the problem is visible (recommended once the pilot works)'
                    })
            }
            $configuration.fslogix = [ordered]@{ preventTempProfile = ($failure -eq 'Block') }
        } else {
            $configuration.Remove('fslogix')
        }
        $configuration.schemaVersion = '1.5.0'
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

    if ($Configuration.ContainsKey('foundation')) {
        $foundation = $Configuration.foundation
        $parts = @(
            if ($foundation.createResourceGroup) { "resource group $($Configuration.target.resourceGroupName) ($($Configuration.target.location))" }
            if ($foundation.ContainsKey('network')) { "VNet $($Configuration.network.virtualNetworkName) $($foundation.network.addressSpace) with NAT gateway" }
            if ($foundation.ContainsKey('keyVault')) { "Key Vault $($foundation.keyVault.name) with generated admin password" }
            if ($foundation.ContainsKey('deploymentIdentity')) { "deployment identity $($foundation.deploymentIdentity.name)" }
        )
        Write-Output "Foundation (created by Deploy if missing): $($parts -join '; ')."
    }

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
            Write-Output "Profiles: FSLogix on Azure Files '$($Configuration.storage.accountName)' for cloud-only identities - Microsoft PREVIEW. Prerequisites (automated by -Mode PostDeploy): storage app admin consent, cloud group SID manifest tag, private-link identifier URIs, Conditional Access MFA exclusion, folder permissions."
        }
        'LocalProfile' {
            Write-Output 'Profiles: local on each dedicated VM (no FSLogix or storage account), like Windows 365.'
        }
    }
    if ($Configuration.ContainsKey('fslogix') -and $Configuration.fslogix.ContainsKey('preventTempProfile')) {
        Write-Output "FSLogix: $(if ($Configuration.fslogix.preventTempProfile) { 'sign-in is blocked if the profile cannot attach' } else { 'a temporary profile is used if the profile cannot attach (changes are lost)' })."
    }
    if ($Configuration.ContainsKey('display')) {
        $workspaceShown = if ($Configuration.display.ContainsKey('workspaceName')) { $Configuration.display.workspaceName } else { "$($Configuration.target.prefix) Workspace" }
        $desktopShown = if ($Configuration.display.ContainsKey('desktopName')) { $Configuration.display.desktopName } else { 'SessionDesktop' }
        Write-Output "Users see: workspace '$workspaceShown', desktop '$desktopShown'."
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

function ConvertTo-WebJson {
    param($Value)
    return (ConvertTo-Json -InputObject $Value -Depth 10 -Compress)
}

function Invoke-WebGenerate {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Answers, [Parameter(Mandatory)][string]$Destination)

    # Map wizard answers onto the same parameters New uses, then run it without prompts.
    $text = { param($Name) if ($Answers.Contains($Name) -and $null -ne $Answers[$Name]) { [string]$Answers[$Name] } else { '' } }
    foreach ($name in 'SubscriptionId', 'Location', 'Prefix', 'ResourceGroupName', 'NetworkMode', 'Hosting', 'Persona', 'ScalingPreset', 'WorkdayStart', 'WorkdayEnd', 'UserIdentity', 'WorkspaceName', 'DesktopName', 'ProfileFailureAction') {
        $value = & $text $name
        if ($value) { Set-Variable -Scope Script -Name $name -Value $value }
    }
    foreach ($name in 'AddressSpace', 'VirtualNetworkName', 'SessionHostSubnet', 'PrivateEndpointSubnet', 'UsersGroup', 'AdminsGroup', 'NewUsersGroup', 'NewAdminsGroup', 'KerberosDomainName', 'KerberosDomainGuid', 'TimeZone') {
        Set-Variable -Scope Script -Name $name -Value (& $text $name)
    }
    $vmSizeAnswer = & $text 'VmSize'
    if ($vmSizeAnswer -and $vmSizeAnswer -notmatch '^Standard_[A-Za-z0-9_]{1,55}$') { throw "VM size '$vmSizeAnswer' is not a valid Azure VM size name." }
    $script:WebVmSize = $vmSizeAnswer
    $script:Users = [int]$Answers['Users']
    $script:PeakConcurrencyPct = if ($Answers['Hosting'] -eq 'Dedicated') { 100 } else { [int]$Answers['PeakConcurrencyPct'] }
    $script:AddMeToUsersGroup = [switch][bool]$Answers['AddMeToUsersGroup']
    $script:Force = [switch][bool]$Answers['Overwrite']
    $script:Offline = [switch]$false

    $log = [System.Collections.Generic.List[string]]::new()
    $path = $null
    $script:NonInteractive = $true
    try {
        foreach ($item in (New-SizedConfiguration -BasePath (Join-Path $PSScriptRoot 'config/avd.example.json') -DestinationPath $Destination 6>&1)) {
            if ($item -is [System.Management.Automation.InformationRecord]) { $log.Add([string]$item.MessageData) } else { $path = [string]$item }
        }
        $configuration = Read-ValidatedConfiguration -Path $path
        $summary = @(Write-ConfigurationSummary -Configuration $configuration)
    } finally {
        $script:NonInteractive = $false
    }
    return [ordered]@{
        path    = $path
        log     = @($log | Where-Object { $_ -and $_.Trim() })
        summary = $summary
        next    = @(
            ".\v2\avd.ps1 -Mode Preview -ConfigurationFile `"$path`"",
            ".\v2\avd.ps1 -Mode Deploy -ConfigurationFile `"$path`" -AsSignedInUser -PostDeploy"
        )
    }
}

function Invoke-WebPreview {
    param([Parameter(Mandatory)][string]$Destination)

    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) { throw 'Create the configuration first.' }
    $configuration = Read-ValidatedConfiguration -Path $Destination
    $planPath = [System.IO.Path]::ChangeExtension($Destination, '.plan.json')
    $log = [System.Collections.Generic.List[string]]::new()
    $preview = $null
    # Write-Host progress arrives on the information stream; the what-if tables still print in the PowerShell window.
    foreach ($item in (Invoke-AvdPreview -Configuration $configuration -ConfigurationPath $Destination -PlanPath $planPath 6>&1)) {
        if ($item -is [System.Management.Automation.InformationRecord]) { if ([string]$item.MessageData) { $log.Add([string]$item.MessageData) } }
        elseif ($item.PSObject.Properties['PlanFile']) { $preview = $item }
    }
    if (-not $preview) { throw 'Preview did not return a result.' }
    $plan = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($preview.PlanFile)) -AsHashtable -Depth 10
    $ready = $preview.Blockers.Count -eq 0
    return [ordered]@{
        ready    = $ready
        planFile = $preview.PlanFile
        expires  = [string]$plan.expiresUtc
        summary  = [string]$preview.Changes
        changes  = @($plan.changes | ForEach-Object { [ordered]@{ stage = $_.stage; changeType = $_.changeType; resource = (([string]$_.resourceId) -split '/providers/')[-1] } })
        blockers = @($preview.Blockers)
        warnings = @($preview.Warnings)
        log      = @($log)
        next     = if ($ready) { ".\v2\avd.ps1 -Mode Deploy -ConfigurationFile `"$Destination`" -AsSignedInUser -PostDeploy" } else { '' }
    }
}

function Invoke-WebApi {
    param([Parameter(Mandatory)][string]$Method, [Parameter(Mandatory)][string]$Route, [System.Collections.Specialized.NameValueCollection]$Query, [System.Collections.IDictionary]$Body, [string]$Destination)

    switch ("$Method $Route") {
        'GET /api/context' {
            $context = Get-AzContext
            return [ordered]@{ account = [string]$context.Account.Id; subscriptionId = [string]$context.Subscription.Id; tenantId = [string]$context.Tenant.Id; outputFile = $Destination; outputExists = (Test-Path -LiteralPath $Destination) }
        }
        'GET /api/subscriptions' {
            return @(Get-AzSubscription -WarningAction SilentlyContinue | Where-Object { $_.State -eq 'Enabled' } | Sort-Object Name | ForEach-Object { [ordered]@{ id = [string]$_.Id; name = [string]$_.Name; tenantId = [string]$_.TenantId } })
        }
        'POST /api/subscription' {
            $subscription = Get-AzSubscription -WarningAction SilentlyContinue | Where-Object { $_.Id -eq $Body.id } | Select-Object -First 1
            if (-not $subscription) { throw "Subscription $($Body.id) is not available." }
            Set-AzContext -Tenant $subscription.TenantId -Subscription $subscription.Id | Out-Null
            return [ordered]@{ id = [string]$subscription.Id; tenantId = [string]$subscription.TenantId }
        }
        'GET /api/regions' {
            return @(Get-AvdHostPoolRegions | ForEach-Object { [ordered]@{ name = $_.Name; displayName = $_.DisplayName } })
        }
        'GET /api/resourcegroup' {
            $group = Get-AzResourceGroup -Name $Query['name'] -ErrorAction SilentlyContinue
            return [ordered]@{ exists = [bool]$group; location = if ($group) { [string]$group.Location } else { '' } }
        }
        'GET /api/networks' {
            $all = @(Get-AzVirtualNetwork -ErrorAction SilentlyContinue)
            $prefixes = @($all | ForEach-Object { $_.AddressSpace.AddressPrefixes })
            return [ordered]@{
                proposedAddressSpace = Get-AvdFreeAddressSpace -ExistingPrefixes $prefixes
                existingPrefixes     = $prefixes
                networks             = @($all | Where-Object { $_.Location -eq $Query['region'] } | ForEach-Object {
                        [ordered]@{ name = $_.Name; resourceGroup = $_.ResourceGroupName; addressPrefixes = @($_.AddressSpace.AddressPrefixes); subnets = @($_.Subnets | ForEach-Object { $_.Name }) }
                    })
            }
        }
        'GET /api/groups' {
            $search = [string]$Query['search']
            $groups = if ($search -match '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$') { @(Get-AzADGroup -ObjectId $search -ErrorAction SilentlyContinue) }
            elseif ($search) { @(Get-AzADGroup -DisplayNameStartsWith $search -ErrorAction SilentlyContinue) }
            else { @(Get-AzADGroup -First 25 -ErrorAction SilentlyContinue) }
            return @($groups | Sort-Object DisplayName | Select-Object -First 25 | ForEach-Object { [ordered]@{ id = [string]$_.Id; displayName = [string]$_.DisplayName } })
        }
        'GET /api/timezones' {
            return [ordered]@{
                suggested = Get-SuggestedTimeZone -Region $Query['region']
                zones     = @([System.TimeZoneInfo]::GetSystemTimeZones() | ForEach-Object { [ordered]@{ id = $_.Id; displayName = $_.DisplayName } })
            }
        }
        'GET /api/personas' {
            $sizing = Get-AvdSizingProfile
            return @('Frontline', 'Standard', 'Heavy' | ForEach-Object { [ordered]@{ id = $_; label = $sizing.personas[$_].label; description = $sizing.personas[$_].description } })
        }
        'POST /api/sizing' {
            $peak = if ($Body.hosting -eq 'Dedicated') { 100 } else { [int]$Body.peakConcurrencyPct }
            return Get-AvdSizingRecommendation -Hosting $Body.hosting -Persona $Body.persona -Users ([int]$Body.users) -PeakConcurrencyPct $peak
        }
        'POST /api/generate' {
            return Invoke-WebGenerate -Answers $Body -Destination $Destination
        }
        'POST /api/capacity' {
            if ([string]$Body.vmSize -notmatch '^Standard_[A-Za-z0-9_]{1,55}$' -or [string]$Body.location -notmatch '^[a-z0-9]+$') { throw 'A valid region and VM size are required.' }
            $capacity = Test-AvdVmCapacity -SubscriptionId ([string](Get-AzContext).Subscription.Id) -Location $Body.location -VmSize $Body.vmSize -Count ([Math]::Max(1, [int]$Body.count))
            return [ordered]@{ checked = $capacity.Checked; ok = ($capacity.Blockers.Count -eq 0); blockers = @($capacity.Blockers); warnings = @($capacity.Warnings); alternatives = @($capacity.Alternatives) }
        }
        'POST /api/preview' {
            return Invoke-WebPreview -Destination $Destination
        }
        default {
            throw [System.Collections.Generic.KeyNotFoundException]::new("Unknown endpoint $Method $Route")
        }
    }
}

function Send-WebResponse {
    param($Response, [int]$Status, [string]$ContentType, [string]$Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $Response.StatusCode = $Status
    $Response.ContentType = $ContentType
    $Response.Headers['X-Content-Type-Options'] = 'nosniff'
    $Response.Headers['Cache-Control'] = 'no-store'
    $Response.Headers['Content-Security-Policy'] = "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'"
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.OutputStream.Close()
}

function Start-WebWizard {
    param([Parameter(Mandatory)][string]$Destination)

    Assert-AvdAzureTooling
    if (-not (Get-AzContext)) {
        Write-Host 'Signing in to Azure...'
        Connect-AzAccount -WarningAction SilentlyContinue | Out-Null
    }
    $page = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'web/index.html'))
    $token = [System.Convert]::ToHexString([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(24)).ToLowerInvariant()
    $allowedHosts = @("localhost:$Port", "127.0.0.1:$Port")
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add("http://localhost:$Port/")
    $listener.Start()
    $url = "http://localhost:$Port/?token=$token"
    Write-Host "AVD web wizard running at http://localhost:$Port (this window must stay open)."
    Write-Host "Writing configuration to: $Destination"
    if (-not $NoBrowser) { Start-Process $url } else { Write-Host "Open: $url" }
    Write-Output "WEB-READY $url"

    try {
        while ($listener.IsListening) {
            $pending = $listener.GetContextAsync()
            # Poll so Ctrl+C can stop the wizard between requests.
            while (-not $pending.AsyncWaitHandle.WaitOne(500)) { }
            $context = $pending.GetAwaiter().GetResult()
            $request = $context.Request
            $response = $context.Response
            try {
                # Block DNS rebinding and cross-site calls: only this localhost origin with the session token.
                $origin = $request.Headers['Origin']
                if ($request.Headers['Host'] -notin $allowedHosts -or ($origin -and $origin -notin @($allowedHosts | ForEach-Object { "http://$_" }))) {
                    Send-WebResponse -Response $response -Status 403 -ContentType 'text/plain' -Text 'Forbidden'
                    continue
                }
                $route = $request.Url.AbsolutePath
                if ($request.HttpMethod -eq 'GET' -and $route -eq '/') {
                    if ($request.QueryString['token'] -ne $token) {
                        Send-WebResponse -Response $response -Status 403 -ContentType 'text/plain' -Text 'Open the link printed in the PowerShell window.'
                        continue
                    }
                    Send-WebResponse -Response $response -Status 200 -ContentType 'text/html; charset=utf-8' -Text $page
                    continue
                }
                if (-not $route.StartsWith('/api/') -or $request.Headers['X-AVD-Token'] -ne $token) {
                    Send-WebResponse -Response $response -Status 403 -ContentType 'application/json' -Text '{"error":"Forbidden"}'
                    continue
                }
                if ($route -eq '/api/shutdown' -and $request.HttpMethod -eq 'POST') {
                    Send-WebResponse -Response $response -Status 200 -ContentType 'application/json' -Text '{"ok":true}'
                    break
                }
                $body = $null
                if ($request.HttpMethod -eq 'POST') {
                    if ($request.ContentType -notlike 'application/json*') { throw 'Requests must be JSON.' }
                    $reader = [System.IO.StreamReader]::new($request.InputStream, [System.Text.Encoding]::UTF8)
                    $raw = $reader.ReadToEnd()
                    $reader.Dispose()
                    $body = if ($raw) { ConvertFrom-Json -InputObject $raw -AsHashtable -Depth 10 } else { @{} }
                }
                $result = Invoke-WebApi -Method $request.HttpMethod -Route $route -Query $request.QueryString -Body $body -Destination $Destination
                Send-WebResponse -Response $response -Status 200 -ContentType 'application/json' -Text (ConvertTo-WebJson $result)
            } catch {
                $status = if ($_.Exception -is [System.Collections.Generic.KeyNotFoundException]) { 404 } else { 400 }
                try { Send-WebResponse -Response $response -Status $status -ContentType 'application/json' -Text (ConvertTo-WebJson @{ error = $_.Exception.Message }) } catch { }
            }
        }
    } finally {
        $listener.Stop()
        $listener.Close()
        Write-Host 'AVD web wizard stopped.'
    }
}

if ($Mode -eq 'Web') {
    $destination = [System.IO.Path]::GetFullPath($(if ($OutputFile) { $OutputFile } else { Join-Path $PSScriptRoot 'sandbox/avd.json' }))
    Start-WebWizard -Destination $destination
    return
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
    if ($Offline) {
        Write-Output 'Next: replace any example tenant, subscription, network, group, Key Vault and artifact values with your own, then run -Mode Validate and -Mode Build.'
    } else {
        Write-Output "Next: .\v2\avd.ps1 -Mode Preview -ConfigurationFile $ConfigurationFile"
    }
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
        if ($result.DeploymentIdentity) { Write-Output "  Deployment identity client ID: $($result.DeploymentIdentity)" }
        foreach ($sessionHost in $result.SessionHosts) { Write-Output "  Session host: $sessionHost" }
        foreach ($assignment in $result.Assignments) { Write-Output "  Assigned: $assignment" }
        foreach ($member in $result.AddedToUsersGroup) { Write-Output "  In AVD users group: $member" }
        if ($result.DesktopName) { Write-Output "  Desktop name: $($result.DesktopName)" }
        if ($result.Restarted.Count -gt 0) { Write-Output "  Restarting to apply the Kerberos setting: $($result.Restarted -join ', ')" }
        $tasks = @($result.ManualTasks)
        if ($PostDeploy) {
            $post = Invoke-AvdPostDeploy -Configuration $configuration -ConditionalAccess $ConditionalAccess -OperatorPublicIp $OperatorPublicIp
            Write-Output ''
            Write-Output 'Post-deployment configuration:'
            foreach ($item in $post.Done) { Write-Output "  Done: $item" }
            # PostDeploy replaces the generic Entra and FSLogix reminders with what is actually left.
            $tasks = @($tasks | Where-Object { $_ -notmatch 'admin consent to the storage account|authentication for RDP|ordinary \(non-admin\) test user' }) + @($post.Manual) +
                'Sign in as an ordinary (non-admin) test user from the AVD users group and confirm the desktop launches and the profile persists.'
        } else {
            $tasks += "Run .\v2\avd.ps1 -Mode PostDeploy -ConfigurationFile $ConfigurationFile to automate the Microsoft Entra$(if ($configuration.profile -ne 'LocalProfile') { ' and FSLogix storage' }) steps above."
        }
        Write-Output 'Still to do (manual):'
        foreach ($task in $tasks) { Write-Output "  - $task" }
    }
}

if ($Mode -eq 'PostDeploy') {
    if (-not $PSBoundParameters.ContainsKey('ConfigurationFile')) {
        throw 'PostDeploy needs -ConfigurationFile pointing at the saved configuration of the deployed estate.'
    }
    $null = Connect-AvdAzure -TenantId $configuration.tenantId -SubscriptionId $configuration.subscriptionId
    $post = Invoke-AvdPostDeploy -Configuration $configuration -ConditionalAccess $ConditionalAccess -OperatorPublicIp $OperatorPublicIp
    Write-Output ''
    Write-Output 'Post-deployment configuration:'
    foreach ($item in $post.Done) { Write-Output "  Done: $item" }
    Write-Output 'Still to do (manual):'
    foreach ($task in @($post.Manual) + 'Sign in as an ordinary (non-admin) test user from the AVD users group and confirm the desktop launches and the profile persists.') { Write-Output "  - $task" }
}

if ($Mode -eq 'Build') {
    foreach ($templatePath in $templatePaths) {
        Invoke-BicepBuild -TemplatePath $templatePath
        Write-Output "Bicep compiled: $([System.IO.Path]::GetRelativePath($PSScriptRoot, $templatePath))"
    }
}