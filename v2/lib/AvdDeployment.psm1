#requires -Version 7.2
Set-StrictMode -Version Latest

# Azure/Entra orchestration for avd.ps1 -Mode Preview and -Mode Deploy.
# Preview is read-only. Deploy only runs a fresh, blocker-free plan whose hashes still match.

$script:V2Root = Split-Path $PSScriptRoot -Parent
$script:PowerOnOffRoleId = '40c5ff49-9181-41f8-ae61-143b0e78555e'
$script:PlanLifetimeHours = 24
$script:KerberosRestartTag = 'avdv2-kerberos-restart'
$script:RequiredAzCommands = [ordered]@{
    'Az.Accounts'              = @('Get-AzContext', 'Connect-AzAccount', 'Set-AzContext', 'Get-AzSubscription', 'Invoke-AzRestMethod', 'Get-AzAccessToken')
    'Az.Resources'             = @('Get-AzResourceGroup', 'Get-AzResourceGroupDeploymentWhatIfResult', 'New-AzResourceGroupDeployment', 'Test-AzResourceGroupDeployment', 'Get-AzRoleAssignment',
        'New-AzRoleAssignment', 'Remove-AzRoleAssignment', 'Get-AzDeploymentWhatIfResult', 'New-AzDeployment', 'Get-AzResourceProvider', 'Register-AzResourceProvider', 'Get-AzResource', 'Get-AzADUser')
    'Az.Network'               = @('Get-AzVirtualNetwork')
    'Az.DesktopVirtualization' = @('Get-AzWvdHostPool', 'Update-AzWvdHostPool', 'Get-AzWvdHostPoolRegistrationToken', 'Get-AzWvdSessionHost', 'Update-AzWvdSessionHost', 'Update-AzWvdDesktop')
    'Az.KeyVault'              = @('Get-AzKeyVaultSecret', 'Get-AzKeyVault')
}

function Assert-AvdAzureTooling {
    $missing = foreach ($module in $script:RequiredAzCommands.Keys) {
        if (@($script:RequiredAzCommands[$module] | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) }).Count -gt 0) { $module }
    }
    if ($missing) {
        throw "Install the Azure PowerShell modules first: Install-Module $(@($missing) -join ', ') -Scope CurrentUser"
    }
    if (-not (Get-Command bicep -ErrorAction SilentlyContinue)) {
        throw 'Install the Bicep CLI (winget install Microsoft.Bicep) and make bicep available on PATH; Azure PowerShell needs it to deploy .bicep files.'
    }
}

function Connect-AvdAzure {
    param([Parameter(Mandatory)][string]$TenantId, [Parameter(Mandatory)][string]$SubscriptionId)

    $context = Get-AzContext
    if (-not $context -or $context.Tenant.Id -ne $TenantId) {
        Write-Host "Signing in to Azure tenant $TenantId..."
        Connect-AzAccount -Tenant $TenantId -Subscription $SubscriptionId | Out-Null
        $context = Get-AzContext
    }
    if ($context -and $context.Subscription.Id -ne $SubscriptionId) {
        Set-AzContext -Tenant $TenantId -Subscription $SubscriptionId | Out-Null
        $context = Get-AzContext
    }
    if (-not $context -or $context.Tenant.Id -ne $TenantId -or $context.Subscription.Id -ne $SubscriptionId) {
        throw "The Azure context must be tenant $TenantId and subscription $SubscriptionId. Run Connect-AzAccount -Tenant $TenantId -Subscription $SubscriptionId."
    }
    return $context
}

function Get-AvdHostPoolName {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Configuration)
    return "$($Configuration.target.prefix)-HostPool"
}

function Get-AvdPlatformParameters {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Configuration)

    $parameters = @{
        defaultPrefix             = $Configuration.target.prefix
        profile                   = $Configuration.profile
        avdUsersGroupOid          = $Configuration.accessGroups.usersObjectId
        avdAdminsGroupOid         = $Configuration.accessGroups.adminsObjectId
        avdServicePrincipalOid    = $Configuration.identity.avdServicePrincipalObjectId
        vnetResourceGroup         = $Configuration.network.resourceGroupName
        vnetName                  = $Configuration.network.virtualNetworkName
        privateEndpointSubnetName = $Configuration.network.privateEndpointSubnetName
        deployPrivateDns          = [bool]$Configuration.network.deployPrivateDns
    }
    if ($Configuration.Contains('storage')) { $parameters.storageAccountName = $Configuration.storage.accountName }
    if ($Configuration.identity.Contains('kerberosDomainName')) {
        $parameters.kerberosDomainName = $Configuration.identity.kerberosDomainName
        $parameters.kerberosDomainGuid = $Configuration.identity.kerberosDomainGuid
    }
    if ($Configuration.Contains('hostPool')) { $parameters.hostPool = $Configuration.hostPool }
    if ($Configuration.Contains('scaling')) { $parameters.scaling = $Configuration.scaling }
    if ($Configuration.Contains('display') -and $Configuration.display.Contains('workspaceName')) { $parameters.workspaceFriendlyName = $Configuration.display.workspaceName }
    return $parameters
}

function Get-AvdSessionHostParameters {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Configuration,
        [Parameter(Mandatory)][securestring]$AdminPassword,
        [Parameter(Mandatory)][securestring]$RegistrationToken
    )

    $dnsServers = @(if ($Configuration.network.Contains('dnsServers')) { $Configuration.network.dnsServers })
    $parameters = @{
        sessionHostPrefix             = $Configuration.sessionHosts.namePrefix
        hostPoolName                  = Get-AvdHostPoolName -Configuration $Configuration
        vmSize                        = $Configuration.sessionHosts.vmSize
        numberOfHosts                 = [int]$Configuration.sessionHosts.count
        adminUsername                 = $Configuration.sessionHosts.adminUsername
        adminPassword                 = $AdminPassword
        hostPoolRegistrationInfoToken = $RegistrationToken
        vNetResourceGroup             = $Configuration.network.resourceGroupName
        vNetName                      = $Configuration.network.virtualNetworkName
        subnetName                    = $Configuration.network.sessionHostSubnetName
        dns1                          = if ($dnsServers.Count -ge 1) { $dnsServers[0] } else { '' }
        dns2                          = if ($dnsServers.Count -ge 2) { $dnsServers[1] } else { '' }
        sessionHostPrepScriptUrl      = $Configuration.artifacts.sessionHostPrepUri
        hostPoolType                  = if ($Configuration.Contains('hostPool')) { $Configuration.hostPool.type } else { 'Pooled' }
        profileMode                   = if ($Configuration.profile -eq 'LocalProfile') { 'Local' } else { 'FSLogix' }
        preventTempProfile            = [bool]($Configuration.Contains('fslogix') -and $Configuration.fslogix.Contains('preventTempProfile') -and $Configuration.fslogix.preventTempProfile)
    }
    if ($Configuration.Contains('storage')) { $parameters.storageAccountName = $Configuration.storage.accountName }
    return $parameters
}

function Get-AvdSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-AvdSecretReference {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Configuration)
    $match = [regex]::Match($Configuration.sessionHosts.adminPasswordSecretUri, '^https://(?<vault>[^.]+)\.vault\.azure\.net/secrets/(?<name>[^/?#]+)(?:/(?<version>[^/?#]+))?$')
    return [pscustomobject]@{
        VaultName = $match.Groups['vault'].Value
        Name      = $match.Groups['name'].Value
        Version   = if ($match.Groups['version'].Success) { $match.Groups['version'].Value } else { $null }
    }
}

function New-AvdAdminPassword {
    # 24 characters from a cryptographic RNG with every character class; never written to output or disk.
    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!#%*+-=?@^_')
    $all = -join $sets
    $characters = [System.Collections.Generic.List[char]]::new()
    foreach ($set in $sets) { $characters.Add($set[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($set.Length)]) }
    while ($characters.Count -lt 24) { $characters.Add($all[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($all.Length)]) }
    for ($index = $characters.Count - 1; $index -gt 0; $index--) {
        $swap = [System.Security.Cryptography.RandomNumberGenerator]::GetInt32($index + 1)
        $current = $characters[$index]; $characters[$index] = $characters[$swap]; $characters[$swap] = $current
    }
    $secure = [securestring]::new()
    foreach ($character in $characters) { $secure.AppendChar($character) }
    $characters.Clear()
    $secure.MakeReadOnly()
    return $secure
}

function Test-AvdAutoscaleRole {
    # Present, Missing or Unknown (when the caller cannot read role assignments).
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Configuration)
    $scope = "/subscriptions/$($Configuration.subscriptionId)"
    try {
        $assignments = @(Get-AzRoleAssignment -ObjectId $Configuration.identity.avdServicePrincipalObjectId -Scope $scope -ErrorAction Stop |
                Where-Object { $_.RoleDefinitionId -match $script:PowerOnOffRoleId -and $_.Scope -eq $scope })
        if ($assignments.Count -gt 0) { return 'Present' }
        return 'Missing'
    } catch {
        return 'Unknown'
    }
}

function Get-AvdFoundationState {
    # Which foundation pieces are missing; only these are deployed, so existing resources are never re-PUT.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Configuration)

    $foundation = $Configuration.foundation
    $resourceGroupName = $Configuration.target.resourceGroupName
    $groupExists = [bool](Get-AzResourceGroup -Name $resourceGroupName -ErrorAction SilentlyContinue)
    $state = [ordered]@{ ResourceGroup = $false; Network = $false; KeyVault = $false; Secret = $false; Identity = $false; AutoscaleRole = $false }
    if ($Configuration.Contains('scaling')) {
        $state.AutoscaleRole = (Test-AvdAutoscaleRole -Configuration $Configuration) -eq 'Missing'
    }
    $state.ResourceGroup = [bool]$foundation.createResourceGroup -and -not $groupExists
    if ($foundation.Contains('network')) {
        $state.Network = -not ($groupExists -and (Get-AzVirtualNetwork -ResourceGroupName $resourceGroupName -Name $Configuration.network.virtualNetworkName -ErrorAction SilentlyContinue))
    }
    if ($foundation.Contains('keyVault')) {
        $vaultExists = $groupExists -and [bool](Get-AzKeyVault -VaultName $foundation.keyVault.name -ResourceGroupName $resourceGroupName -ErrorAction SilentlyContinue)
        $state.KeyVault = -not $vaultExists
        $state.Secret = -not ($vaultExists -and (Test-AvdSecretExists -Configuration $Configuration))
    }
    if ($foundation.Contains('deploymentIdentity')) {
        $state.Identity = -not ($groupExists -and (Get-AzResource -ResourceId $Configuration.execution.deploymentIdentityResourceId -ErrorAction SilentlyContinue))
    }
    $missing = @($state.Keys | Where-Object { $state[$_] })
    return [pscustomobject]@{ Missing = $missing; ResourceGroup = $state.ResourceGroup; Network = $state.Network; KeyVault = $state.KeyVault; Secret = $state.Secret; Identity = $state.Identity; AutoscaleRole = $state.AutoscaleRole }
}

function Get-AvdFoundationParameters {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Configuration,
        [Parameter(Mandatory)]$State,
        [securestring]$AdminPassword,
        [string]$OperatorObjectId = '',
        [string]$OperatorPrincipalType = 'User'
    )

    $foundation = $Configuration.foundation
    $parameters = @{
        resourceGroupName     = $Configuration.target.resourceGroupName
        location              = $Configuration.target.location
        createResourceGroup   = [bool]$State.ResourceGroup
        operatorObjectId      = $OperatorObjectId
        operatorPrincipalType = $OperatorPrincipalType
    }
    if ($foundation.Contains('network') -and $State.Network) {
        $parameters.network = @{
            addressSpace              = $foundation.network.addressSpace
            vnetName                  = $Configuration.network.virtualNetworkName
            sessionHostSubnetName     = $Configuration.network.sessionHostSubnetName
            privateEndpointSubnetName = $Configuration.network.privateEndpointSubnetName
        }
    }
    if ($foundation.Contains('keyVault')) {
        $parameters.keyVault = @{ name = $foundation.keyVault.name; secretName = (Get-AvdSecretReference -Configuration $Configuration).Name; create = [bool]$State.KeyVault }
        if ($AdminPassword -and $State.Secret) { $parameters.adminPassword = $AdminPassword }
    }
    if ($foundation.Contains('deploymentIdentity')) {
        $parameters.deploymentIdentityName = $foundation.deploymentIdentity.name
        $parameters.createDeploymentIdentity = [bool]$State.Identity
    }
    if ($State.AutoscaleRole) {
        $parameters.autoscaleServicePrincipalId = $Configuration.identity.avdServicePrincipalObjectId
    }
    return $parameters
}

function Get-AvdOperator {
    param([Parameter(Mandatory)]$Context)
    if ($Context.Account.Type -ne 'User') {
        return [pscustomobject]@{ ObjectId = ''; PrincipalType = 'ServicePrincipal' }
    }
    try {
        $user = Get-AzADUser -SignedIn -ErrorAction Stop
        return [pscustomobject]@{ ObjectId = [string]$user.Id; PrincipalType = 'User' }
    } catch {
        return [pscustomobject]@{ ObjectId = ''; PrincipalType = 'User' }
    }
}

function Test-AvdSecretExists {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Configuration)
    $reference = Get-AvdSecretReference -Configuration $Configuration
    $secretId = "/subscriptions/$($Configuration.subscriptionId)/resourceGroups/$($Configuration.target.resourceGroupName)/providers/Microsoft.KeyVault/vaults/$($reference.VaultName)/secrets/$($reference.Name)"
    return [bool](Get-AzResource -ResourceId $secretId -ErrorAction SilentlyContinue)
}

function Test-AvdNameAvailable {
    param([Parameter(Mandatory)][string]$SubscriptionId, [Parameter(Mandatory)][string]$Provider, [Parameter(Mandatory)][string]$Type, [Parameter(Mandatory)][string]$Name)
    $apiVersion = if ($Provider -eq 'Microsoft.KeyVault') { '2023-07-01' } else { '2023-05-01' }
    $response = Invoke-AzRestMethod -Method POST -Path "/subscriptions/$SubscriptionId/providers/$Provider/checkNameAvailability?api-version=$apiVersion" -Payload (@{ name = $Name; type = $Type } | ConvertTo-Json)
    if ($response.StatusCode -ne 200) { return $true }
    return [bool]($response.Content | ConvertFrom-Json).nameAvailable
}

function Get-AvdRequiredProviders {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Configuration)
    $providers = [System.Collections.Generic.List[string]]::new()
    foreach ($namespace in 'Microsoft.DesktopVirtualization', 'Microsoft.Compute', 'Microsoft.Network') { $providers.Add($namespace) }
    if ($Configuration.Contains('storage')) { $providers.Add('Microsoft.Storage') }
    if ($Configuration.Contains('foundation')) {
        if ($Configuration.foundation.Contains('keyVault')) { $providers.Add('Microsoft.KeyVault') }
        if ($Configuration.foundation.Contains('deploymentIdentity')) { $providers.Add('Microsoft.ManagedIdentity') }
    }
    return , $providers.ToArray()
}

function Get-AvdProviderState {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Configuration)
    $unregistered = foreach ($namespace in (Get-AvdRequiredProviders -Configuration $Configuration)) {
        $states = @(Get-AzResourceProvider -ProviderNamespace $namespace -ErrorAction SilentlyContinue | ForEach-Object { $_.RegistrationState })
        if ($states -notcontains 'Registered') { $namespace }
    }
    return @($unregistered)
}

function Register-AvdProviders {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Configuration)
    $pending = @(Get-AvdProviderState -Configuration $Configuration)
    if ($pending.Count -eq 0) { return }
    foreach ($namespace in $pending) {
        Write-Host "Registering resource provider $namespace..."
        Register-AzResourceProvider -ProviderNamespace $namespace -ErrorAction Stop | Out-Null
    }
    $deadline = [DateTime]::UtcNow.AddMinutes(10)
    while (@(Get-AvdProviderState -Configuration $Configuration).Count -gt 0) {
        if ([DateTime]::UtcNow -ge $deadline) { throw "Resource providers are still registering: $(@(Get-AvdProviderState -Configuration $Configuration) -join ', '). Rerun Deploy in a few minutes." }
        Start-Sleep -Seconds 15
    }
}

function Get-AvdTemplateHash {
    $infraRoot = Join-Path $script:V2Root 'infra/avd'
    $lines = Get-ChildItem -LiteralPath $infraRoot -Filter '*.bicep' -Recurse -File |
        Sort-Object FullName |
        ForEach-Object { "$([System.IO.Path]::GetRelativePath($infraRoot, $_.FullName).Replace('\', '/')):$(Get-AvdSha256 -Path $_.FullName)" }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))
    return [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Test-AvdArtifactDigest {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Configuration)

    $temporaryFile = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
    try {
        Invoke-WebRequest -Uri $Configuration.artifacts.sessionHostPrepUri -OutFile $temporaryFile -UseBasicParsing | Out-Null
        $actual = Get-AvdSha256 -Path $temporaryFile
        $text = [System.IO.File]::ReadAllText($temporaryFile)
    } catch {
        return [pscustomobject]@{ Ok = $false; Message = "Session host prep script could not be downloaded from $($Configuration.artifacts.sessionHostPrepUri)." }
    } finally {
        Remove-Item -LiteralPath $temporaryFile -Force -ErrorAction SilentlyContinue
    }
    if ($actual -ne $Configuration.artifacts.sessionHostPrepSha256.ToLowerInvariant()) {
        return [pscustomobject]@{ Ok = $false; Message = "Session host prep script SHA-256 is $actual but the configuration expects $($Configuration.artifacts.sessionHostPrepSha256). Publish the reviewed v2/scripts/session-host-prep.ps1 and record its hash." }
    }
    if ($Configuration.Contains('fslogix') -and $Configuration.fslogix.Contains('preventTempProfile') -and $Configuration.fslogix.preventTempProfile -and $text -notmatch '\$PreventTempProfile') {
        return [pscustomobject]@{ Ok = $false; Message = 'fslogix.preventTempProfile needs a newer session host prep script than the one pinned in this configuration. Recreate the configuration with -Mode New (it pins the current release) or set preventTempProfile to false.' }
    }
    return [pscustomobject]@{ Ok = $true; Message = "Session host prep script digest verified ($actual)." }
}

function Get-AvdAdminPassword {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Configuration,
        [ValidateRange(1, 60)]
        [int]$Attempts = 1
    )

    $reference = Get-AvdSecretReference -Configuration $Configuration
    $arguments = @{ VaultName = $reference.VaultName; Name = $reference.Name; ErrorAction = 'Stop' }
    if ($reference.Version) { $arguments.Version = $reference.Version }
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            $secret = Get-AzKeyVaultSecret @arguments
            if ($secret -and $secret.SecretValue) { return $secret.SecretValue }
        } catch {
            # A role assignment made moments ago by the foundation stage can take a few minutes to apply.
        }
        if ($attempt -lt $Attempts) {
            Write-Host "Waiting for Key Vault access to apply (attempt $attempt of $Attempts)..."
            Start-Sleep -Seconds 30
        }
    }
    throw "The session host admin password could not be read from Key Vault secret '$($reference.Name)' in '$($reference.VaultName)'. Check the secret exists and you have Key Vault Secrets User."
}

function Add-AvdWhatIfChanges {
    # PSWhatIfChange exposes FullyQualifiedResourceId; conditional resources arrive separately as PotentialChanges.
    param([Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Changes, [Parameter(Mandatory)][string]$Stage, $Result)
    if (-not $Result) { return }
    foreach ($property in 'Changes', 'PotentialChanges') {
        if (-not $Result.PSObject.Properties[$property]) { continue }
        foreach ($change in @($Result.$property)) {
            if (-not $change) { continue }
            $type = [string]$change.ChangeType
            $Changes.Add([ordered]@{
                    stage      = $Stage
                    resourceId = [string]$change.FullyQualifiedResourceId
                    changeType = if ($property -eq 'PotentialChanges') { "Potential$type" } else { $type }
                })
        }
    }
}

function Format-AvdDeploymentError {
    # Flatten Azure validation errors (Code/Message/Details) so the real cause is visible, not just "see inner errors".
    param($Errors, [int]$Depth = 0)
    foreach ($item in @($Errors)) {
        if (-not $item) { continue }
        $code = if ($item.PSObject.Properties['Code']) { $item.Code } else { '' }
        $message = if ($item.PSObject.Properties['Message']) { $item.Message } else { [string]$item }
        "$('  ' * $Depth)- $(if ($code) { "[$code] " })$message"
        if ($item.PSObject.Properties['Details'] -and $item.Details) { Format-AvdDeploymentError -Errors $item.Details -Depth ($Depth + 1) }
    }
}

function Get-AvdComputeCapacity {
    # VM size availability and vCPU quota for the hosts this run would add. Returns blockers and warnings.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Configuration, [bool]$ResourceGroupExists)

    $blockers = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $alternatives = [System.Collections.Generic.List[string]]::new()
    $checked = $false
    $location = $Configuration.target.location
    $size = $Configuration.sessionHosts.vmSize
    $subscription = $Configuration.subscriptionId
    try {
        $skuResponse = Invoke-AzRestMethod -Method GET -Path "/subscriptions/$subscription/providers/Microsoft.Compute/skus?api-version=2021-07-01&`$filter=location%20eq%20'$location'"
        $usageResponse = Invoke-AzRestMethod -Method GET -Path "/subscriptions/$subscription/providers/Microsoft.Compute/locations/$location/usages?api-version=2023-07-01"
        if ($skuResponse.StatusCode -ne 200 -or $usageResponse.StatusCode -ne 200) { throw 'Compute capacity APIs did not return 200.' }
        $vmSkus = @(($skuResponse.Content | ConvertFrom-Json).value | Where-Object { $_.resourceType -eq 'virtualMachines' })
        $usages = @(($usageResponse.Content | ConvertFrom-Json).value)
        $checked = $true
        $capability = { param($s, $name) $c = @($s.capabilities | Where-Object { $_.name -eq $name }) | Select-Object -First 1; if ($c) { [string]$c.value } }
        $freeQuota = { param($key) $u = $usages | Where-Object { $_.name.value -eq $key } | Select-Object -First 1; if ($u) { [int]$u.limit - [int]$u.currentValue } }

        $existing = 0
        if ($ResourceGroupExists) {
            $pattern = '^' + [regex]::Escape($Configuration.sessionHosts.namePrefix) + '-\d+$'
            $existing = @(Get-AzResource -ResourceGroupName $Configuration.target.resourceGroupName -ResourceType 'Microsoft.Compute/virtualMachines' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $pattern }).Count
        }
        $newHosts = [Math]::Max(0, [int]$Configuration.sessionHosts.count - $existing)

        $sku = $vmSkus | Where-Object { $_.name -eq $size } | Select-Object -First 1
        $targetVcpus = if ($sku) { [int](& $capability $sku 'vCPUs') } else { [int]([regex]::Match($size, '^Standard_[A-Z]+(\d+)').Groups[1].Value) }

        # Alternatives must suit the template: general-purpose D-series, Gen2 image, Trusted Launch, premium disks, unrestricted, with quota.
        $findAlternatives = {
            $total = & $freeQuota 'cores'
            $names = @($vmSkus | Where-Object {
                    $_.name -ne $size -and $_.name -match '^Standard_D\d+[a-z]*s_v\d+$' -and
                    [int](& $capability $_ 'vCPUs') -eq $targetVcpus -and
                    (& $capability $_ 'HyperVGenerations') -match 'V2' -and
                    (& $capability $_ 'TrustedLaunchDisabled') -ne 'True' -and
                    (& $capability $_ 'PremiumIO') -eq 'True' -and
                    @($_.restrictions | Where-Object { $_.type -eq 'Location' -and $_.reasonCode -eq 'NotAvailableForSubscription' }).Count -eq 0
                } | Where-Object {
                    $familyFree = & $freeQuota $_.family
                    $need = $newHosts * $targetVcpus
                    ($null -eq $familyFree -or $familyFree -ge $need) -and ($null -eq $total -or $total -ge $need)
                } | Sort-Object { [int]([regex]::Match($_.name, '_v(\d+)$').Groups[1].Value) } -Descending | Select-Object -ExpandProperty name -Unique -First 5)
            $alternatives.Clear()
            foreach ($name in $names) { $alternatives.Add($name) }
        }
        $suggest = {
            & $findAlternatives
            if ($alternatives.Count -gt 0) { " Available $targetVcpus-vCPU sizes with enough quota: $($alternatives -join ', ')." }
            else { " No other $targetVcpus-vCPU D-series size is available with enough quota; try a smaller size or request a quota increase." }
        }

        if (-not $sku) {
            $blockers.Add("VM size $size is not offered in $location. Choose another size (sessionHosts.vmSize).$(& $suggest)")
            return [pscustomobject]@{ Blockers = $blockers; Warnings = $warnings; Alternatives = @($alternatives); Checked = $checked }
        }
        $restricted = @($sku.restrictions | Where-Object { $_.type -eq 'Location' -and $_.reasonCode -eq 'NotAvailableForSubscription' })
        if ($restricted.Count -gt 0) {
            $blockers.Add("VM size $size is restricted for this subscription in $location. Request access or choose another size (sessionHosts.vmSize).$(& $suggest)")
            return [pscustomobject]@{ Blockers = $blockers; Warnings = $warnings; Alternatives = @($alternatives); Checked = $checked }
        }
        $needed = $newHosts * $targetVcpus
        if ($needed -gt 0) {
            $short = $false
            foreach ($quota in @(
                    @{ Key = $sku.family; Label = "$($sku.family) vCPUs" },
                    @{ Key = 'cores'; Label = 'Total regional vCPUs' })) {
                $usage = $usages | Where-Object { $_.name.value -eq $quota.Key } | Select-Object -First 1
                if ($usage) {
                    $free = [int]$usage.limit - [int]$usage.currentValue
                    if ($free -lt $needed) {
                        $blockers.Add("Not enough quota for $newHosts x $size in ${location}: $($quota.Label) needs $needed, $free free (limit $($usage.limit)). Request a quota increase, use a smaller size, or reduce sessionHosts.count.")
                        $short = $true
                    }
                }
            }
            if ($short) { $blockers.Add("Alternatives for sessionHosts.vmSize:$(& $suggest)") }
        }
    } catch {
        $warnings.Add("Could not check VM size availability and vCPU quota for $size in $location. Deploy validates the session hosts before creating them.")
    }
    return [pscustomobject]@{ Blockers = $blockers; Warnings = $warnings; Alternatives = @($alternatives); Checked = $checked }
}

function Test-AvdVmCapacity {
    # Wizard-time check of one VM size before a configuration exists (new estate, so every host is new).
    param([Parameter(Mandatory)][string]$SubscriptionId, [Parameter(Mandatory)][string]$Location, [Parameter(Mandatory)][string]$VmSize, [Parameter(Mandatory)][int]$Count)
    $configuration = [ordered]@{
        subscriptionId = $SubscriptionId
        target         = [ordered]@{ location = $Location; resourceGroupName = '' }
        sessionHosts   = [ordered]@{ vmSize = $VmSize; count = $Count; namePrefix = 'probe' }
    }
    return Get-AvdComputeCapacity -Configuration $configuration -ResourceGroupExists $false
}

function New-AvdPlaceholderSecret {
    # What-if never deploys, so preview uses throwaway values rather than reading secrets.
    return ConvertTo-SecureString "Pv!$([guid]::NewGuid().ToString('N'))Aa1" -AsPlainText -Force
}

function Get-AvdRegisteredHosts {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Configuration)
    $hostPoolName = Get-AvdHostPoolName -Configuration $Configuration
    foreach ($sessionHost in @(Get-AzWvdSessionHost -ResourceGroupName $Configuration.target.resourceGroupName -HostPoolName $hostPoolName)) {
        $fullName = ($sessionHost.Name -split '/')[-1]
        [pscustomobject]@{
            ComputerName = $fullName.Split('.')[0]
            Name         = $fullName
            AssignedUser = if ($sessionHost.PSObject.Properties['AssignedUser']) { [string]$sessionHost.AssignedUser } else { '' }
            Status       = if ($sessionHost.PSObject.Properties['Status']) { [string]$sessionHost.Status } else { '' }
        }
    }
}

function Set-AvdDesktopName {
    # ARM templates cannot set the SessionDesktop friendly name; PATCH it after the app group exists.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Configuration)
    if (-not ($Configuration.Contains('display') -and $Configuration.display.Contains('desktopName'))) { return [pscustomobject]@{ Name = ''; Manual = '' } }
    $name = $Configuration.display.desktopName
    $appGroup = "$($Configuration.target.prefix)-AppGroup"
    try {
        Update-AzWvdDesktop -ResourceGroupName $Configuration.target.resourceGroupName -ApplicationGroupName $appGroup -Name 'SessionDesktop' -FriendlyName $name -ErrorAction Stop | Out-Null
        Write-Host "Desktop name set to '$name'."
        return [pscustomobject]@{ Name = $name; Manual = '' }
    } catch {
        return [pscustomobject]@{ Name = ''; Manual = "Set the desktop name: Update-AzWvdDesktop -ResourceGroupName $($Configuration.target.resourceGroupName) -ApplicationGroupName $appGroup -Name SessionDesktop -FriendlyName '$name' ($($_.Exception.Message))" }
    }
}

function Get-AvdManualTasks {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Configuration)

    $tasks = [System.Collections.Generic.List[string]]::new()
    $tasks.Add('Enable Microsoft Entra authentication for RDP once per tenant (Entra ID > Devices > Remote connection configuration > Windows Cloud Login); the hosts use Entra single sign-on.')
    switch ($Configuration.profile) {
        'AzureFilesHybridKerberos' {
            $tasks.Add('Grant admin consent to the storage account''s Entra app, add its private-link identifier URIs, exclude it from MFA Conditional Access, and set FSLogix share/folder ACLs from a machine that can reach a domain controller.')
        }
        'AzureFilesEntraKerberosCloudOnly' {
            $tasks.Add('PREVIEW cloud-only FSLogix: grant admin consent to the storage account''s Entra app, add the cloud group SID manifest tag and private-link identifier URIs, exclude only that app from MFA Conditional Access, and set folder permissions (see ADR 0011).')
        }
    }
    if (-not $Configuration.network.deployPrivateDns) {
        $tasks.Add('Custom DNS: make sure the storage private endpoint resolves (forward privatelink.file.core.windows.net to Azure DNS or add records).')
    }
    $tasks.Add('Sign in as an ordinary (non-admin) test user from the AVD users group and confirm the desktop launches and the profile persists.')
    return , $tasks
}

function Invoke-AvdPreview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Configuration,
        [Parameter(Mandatory)][string]$ConfigurationPath,
        [Parameter(Mandatory)][string]$PlanPath
    )

    Assert-AvdAzureTooling
    $context = Connect-AvdAzure -TenantId $Configuration.tenantId -SubscriptionId $Configuration.subscriptionId
    $resourceGroupName = $Configuration.target.resourceGroupName
    $hostPoolName = Get-AvdHostPoolName -Configuration $Configuration
    $blockers = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $changes = [System.Collections.Generic.List[object]]::new()

    Write-Host "Preview as $($context.Account.Id) in subscription $($Configuration.subscriptionId). No changes will be made."
    $foundation = if ($Configuration.Contains('foundation')) { $Configuration.foundation } else { $null }
    $createsNetwork = $foundation -and $foundation.Contains('network')
    $createsKeyVault = $foundation -and $foundation.Contains('keyVault')

    $unregistered = @(Get-AvdProviderState -Configuration $Configuration)
    if ($unregistered.Count -gt 0) {
        if ($context.Account.Type -eq 'ManagedService') {
            $blockers.Add("Resource providers not registered: $($unregistered -join ', '). Ask a subscription administrator to register them.")
        } else {
            $warnings.Add("Resource providers not registered yet: $($unregistered -join ', '). Deploy registers them (needs subscription-level rights).")
        }
    }

    $resourceGroup = Get-AzResourceGroup -Name $resourceGroupName -ErrorAction SilentlyContinue
    if (-not $resourceGroup) {
        if ($foundation -and $foundation.createResourceGroup) {
            Write-Host "Resource group '$resourceGroupName' will be created in $($Configuration.target.location)."
        } else {
            $blockers.Add("Resource group '$resourceGroupName' does not exist. Create it, or set foundation.createResourceGroup (avd.ps1 -Mode New does this).")
        }
    } elseif ($resourceGroup.Location -ne $Configuration.target.location) {
        $blockers.Add("Resource group '$resourceGroupName' is in '$($resourceGroup.Location)' but the configuration says '$($Configuration.target.location)'.")
    }

    $network = $Configuration.network
    $virtualNetwork = if ($resourceGroup -or $network.resourceGroupName -ne $resourceGroupName) {
        Get-AzVirtualNetwork -ResourceGroupName $network.resourceGroupName -Name $network.virtualNetworkName -ErrorAction SilentlyContinue
    }
    if (-not $virtualNetwork -and -not $createsNetwork) {
        $blockers.Add("Virtual network '$($network.virtualNetworkName)' was not found in resource group '$($network.resourceGroupName)'.")
    } elseif ($virtualNetwork) {
        $subnetNames = @($virtualNetwork.Subnets | ForEach-Object { $_.Name })
        foreach ($subnet in @($network.sessionHostSubnetName, $network.privateEndpointSubnetName) | Select-Object -Unique) {
            if ($subnet -notin $subnetNames) {
                $blockers.Add("Subnet '$subnet' was not found in virtual network '$($network.virtualNetworkName)'.")
            }
        }
    }

    if ($createsKeyVault) {
        $vaultName = $foundation.keyVault.name
        $ownVault = if ($resourceGroup) { Get-AzKeyVault -VaultName $vaultName -ResourceGroupName $resourceGroupName -ErrorAction SilentlyContinue }
        if (-not $ownVault) {
            if (Get-AzKeyVault -VaultName $vaultName -Location $Configuration.target.location -InRemovedState -ErrorAction SilentlyContinue) {
                $blockers.Add("Key Vault name '$vaultName' belongs to a soft-deleted vault. Purge it (Remove-AzKeyVault -VaultName $vaultName -Location $($Configuration.target.location) -InRemovedState) or choose another name.")
            } elseif (-not (Test-AvdNameAvailable -SubscriptionId $Configuration.subscriptionId -Provider 'Microsoft.KeyVault' -Type 'Microsoft.KeyVault/vaults' -Name $vaultName)) {
                $blockers.Add("Key Vault name '$vaultName' is already taken. Choose another name in foundation.keyVault.name and sessionHosts.adminPasswordSecretUri.")
            }
        }
    }
    if ($Configuration.Contains('storage')) {
        $accountName = $Configuration.storage.accountName
        $ownAccount = if ($resourceGroup) { Get-AzResource -ResourceGroupName $resourceGroupName -Name $accountName -ResourceType 'Microsoft.Storage/storageAccounts' -ErrorAction SilentlyContinue }
        if (-not $ownAccount -and -not (Test-AvdNameAvailable -SubscriptionId $Configuration.subscriptionId -Provider 'Microsoft.Storage' -Type 'Microsoft.Storage/storageAccounts' -Name $accountName)) {
            $blockers.Add("Storage account name '$accountName' is already taken. Choose another globally unique storage.accountName.")
        }
    }

    $artifact = Test-AvdArtifactDigest -Configuration $Configuration
    if ($artifact.Ok) { Write-Host $artifact.Message } else { $blockers.Add($artifact.Message) }

    if ($Configuration.Contains('scaling')) {
        # AVD refuses to create a scaling plan until its service principal has this role, so a missing role is not just a warning.
        switch (Test-AvdAutoscaleRole -Configuration $Configuration) {
            'Missing' {
                if ($foundation -and $context.Account.Type -ne 'ManagedService') {
                    Write-Host "The foundation will grant 'Desktop Virtualization Power On Off Contributor' to the Azure Virtual Desktop service principal at subscription scope (required before the scaling plan can be created)."
                } else {
                    $blockers.Add("Autoscale prerequisite missing: assign 'Desktop Virtualization Power On Off Contributor' to the Azure Virtual Desktop service principal ($($Configuration.identity.avdServicePrincipalObjectId)) at /subscriptions/$($Configuration.subscriptionId). AVD rejects the scaling plan without it. Or remove 'scaling' from the configuration.")
                }
            }
            'Unknown' {
                $warnings.Add("Could not read role assignments to check the autoscale prerequisite. AVD rejects the scaling plan unless 'Desktop Virtualization Power On Off Contributor' is assigned to its service principal at subscription scope.")
            }
        }
    }

    if ($Configuration.profile -eq 'AzureFilesEntraKerberosCloudOnly') {
        $warnings.Add('Cloud-only FSLogix is a Microsoft PREVIEW feature and needs the admin prerequisites in ADR 0011.')
    }
    if ($Configuration.Contains('display')) {
        $shownWorkspace = if ($Configuration.display.Contains('workspaceName')) { $Configuration.display.workspaceName } else { "$($Configuration.target.prefix) Workspace" }
        $shownDesktop = if ($Configuration.display.Contains('desktopName')) { $Configuration.display.desktopName } else { 'SessionDesktop' }
        Write-Host "Users will see workspace '$shownWorkspace' with desktop '$shownDesktop' (Deploy sets the desktop name after the platform; what-if cannot show it)."
    }

    $capacity = Get-AvdComputeCapacity -Configuration $Configuration -ResourceGroupExists ([bool]$resourceGroup)
    foreach ($item in $capacity.Blockers) { $blockers.Add($item) }
    foreach ($item in $capacity.Warnings) { $warnings.Add($item) }

    if ($blockers.Count -eq 0 -and $foundation) {
        $foundationState = Get-AvdFoundationState -Configuration $Configuration
        if ($foundationState.Missing.Count -eq 0) {
            Write-Host 'Foundation: resource group, network, Key Vault, secret, identity and autoscale role already in place; nothing to create.'
        } elseif ($context.Account.Type -eq 'ManagedService') {
            $blockers.Add("Foundation resources are missing ($($foundationState.Missing -join ', ')). Create them once as an operator: -Mode Deploy -AsSignedInUser.")
        } else {
            Write-Host ''
            Write-Host "What-if: foundation - creating only what is missing: $($foundationState.Missing -join ', ')"
            $operator = Get-AvdOperator -Context $context
            $previewPassword = if ($foundationState.Secret) { New-AvdPlaceholderSecret }
            $foundationParameters = Get-AvdFoundationParameters -Configuration $Configuration -State $foundationState -AdminPassword $previewPassword -OperatorObjectId $operator.ObjectId -OperatorPrincipalType $operator.PrincipalType
            $foundationResult = Get-AzDeploymentWhatIfResult -Location $Configuration.target.location -TemplateFile (Join-Path $script:V2Root 'infra/avd/foundation.bicep') -TemplateParameterObject $foundationParameters -ErrorAction Stop
            $foundationResult | Out-Host
            Add-AvdWhatIfChanges -Changes $changes -Stage 'foundation' -Result $foundationResult
        }
    }

    # The platform can only be previewed once its resource group and network exist.
    if ($blockers.Count -eq 0 -and $resourceGroup -and ($virtualNetwork -or -not $createsNetwork)) {
        Write-Host "What-if: platform ($hostPoolName, app group, workspace$(if ($Configuration.profile -ne 'LocalProfile') { ', FSLogix storage' })$(if ($Configuration.Contains('scaling')) { ', scaling plan' }))"
        $platformResult = Get-AzResourceGroupDeploymentWhatIfResult -ResourceGroupName $resourceGroupName -TemplateFile (Join-Path $script:V2Root 'infra/avd/platform.bicep') -TemplateParameterObject (Get-AvdPlatformParameters -Configuration $Configuration) -ErrorAction Stop
        $platformResult | Out-Host
        Add-AvdWhatIfChanges -Changes $changes -Stage 'platform' -Result $platformResult

        $existingPool = Get-AzWvdHostPool -ResourceGroupName $resourceGroupName -Name $hostPoolName -ErrorAction SilentlyContinue
        if ($existingPool) {
            Write-Host "What-if: $($Configuration.sessionHosts.count) session host(s)"
            $hostParameters = Get-AvdSessionHostParameters -Configuration $Configuration -AdminPassword (New-AvdPlaceholderSecret) -RegistrationToken (New-AvdPlaceholderSecret)
            $hostResult = Get-AzResourceGroupDeploymentWhatIfResult -ResourceGroupName $resourceGroupName -TemplateFile (Join-Path $script:V2Root 'infra/avd/session-hosts.bicep') -TemplateParameterObject $hostParameters -ErrorAction Stop
            $hostResult | Out-Host
            Add-AvdWhatIfChanges -Changes $changes -Stage 'sessionHosts' -Result $hostResult
        } else {
            $warnings.Add("Host pool '$hostPoolName' does not exist yet, so the session-host stage cannot be previewed in Azure. Deploy creates the platform first, then $($Configuration.sessionHosts.count) host(s) named $($Configuration.sessionHosts.namePrefix)-0 onward.")
        }
    } elseif ($blockers.Count -eq 0) {
        $warnings.Add("The platform and session hosts can be previewed in Azure only after the foundation creates the resource group$(if ($createsNetwork) { ' and network' }). Deploy runs the foundation first, then $hostPoolName and $($Configuration.sessionHosts.count) host(s) named $($Configuration.sessionHosts.namePrefix)-0 onward.")
    }

    $assignments = @(if ($Configuration.Contains('assignments')) { $Configuration.assignments })
    $now = [DateTime]::UtcNow
    $plan = [ordered]@{
        planVersion      = '1.0.0'
        createdUtc       = $now.ToString('o')
        expiresUtc       = $now.AddHours($script:PlanLifetimeHours).ToString('o')
        createdBy        = [string]$context.Account.Id
        tenantId         = $Configuration.tenantId
        subscriptionId   = $Configuration.subscriptionId
        resourceGroup    = $resourceGroupName
        configurationSha = Get-AvdSha256 -Path $ConfigurationPath
        templateSha      = Get-AvdTemplateHash
        artifactSha      = $Configuration.artifacts.sessionHostPrepSha256.ToLowerInvariant()
        sessionHosts     = [ordered]@{ count = [int]$Configuration.sessionHosts.count; vmSize = $Configuration.sessionHosts.vmSize }
        assignments      = @($assignments | ForEach-Object { [ordered]@{ host = "$($Configuration.sessionHosts.namePrefix)-$($_.hostIndex)"; userPrincipalName = $_.userPrincipalName; objectId = $_.objectId } })
        changes          = @($changes)
        blockers         = @($blockers)
        warnings         = @($warnings)
    }
    [System.IO.File]::WriteAllText([System.IO.Path]::GetFullPath($PlanPath), ($plan | ConvertTo-Json -Depth 8) + [Environment]::NewLine)

    $counts = @($changes | Group-Object { $_.changeType } | ForEach-Object { "$($_.Name): $($_.Count)" }) -join ', '
    [pscustomobject]@{
        PlanFile = [System.IO.Path]::GetFullPath($PlanPath)
        Changes  = if ($counts) { $counts } else { 'not evaluated' }
        Blockers = @($blockers)
        Warnings = @($warnings)
    }
}

function Assert-AvdPlan {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Configuration,
        [Parameter(Mandatory)][string]$ConfigurationPath,
        [Parameter(Mandatory)][string]$PlanPath
    )

    if (-not (Test-Path -LiteralPath $PlanPath -PathType Leaf)) {
        throw "No plan found at $PlanPath. Run -Mode Preview first."
    }
    $plan = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($PlanPath)) -AsHashtable -Depth 8
    if (@($plan.blockers).Count -gt 0) {
        throw "The plan has blockers. Fix them and run -Mode Preview again:`n - $(@($plan.blockers) -join "`n - ")"
    }
    $expires = $plan.expiresUtc
    if ($expires -isnot [datetime]) {
        $expires = [DateTime]::Parse([string]$expires, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
    }
    if ($expires.ToUniversalTime() -lt [DateTime]::UtcNow) {
        throw 'The plan has expired. Run -Mode Preview again.'
    }
    if ($plan.tenantId -ne $Configuration.tenantId -or $plan.subscriptionId -ne $Configuration.subscriptionId -or $plan.resourceGroup -ne $Configuration.target.resourceGroupName) {
        throw 'The plan was created for a different tenant, subscription or resource group.'
    }
    if ($plan.configurationSha -ne (Get-AvdSha256 -Path $ConfigurationPath)) {
        throw 'The configuration changed after the plan was created. Run -Mode Preview again.'
    }
    if ($plan.templateSha -ne (Get-AvdTemplateHash)) {
        throw 'The V2 Bicep templates changed after the plan was created. Run -Mode Preview again.'
    }
    return $plan
}

function Add-AvdGroupMembers {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Configuration,
        [Parameter(Mandatory)][object[]]$Assignments
    )

    $groupId = $Configuration.accessGroups.usersObjectId
    $manual = [System.Collections.Generic.List[string]]::new()
    $added = [System.Collections.Generic.List[string]]::new()
    $requiredScope = 'GroupMember.ReadWrite.All'

    if (-not (Get-Command Get-MgContext -ErrorAction SilentlyContinue)) {
        foreach ($assignment in $Assignments) { $manual.Add("Add $($assignment.userPrincipalName) to AVD users group $groupId (Microsoft.Graph.Authentication is not installed).") }
        return [pscustomobject]@{ Added = $added; Manual = $manual }
    }
    $context = Get-MgContext
    if (-not $context -or $context.TenantId -ne $Configuration.tenantId -or @($context.Scopes) -notcontains $requiredScope) {
        Write-Host "Signing in to Microsoft Graph for tenant $($Configuration.tenantId) to add dedicated users to the AVD users group (delegated $requiredScope)..."
        try {
            Connect-MgGraph -TenantId $Configuration.tenantId -Scopes 'User.ReadBasic.All', $requiredScope -NoWelcome | Out-Null
            $context = Get-MgContext
        } catch {
            $context = $null
        }
    }
    if (-not $context -or $context.TenantId -ne $Configuration.tenantId) {
        foreach ($assignment in $Assignments) { $manual.Add("Add $($assignment.userPrincipalName) to AVD users group $groupId (no delegated Graph session for the configured tenant).") }
        return [pscustomobject]@{ Added = $added; Manual = $manual }
    }

    foreach ($assignment in $Assignments) {
        $body = @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$($assignment.objectId)" }
        try {
            Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/groups/$groupId/members/`$ref" -Body $body -ErrorAction Stop | Out-Null
            $added.Add($assignment.userPrincipalName)
        } catch {
            # Graph SDK puts the service error body in ErrorDetails; the exception message is only the HTTP status line.
            $detail = "$($_.ErrorDetails.Message) $($_.Exception.Message)"
            if ($detail -match 'already exist') {
                $added.Add($assignment.userPrincipalName)
            } else {
                # Delegated denial is reported, never retried with another identity.
                $manual.Add("Add $($assignment.userPrincipalName) to AVD users group $groupId (your account could not change this group's membership).")
            }
        }
    }
    return [pscustomobject]@{ Added = $added; Manual = $manual }
}

function Invoke-AvdDeploy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Configuration,
        [Parameter(Mandatory)][string]$ConfigurationPath,
        [Parameter(Mandatory)][string]$PlanPath,
        [string]$Approve,
        [switch]$AsSignedInUser,
        [ValidateRange(0, 60)]
        [int]$RegistrationWaitMinutes = 10
    )

    Assert-AvdAzureTooling
    $context = Connect-AvdAzure -TenantId $Configuration.tenantId -SubscriptionId $Configuration.subscriptionId
    $plan = Assert-AvdPlan -Configuration $Configuration -ConfigurationPath $ConfigurationPath -PlanPath $PlanPath
    $resourceGroupName = $Configuration.target.resourceGroupName
    $hostPoolName = Get-AvdHostPoolName -Configuration $Configuration

    if ($context.Account.Type -ne 'ManagedService' -and -not $AsSignedInUser) {
        throw "Deploy normally runs as the deployment managed identity. To deploy as $($context.Account.Id) (sandbox or local testing), add -AsSignedInUser."
    }

    Write-Host "Plan created $($plan.createdUtc) by $($plan.createdBy): $(@($plan.changes).Count) previewed change(s), $($plan.sessionHosts.count) x $($plan.sessionHosts.vmSize)."
    foreach ($warning in @($plan.warnings)) { Write-Host "  Warning: $warning" }
    $approval = if ($Approve) { $Approve } else { Read-Host "Type the resource group name '$resourceGroupName' to deploy this plan" }
    if ($approval -ne $resourceGroupName) {
        throw 'Deployment not approved. Nothing was changed.'
    }

    $artifact = Test-AvdArtifactDigest -Configuration $Configuration
    if (-not $artifact.Ok) { throw $artifact.Message }
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddHHmmss')
    $runsAsIdentity = $context.Account.Type -eq 'ManagedService'
    $unregistered = @(Get-AvdProviderState -Configuration $Configuration)
    if ($unregistered.Count -gt 0) {
        if ($runsAsIdentity) { throw "Resource providers not registered: $($unregistered -join ', '). Ask a subscription administrator to register them." }
        Register-AvdProviders -Configuration $Configuration
    }

    $adminPassword = $null
    $foundationResult = $null
    $foundationRan = $false
    if ($Configuration.Contains('foundation')) {
        $foundationState = Get-AvdFoundationState -Configuration $Configuration
        if ($foundationState.Missing.Count -eq 0) {
            Write-Host 'Foundation already in place; skipping it so existing resources are left unchanged.'
        } elseif ($runsAsIdentity) {
            throw "Foundation resources are missing ($($foundationState.Missing -join ', ')). Create them once as an operator: -Mode Deploy -AsSignedInUser."
        } else {
            if ($foundationState.Secret) {
                # Generated once, held only in memory, stored by the foundation and used directly for this run's hosts.
                $adminPassword = New-AvdAdminPassword
                Write-Host 'Generated a new session host admin password; it will be stored only in Key Vault.'
            }
            $operator = Get-AvdOperator -Context $context
            Write-Host "Deploying foundation (creating: $($foundationState.Missing -join ', '))..."
            $foundationParameters = Get-AvdFoundationParameters -Configuration $Configuration -State $foundationState -AdminPassword $adminPassword -OperatorObjectId $operator.ObjectId -OperatorPrincipalType $operator.PrincipalType
            $foundationResult = New-AzDeployment -Name "avdv2-foundation-$stamp" -Location $Configuration.target.location -TemplateFile (Join-Path $script:V2Root 'infra/avd/foundation.bicep') -TemplateParameterObject $foundationParameters -ErrorAction Stop
            if ($foundationResult.ProvisioningState -ne 'Succeeded') {
                throw 'The foundation deployment did not succeed. Nothing else was deployed.'
            }
            $foundationRan = $true
        }
    }
    if (-not $adminPassword) {
        $attempts = if ($foundationRan) { 10 } else { 1 }
        $adminPassword = Get-AvdAdminPassword -Configuration $Configuration -Attempts $attempts
    }

    Write-Host "Deploying AVD platform to $resourceGroupName..."
    # A just-granted autoscale role can take a few minutes to reach AVD; the platform deployment is idempotent, so retry.
    $retryDelay = if ($env:AVDV2_RETRY_DELAY_SECONDS) { [int]$env:AVDV2_RETRY_DELAY_SECONDS } else { 60 }
    for ($attempt = 1; ; $attempt++) {
        try {
            $platform = New-AzResourceGroupDeployment -Name "avdv2-platform-$stamp-$attempt" -ResourceGroupName $resourceGroupName -TemplateFile (Join-Path $script:V2Root 'infra/avd/platform.bicep') -TemplateParameterObject (Get-AvdPlatformParameters -Configuration $Configuration) -ErrorAction Stop
            break
        } catch {
            if ($attempt -ge 6 -or "$($_.Exception.Message)" -notmatch 'unable to access host pool') { throw }
            Write-Host "AVD cannot use its autoscale permission yet (role assignments can take a few minutes); retrying in $retryDelay seconds ($attempt of 5)..."
            Start-Sleep -Seconds $retryDelay
        }
    }
    if ($platform.ProvisioningState -ne 'Succeeded') {
        throw 'The AVD platform deployment did not succeed. Session hosts were not deployed.'
    }
    $manualTasks = [System.Collections.Generic.List[string]]::new()
    $desktopName = Set-AvdDesktopName -Configuration $Configuration
    if ($desktopName.Manual) { $manualTasks.Add($desktopName.Manual) }

    # Hosts whose VM already existed keep running; only new FSLogix hosts are restarted after they register.
    $vmPattern = '^' + [regex]::Escape($Configuration.sessionHosts.namePrefix) + '-\d+$'
    $existingVmResources = @(Get-AzResource -ResourceGroupName $resourceGroupName -ResourceType 'Microsoft.Compute/virtualMachines' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $vmPattern })
    $existingVms = @($existingVmResources | ForEach-Object { $_.Name })
    # Hosts that existed before this run and were never restarted by Deploy (tag missing), e.g. after a failed run.
    $unrestartedVms = @($existingVmResources | Where-Object {
            $tags = if ($_.PSObject.Properties['Tags']) { $_.Tags } else { $null }
            -not ($tags -and $tags.ContainsKey($script:KerberosRestartTag))
        } | ForEach-Object { $_.Name })

    # Validate the session hosts before creating a registration token, and show Azure's nested error details.
    $validationParameters = Get-AvdSessionHostParameters -Configuration $Configuration -AdminPassword $adminPassword -RegistrationToken (New-AvdPlaceholderSecret)
    $validationErrors = @(Test-AzResourceGroupDeployment -ResourceGroupName $resourceGroupName -TemplateFile (Join-Path $script:V2Root 'infra/avd/session-hosts.bicep') -TemplateParameterObject $validationParameters -ErrorAction Stop)
    if ($validationErrors.Count -gt 0) {
        throw "Session host validation failed, so no hosts or registration token were created:`n$((Format-AvdDeploymentError -Errors $validationErrors) -join "`n")"
    }

    # PATCH only the registration info. The New/Remove-AzWvdRegistrationInfo wrappers re-PUT the whole host pool and
    # drop properties such as startVMOnConnect and personalDesktopAssignmentType.
    Write-Host 'Creating a temporary host-pool registration token (4 hours)...'
    try {
        Update-AzWvdHostPool -ResourceGroupName $resourceGroupName -Name $hostPoolName -RegistrationInfoExpirationTime ([DateTime]::UtcNow.AddHours(4)) -RegistrationInfoRegistrationTokenOperation 'Update' -ErrorAction Stop | Out-Null
        $registration = Get-AzWvdHostPoolRegistrationToken -ResourceGroupName $resourceGroupName -HostPoolName $hostPoolName -ErrorAction Stop
        if (-not $registration -or [string]::IsNullOrWhiteSpace($registration.Token)) {
            throw 'Azure did not return a host-pool registration token.'
        }
        $hostParameters = Get-AvdSessionHostParameters -Configuration $Configuration -AdminPassword $adminPassword -RegistrationToken (ConvertTo-SecureString $registration.Token -AsPlainText -Force)
        $registration = $null
        Write-Host "Deploying $($Configuration.sessionHosts.count) session host(s)..."
        $hosts = New-AzResourceGroupDeployment -Name "avdv2-hosts-$stamp" -ResourceGroupName $resourceGroupName -TemplateFile (Join-Path $script:V2Root 'infra/avd/session-hosts.bicep') -TemplateParameterObject $hostParameters -ErrorAction Stop
        if ($hosts.ProvisioningState -ne 'Succeeded') {
            throw 'The session-host deployment did not succeed.'
        }
    } finally {
        Update-AzWvdHostPool -ResourceGroupName $resourceGroupName -Name $hostPoolName -RegistrationInfoRegistrationTokenOperation 'Delete' -ErrorAction Stop | Out-Null
        Write-Host 'Registration token revoked.'
    }

    $expected = @(0..($Configuration.sessionHosts.count - 1) | ForEach-Object { "$($Configuration.sessionHosts.namePrefix)-$_" })
    $deadline = [DateTime]::UtcNow.AddMinutes($RegistrationWaitMinutes)
    do {
        $registered = @(Get-AvdRegisteredHosts -Configuration $Configuration)
        $missing = @($expected | Where-Object { $_ -notin @($registered | ForEach-Object { $_.ComputerName }) })
        if ($missing.Count -eq 0 -or [DateTime]::UtcNow -ge $deadline) { break }
        Write-Host "Waiting for $($missing.Count) host(s) to register..."
        Start-Sleep -Seconds 30
    } while ($true)
    if ($missing.Count -gt 0) {
        throw "VMs deployed but host-pool registration could not be verified for: $($missing -join ', '). Check the DSC extension status and rerun Preview and Deploy."
    }
    Write-Host "All $($expected.Count) session host(s) registered."

    # The Kerberos ticket setting written by host prep needs a restart. Restart VMs this run created and tag them;
    # existing untagged VMs may have users signed in, so they become a manual task instead.
    $restarted = [System.Collections.Generic.List[string]]::new()
    if ($Configuration.profile -ne 'LocalProfile') {
        $vmRoot = "/subscriptions/$($Configuration.subscriptionId)/resourceGroups/$resourceGroupName/providers/Microsoft.Compute/virtualMachines"
        foreach ($vmName in @($expected | Where-Object { $_ -notin $existingVms })) {
            $restart = Invoke-AzRestMethod -Method POST -Path "$vmRoot/$vmName/restart?api-version=2024-03-01"
            if ($restart.StatusCode -in 200, 202) {
                $restarted.Add($vmName)
                $tagBody = @{ operation = 'Merge'; properties = @{ tags = @{ $script:KerberosRestartTag = [DateTime]::UtcNow.ToString('o') } } } | ConvertTo-Json -Depth 4
                $null = Invoke-AzRestMethod -Method PATCH -Path "$vmRoot/$vmName/providers/Microsoft.Resources/tags/default?api-version=2021-04-01" -Payload $tagBody
            } else {
                $manualTasks.Add("Restart $vmName once so its Microsoft Entra Kerberos setting applies (automatic restart returned HTTP $($restart.StatusCode)).")
            }
        }
        if ($restarted.Count -gt 0) { Write-Host "Restarting $($restarted -join ', ') so the Microsoft Entra Kerberos setting applies (back in a few minutes)." }
        foreach ($vmName in @($expected | Where-Object { $_ -in $unrestartedVms })) {
            $manualTasks.Add("Restart $vmName once when no one is signed in (no restart is recorded since host prep set the Microsoft Entra Kerberos setting), then tag it $($script:KerberosRestartTag).")
        }
    }

    foreach ($task in (Get-AvdManualTasks -Configuration $Configuration)) { $manualTasks.Add($task) }
    foreach ($warning in @($plan.warnings)) { if ($warning -match 'prerequisite missing') { $manualTasks.Insert(0, $warning) } }
    $assignedHosts = [System.Collections.Generic.List[string]]::new()
    $groupMembers = @()
    $assignments = @(if ($Configuration.Contains('assignments')) { $Configuration.assignments })
    if ($assignments.Count -gt 0) {
        $applied = [System.Collections.Generic.List[object]]::new()
        foreach ($assignment in $assignments) {
            $hostName = "$($Configuration.sessionHosts.namePrefix)-$($assignment.hostIndex)"
            $sessionHost = $registered | Where-Object { $_.ComputerName -eq $hostName } | Select-Object -First 1
            if ($sessionHost.AssignedUser -and $sessionHost.AssignedUser -ine $assignment.userPrincipalName) {
                $manualTasks.Add("$hostName is already assigned to $($sessionHost.AssignedUser); it was not reassigned to $($assignment.userPrincipalName), who was not added to the AVD users group.")
                continue
            }
            if (-not $sessionHost.AssignedUser) {
                Update-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $hostPoolName -Name $sessionHost.Name -AssignedUser $assignment.userPrincipalName -ErrorAction Stop | Out-Null
            }
            $assignedHosts.Add("$hostName -> $($assignment.userPrincipalName)")
            $applied.Add($assignment)
        }
        if ($applied.Count -gt 0) {
            $groupResult = Add-AvdGroupMembers -Configuration $Configuration -Assignments $applied.ToArray()
            $groupMembers = @($groupResult.Added)
            foreach ($task in $groupResult.Manual) { $manualTasks.Insert(0, $task) }
        }
    }

    $identityClientId = ''
    if ($foundationResult -and $foundationResult.Outputs -and $foundationResult.Outputs.ContainsKey('deploymentIdentityClientId')) {
        $identityClientId = [string]$foundationResult.Outputs['deploymentIdentityClientId'].Value
    }
    if ($identityClientId) {
        $manualTasks.Add("Deployment identity created (client ID $identityClientId). It can read the admin password; grant it workload deployment rights through bootstrap before running Deploy as the identity.")
    }

    [pscustomobject]@{
        ResourceGroup      = $resourceGroupName
        HostPool           = $hostPoolName
        DeploymentIdentity = $identityClientId
        SessionHosts       = @($registered | ForEach-Object { "$($_.ComputerName) ($($_.Status))" })
        Restarted          = @($restarted)
        DesktopName        = [string]$desktopName.Name
        Assignments        = @($assignedHosts)
        AddedToUsersGroup  = $groupMembers
        ManualTasks        = @($manualTasks)
    }
}

Export-ModuleMember -Function Invoke-AvdPreview, Invoke-AvdDeploy, Test-AvdVmCapacity, Get-AvdPlatformParameters, Get-AvdSessionHostParameters, Get-AvdFoundationParameters, Get-AvdTemplateHash, New-AvdAdminPassword, Test-AvdNameAvailable, Connect-AvdAzure, Assert-AvdAzureTooling, Get-AvdOperator
