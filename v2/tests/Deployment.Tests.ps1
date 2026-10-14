#requires -Version 7.2
[CmdletBinding()]
param()

# Offline tests for avd.ps1 -Mode Preview / -Mode Deploy. Azure and Graph cmdlets are replaced by
# global mock functions (functions take precedence over cmdlets), so nothing touches a real tenant.

$ErrorActionPreference = 'Stop'
$v2Root = Split-Path $PSScriptRoot -Parent
$cliPath = Join-Path $v2Root 'avd.ps1'
$prepScript = Join-Path $v2Root 'scripts/session-host-prep.ps1'
$prepSha = (Get-FileHash -LiteralPath $prepScript -Algorithm SHA256).Hash.ToLowerInvariant()
$temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
[System.IO.Directory]::CreateDirectory($temporaryDirectory) | Out-Null
$tenantId = '11111111-1111-4111-8111-111111111111'
$subscriptionId = '22222222-2222-4222-8222-222222222222'
$passed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function New-TestConfiguration {
    param([string]$Name, [scriptblock]$Change)
    $configuration = Get-Content -LiteralPath (Join-Path $v2Root 'config/avd.example.json') -Raw | ConvertFrom-Json -AsHashtable
    $configuration.artifacts.sessionHostPrepUri = 'https://artifacts.example.invalid/v2/session-host-prep.ps1'
    $configuration.artifacts.sessionHostPrepSha256 = $prepSha
    if ($Change) { & $Change $configuration }
    $path = Join-Path $temporaryDirectory "$Name.json"
    [System.IO.File]::WriteAllText($path, ($configuration | ConvertTo-Json -Depth 32))
    return $path
}

function Reset-State {
    param([hashtable]$Flags = @{})
    $global:AvdTest = @{
        Calls          = [System.Collections.Generic.List[string]]::new()
        Tenant         = $tenantId
        AccountType    = 'User'
        ExistingPool   = $false
        MissingRg      = $false
        PowerRole      = $true
        PlatformAccessFailures = 0
        PlatformFail   = $false
        HostFail       = $false
        MissingHost    = $false
        HostCount      = 2
        AssignedUsers  = @{}
        GraphScopes    = @('User.ReadBasic.All', 'GroupMember.ReadWrite.All')
        GraphDenied    = $false
        GraphExisting  = @()
        Prefix         = 'AVDHOST'
        PrepScript     = $prepScript
        Unregistered   = @()
        SecretExists   = $false
        TakenNames     = @()
        DeletedVault   = $false
        FoundationDone = $false
        NetworkMissing = $false
        CreatedGroups  = @()
        QuotaLimit     = 100
        MissingVmSize  = ''
        RestrictedSizes = @()
        HostValidationError = $false
        Post           = [System.Collections.Generic.List[string]]::new()
        DesktopRenameFails = $false
        ExistingVms    = @()
        VmTags         = @{}
        Graph          = $null
        FilesForbidden = 0
        StorageState   = @{ properties = @{ publicNetworkAccess = 'Disabled'; networkAcls = @{ defaultAction = 'Deny'; bypass = 'AzureServices'; ipRules = @(); virtualNetworkRules = @() } } }
    }
    $global:AvdTest.Graph = @{
        RdpEnabled = $false
        App        = @{ id = 'app-object'; appId = 'storage-app-id'; tags = @(); identifierUris = @('api://t/HOST/stavd.file.core.windows.net', 'CIFS/stavd.file.core.windows.net') }
        Grant      = $null
        Policies   = @(
            @{ id = 'p-mfa'; displayName = '101 - MFA For All'; state = 'enabled'; grantControls = @{ builtInControls = @('mfa') }
                conditions = @{ applications = @{ includeApplications = @('All'); excludeApplications = @(); includeUserActions = @(); includeAuthenticationContextClassReferences = @() }; users = @{ includeRoles = @() } } },
            @{ id = 'p-managed'; displayName = 'Microsoft-managed: Multifactor authentication and reauthentication for risky sign-ins'; state = 'enabled'; grantControls = @{ builtInControls = @('mfa') }
                conditions = @{ applications = @{ includeApplications = @('All'); excludeApplications = @() }; users = @{ includeRoles = @() } } },
            @{ id = 'p-cpaw'; displayName = 'Priv - Restrict Access to cPAW only'; state = 'enabled'; grantControls = @{ builtInControls = @('block') }
                conditions = @{ applications = @{ includeApplications = @('All'); excludeApplications = @() }; users = @{ includeRoles = @('62e90394-69f5-4237-9190-012177145e10') } } },
            @{ id = 'p-office'; displayName = 'Office only MFA'; state = 'enabled'; grantControls = @{ builtInControls = @('mfa') }
                conditions = @{ applications = @{ includeApplications = @('Office365'); excludeApplications = @() }; users = @{ includeRoles = @() } } }
        )
        Devices    = @{}
        HybridSids = @{}
    }
    foreach ($key in $Flags.Keys) { $global:AvdTest[$key] = $Flags[$key] }
}

function Invoke-Cli {
    param([string[]]$Arguments)
    $named = @{}
    for ($index = 0; $index -lt $Arguments.Count; $index++) {
        $name = $Arguments[$index].TrimStart('-')
        if ($index + 1 -lt $Arguments.Count -and -not $Arguments[$index + 1].StartsWith('-')) {
            $named[$name] = $Arguments[$index + 1]
            $index++
        } else {
            $named[$name] = $true
        }
    }
    $caughtError = $null
    $output = $null
    try {
        $output = (& $cliPath @named 6>&1 | Out-String)
    } catch {
        $caughtError = $_.Exception.Message
    }
    return [pscustomobject]@{ Output = [string]$output; Error = $caughtError; Calls = ($global:AvdTest.Calls -join ',') }
}

function Write-Pass {
    param([string]$Message)
    $script:passed++
    Write-Host "PASS: $Message"
}

# --- Mocks -------------------------------------------------------------------------------------
function global:Get-AzContext {
    [pscustomobject]@{
        Tenant       = [pscustomobject]@{ Id = $global:AvdTest.Tenant }
        Subscription = [pscustomobject]@{ Id = '22222222-2222-4222-8222-222222222222' }
        Account      = [pscustomobject]@{ Id = 'tester@example.com'; Type = $global:AvdTest.AccountType }
    }
}
function global:Connect-AzAccount { param($Tenant, $Subscription) $global:AvdTest.Calls.Add('connect-azure'); $global:AvdTest.Tenant = $Tenant }
function global:Set-AzContext { param($Tenant, $Subscription) }
function global:Get-AzResourceGroup {
    param($Name, $ErrorAction)
    if (-not $global:AvdTest.MissingRg -or $global:AvdTest.FoundationDone) { [pscustomobject]@{ ResourceGroupName = $Name; Location = 'uksouth' } }
}
function global:Get-AzVirtualNetwork {
    param($ResourceGroupName, $Name, $ErrorAction)
    $subnets = @('session-hosts', 'private-endpoints', 'snet-sessionhosts', 'snet-privateendpoints' | ForEach-Object { [pscustomobject]@{ Name = $_ } })
    if (-not $Name) {
        return @([pscustomobject]@{ Name = 'vnet-example'; Id = '/mock/vnet-example'; ResourceGroupName = 'network-example'; Location = 'uksouth'
                AddressSpace = [pscustomobject]@{ AddressPrefixes = @('10.200.0.0/16') }; Subnets = $subnets; DhcpOptions = [pscustomobject]@{ DnsServers = @() } })
    }
    if ($Name -eq 'vnet-example' -or ($global:AvdTest.FoundationDone -and -not $global:AvdTest.NetworkMissing)) { [pscustomobject]@{ Name = $Name; Subnets = $subnets } }
}
function global:Get-AzResourceProvider {
    param($ProviderNamespace, $ErrorAction)
    [pscustomobject]@{
        RegistrationState = if ($ProviderNamespace -in $global:AvdTest.Unregistered) { 'NotRegistered' } else { 'Registered' }
        ResourceTypes     = @([pscustomobject]@{ ResourceTypeName = 'hostpools'; Locations = @('UK South', 'West Europe') })
    }
}
function global:Register-AzResourceProvider {
    param($ProviderNamespace, $ErrorAction)
    $global:AvdTest.Calls.Add("register:$ProviderNamespace")
    $global:AvdTest.Unregistered = @($global:AvdTest.Unregistered | Where-Object { $_ -ne $ProviderNamespace })
}
function global:Get-AzLocation { @([pscustomobject]@{ Location = 'uksouth'; DisplayName = 'UK South' }, [pscustomobject]@{ Location = 'westeurope'; DisplayName = 'West Europe' }) }
function global:Get-AzSubscription {
    param($ErrorAction, $WarningAction)
    @([pscustomobject]@{ Id = '22222222-2222-4222-8222-222222222222'; Name = 'Sandbox'; TenantId = '11111111-1111-4111-8111-111111111111'; State = 'Enabled' })
}
function global:Get-AzADGroup {
    param($ObjectId, $DisplayNameStartsWith, $DisplayName, $ErrorAction)
    $groups = @(
        [pscustomobject]@{ Id = '44444444-4444-4444-8444-444444444444'; DisplayName = 'AVD Users' },
        [pscustomobject]@{ Id = '55555555-5555-4555-8555-555555555555'; DisplayName = 'AVD Admins' }
    ) + @($global:AvdTest.CreatedGroups)
    if ($ObjectId) { return $groups | Where-Object { $_.Id -eq $ObjectId } }
    if ($DisplayName) { return $groups | Where-Object { $_.DisplayName -eq $DisplayName } }
    $groups | Where-Object { $_.DisplayName -like "$DisplayNameStartsWith*" }
}
function global:New-AzADGroup {
    param($DisplayName, $MailNickname, [switch]$SecurityEnabled, $Description, $ErrorAction)
    if (-not $SecurityEnabled) { throw 'Groups must be security enabled.' }
    $id = if ($DisplayName -like '*admins') { 'bbbbbbbb-1111-4111-8111-111111111111' } else { 'aaaaaaaa-1111-4111-8111-111111111111' }
    $group = [pscustomobject]@{ Id = $id; DisplayName = $DisplayName }
    $global:AvdTest.CreatedGroups = @($global:AvdTest.CreatedGroups) + $group
    $global:AvdTest.Calls.Add("create-group:$DisplayName")
    $group
}
function global:New-AzADGroupOwner { param($GroupId, $OwnerId, $ErrorAction) $global:AvdTest.Calls.Add("owner:$GroupId=$OwnerId") }
function global:Add-AzADGroupMember { param($TargetGroupObjectId, $MemberObjectId, $ErrorAction, $WarningAction) $global:AvdTest.Calls.Add("member:$TargetGroupObjectId=$($MemberObjectId -join ',')") }
function global:Get-AzADServicePrincipal { param($ApplicationId, $ErrorAction) [pscustomobject]@{ Id = '66666666-6666-4666-8666-666666666666' } }
function global:Get-AzADUser { param([switch]$SignedIn, $ErrorAction) [pscustomobject]@{ Id = '77777777-0000-4000-8000-000000000007' } }
function global:Get-AzResource {
    param($ResourceId, $ResourceGroupName, $Name, $ResourceType, $ErrorAction)
    if ($ResourceType -eq 'Microsoft.Compute/virtualMachines') { return @($global:AvdTest.ExistingVms | ForEach-Object { [pscustomobject]@{ Name = $_; Tags = $(if ($global:AvdTest.VmTags.ContainsKey($_)) { $global:AvdTest.VmTags[$_] } else { $null }) } }) }
    if ($ResourceId -like '*/secrets/*' -and $global:AvdTest.SecretExists) { return [pscustomobject]@{ ResourceId = $ResourceId } }
    if ($ResourceId -like '*/userAssignedIdentities/*' -and $global:AvdTest.FoundationDone) { return [pscustomobject]@{ ResourceId = $ResourceId } }
}
function global:Get-AzKeyVault {
    param($VaultName, $ResourceGroupName, $Location, [switch]$InRemovedState, $ErrorAction)
    if ($InRemovedState) { if ($global:AvdTest.DeletedVault) { [pscustomobject]@{ VaultName = $VaultName } }; return }
    if ($ResourceGroupName -and $global:AvdTest.FoundationDone) { [pscustomobject]@{ VaultName = $VaultName } }
}
function global:Invoke-AzRestMethod {
    param($Method, $Path, $Payload)
    if ($Method -eq 'PATCH' -and $Path -match '/virtualMachines/([^/]+)/providers/Microsoft\.Resources/tags/default\?') {
        $tags = ($Payload | ConvertFrom-Json -AsHashtable)
        if ($tags.operation -ne 'Merge' -or -not $tags.properties.tags.ContainsKey('avdv2-kerberos-restart')) { throw 'VM tags must be merged, not replaced.' }
        $global:AvdTest.Post.Add("tag:$($Matches[1])")
        return [pscustomobject]@{ StatusCode = 200; Content = '{}' }
    }
    if ($Method -eq 'POST' -and $Path -match '/virtualMachines/([^/]+)/restart\?') {
        $global:AvdTest.Post.Add("restart:$($Matches[1])")
        return [pscustomobject]@{ StatusCode = 202; Content = '' }
    }
    if ($Path -match '/storageAccounts/[^/?]+\?') {
        if ($Method -eq 'GET') { return [pscustomobject]@{ StatusCode = 200; Content = ($global:AvdTest.StorageState | ConvertTo-Json -Depth 10) } }
        $properties = ($Payload | ConvertFrom-Json -AsHashtable).properties
        $global:AvdTest.StorageState.properties.publicNetworkAccess = $properties.publicNetworkAccess
        $global:AvdTest.StorageState.properties.networkAcls = $properties.networkAcls
        $global:AvdTest.Post.Add("storage:$($properties.publicNetworkAccess)=$(@($properties.networkAcls.ipRules | ForEach-Object { $_.value }) -join ',')")
        return [pscustomobject]@{ StatusCode = 200; Content = '{}' }
    }
    if ($Method -eq 'GET' -and $Path -match '/skus\?') {
        $skus = foreach ($size in 'Standard_D2s_v5', 'Standard_D4s_v5', 'Standard_D8s_v5', 'Standard_D8as_v5', 'Standard_D8s_v3', 'Standard_E8s_v5') {
            if ($size -ne $global:AvdTest.MissingVmSize) {
                $family = switch -Wildcard ($size) { '*as_v5' { 'standardDASv5Family' } '*_v3' { 'standardDSv3Family' } 'Standard_E*' { 'standardESv5Family' } default { 'standardDSv5Family' } }
                $restrictions = if ($size -in $global:AvdTest.RestrictedSizes) { @(@{ type = 'Location'; reasonCode = 'NotAvailableForSubscription' }) } else { @() }
                @{ resourceType = 'virtualMachines'; name = $size; family = $family; restrictions = @($restrictions); capabilities = @(
                        @{ name = 'vCPUs'; value = [regex]::Match($size, '_[DE](\d+)').Groups[1].Value },
                        @{ name = 'HyperVGenerations'; value = $(if ($size -like '*_v3') { 'V1' } else { 'V1,V2' }) },
                        @{ name = 'PremiumIO'; value = 'True' }) }
            }
        }
        return [pscustomobject]@{ StatusCode = 200; Content = (@{ value = @($skus) } | ConvertTo-Json -Depth 6) }
    }
    if ($Method -eq 'GET' -and $Path -match '/usages\?') {
        $usage = @(@{ name = @{ value = 'standardDSv5Family' }; currentValue = 0; limit = $global:AvdTest.QuotaLimit }, @{ name = @{ value = 'standardDASv5Family' }; currentValue = 0; limit = 100 }, @{ name = @{ value = 'cores' }; currentValue = 0; limit = 100 })
        return [pscustomobject]@{ StatusCode = 200; Content = (@{ value = $usage } | ConvertTo-Json -Depth 6) }
    }
    $name = ($Payload | ConvertFrom-Json).name
    [pscustomobject]@{ StatusCode = 200; Content = (@{ nameAvailable = ($name -notin $global:AvdTest.TakenNames) } | ConvertTo-Json) }
}
function global:Test-AzResourceGroupDeployment {
    param($ResourceGroupName, $TemplateFile, $TemplateParameterObject, $ErrorAction)
    if ($global:AvdTest.HostValidationError) {
        [pscustomobject]@{ Code = 'InvalidTemplateDeployment'; Message = 'The template deployment is not valid according to the validation procedure. See inner errors for details.'; Target = $null
            Details = @([pscustomobject]@{ Code = 'QuotaExceeded'; Message = 'Operation could not be completed as it results in exceeding approved standardDSv5Family Cores quota.'; Target = $null; Details = @() }) }
    }
}
function global:Get-AzDeploymentWhatIfResult {
    param($Location, $TemplateFile, $TemplateParameterObject, $ErrorAction)
    $global:AvdTest.Calls.Add('whatif-foundation')
    [pscustomobject]@{ Changes = @([pscustomobject]@{ FullyQualifiedResourceId = '/mock/foundation'; ChangeType = 'Create' }); PotentialChanges = @([pscustomobject]@{ FullyQualifiedResourceId = '/mock/foundation/secret'; ChangeType = 'Create' }) }
}
function global:New-AzDeployment {
    param($Name, $Location, $TemplateFile, $TemplateParameterObject, $ErrorAction)
    $global:AvdTest.Calls.Add('deploy-foundation')
    $global:AvdTest.FoundationParameters = $TemplateParameterObject
    $global:AvdTest.FoundationDone = $true
    [pscustomobject]@{ ProvisioningState = 'Succeeded'; Outputs = @{ deploymentIdentityClientId = [pscustomobject]@{ Value = '88888888-0000-4000-8000-000000000008' } } }
}
function global:Get-AzRoleAssignment {
    param($ObjectId, $Scope, $ErrorAction)
    if ($global:AvdTest.PowerRole) { [pscustomobject]@{ RoleDefinitionId = '40c5ff49-9181-41f8-ae61-143b0e78555e'; Scope = $Scope } }
}
function global:Get-AzResourceGroupDeploymentWhatIfResult {
    param($ResourceGroupName, $TemplateFile, $TemplateParameterObject, $ErrorAction)
    $stage = if ($TemplateFile -like '*session-hosts.bicep') { 'hosts' } else { 'platform' }
    $global:AvdTest.Calls.Add("whatif-$stage")
    [pscustomobject]@{ Changes = @([pscustomobject]@{ FullyQualifiedResourceId = "/mock/$stage"; ChangeType = 'Create' }); PotentialChanges = @() }
}
function global:Get-AzWvdHostPool { param($ResourceGroupName, $Name, $ErrorAction) if ($global:AvdTest.ExistingPool) { [pscustomobject]@{ Name = $Name } } }
function global:Get-AzKeyVaultSecret {
    param($VaultName, $Name, $Version, $ErrorAction)
    $global:AvdTest.Calls.Add('read-secret')
    $global:AvdTest.ReadSecret = $true
    [pscustomobject]@{ SecretValue = (ConvertTo-SecureString 'mock-admin-password' -AsPlainText -Force) }
}
function global:New-AzResourceGroupDeployment {
    param($Name, $ResourceGroupName, $TemplateFile, $TemplateParameterObject, $ErrorAction)
    if ($TemplateFile -like '*session-hosts.bicep') {
        $global:AvdTest.Calls.Add('deploy-hosts')
        if ($TemplateParameterObject.adminPassword -isnot [securestring] -or $TemplateParameterObject.hostPoolRegistrationInfoToken -isnot [securestring]) { throw 'Secrets were not passed as SecureString.' }
        $global:AvdTest.HostParameters = $TemplateParameterObject
        if ($global:AvdTest.HostFail) { throw 'mock-host-failure' }
    } else {
        $global:AvdTest.Calls.Add('deploy-platform')
        $global:AvdTest.PlatformParameters = $TemplateParameterObject
        if ($global:AvdTest.PlatformAccessFailures -gt 0) {
            $global:AvdTest.PlatformAccessFailures--
            throw "unable to access host pool with name 'AVD-HostPool', please make sure that you have given the Azure Virtual Desktop service permissions to access your resource"
        }
        if ($global:AvdTest.PlatformFail) { throw 'mock-platform-failure' }
    }
    [pscustomobject]@{ ProvisioningState = 'Succeeded' }
}
function global:Update-AzWvdHostPool {
    param($ResourceGroupName, $Name, $RegistrationInfoExpirationTime, $RegistrationInfoRegistrationTokenOperation, $ErrorAction)
    if ($PSBoundParameters.Keys | Where-Object { $_ -notin 'ResourceGroupName', 'Name', 'RegistrationInfoExpirationTime', 'RegistrationInfoRegistrationTokenOperation', 'ErrorAction' }) { throw 'Only registration info may be patched.' }
    $global:AvdTest.Calls.Add($(if ($RegistrationInfoRegistrationTokenOperation -eq 'Delete') { 'remove-token' } else { 'create-token' }))
}
function global:Get-AzWvdHostPoolRegistrationToken { param($ResourceGroupName, $HostPoolName, $ErrorAction) [pscustomobject]@{ Token = 'mock-secret-token' } }
function global:Get-AzWvdSessionHost {
    param($ResourceGroupName, $HostPoolName)
    $global:AvdTest.Calls.Add('verify-hosts')
    $count = if ($global:AvdTest.MissingHost) { $global:AvdTest.HostCount - 1 } else { $global:AvdTest.HostCount }
    for ($index = 0; $index -lt $count; $index++) {
        $computer = "$($global:AvdTest.Prefix)-$index"
        [pscustomobject]@{
            Name         = "$HostPoolName/$computer"
            Status       = 'Available'
            AssignedUser = if ($global:AvdTest.AssignedUsers.ContainsKey($computer)) { $global:AvdTest.AssignedUsers[$computer] } else { $null }
        }
    }
}
function global:Update-AzWvdSessionHost { param($ResourceGroupName, $HostPoolName, $Name, $AssignedUser, $ErrorAction) $global:AvdTest.Calls.Add("assign:$Name=$AssignedUser") }
function global:Update-AzWvdDesktop {
    param($ResourceGroupName, $ApplicationGroupName, $Name, $FriendlyName, $ErrorAction)
    if ($global:AvdTest.DesktopRenameFails) { throw 'mock-desktop-failure' }
    $global:AvdTest.Post.Add("desktop:$ApplicationGroupName/$Name=$FriendlyName")
}
function global:New-AzRoleAssignment { param($ObjectId, $RoleDefinitionId, $Scope, $ErrorAction) $global:AvdTest.Post.Add("role-add:$RoleDefinitionId") }
function global:Remove-AzRoleAssignment { param($ObjectId, $RoleDefinitionId, $Scope, $ErrorAction) $global:AvdTest.Post.Add("role-remove:$RoleDefinitionId") }
function global:Get-AzAccessToken { param($ResourceUrl, $ErrorAction) [pscustomobject]@{ Token = (ConvertTo-SecureString 'mock-storage-token' -AsPlainText -Force) } }
function global:Invoke-RestMethod { param($Uri, $TimeoutSec, $ErrorAction) $global:AvdTest.Post.Add('detect-ip'); '203.0.113.7' }
function global:Invoke-WebRequest {
    param($Uri, $OutFile, $Method, $Headers, [switch]$UseBasicParsing, [switch]$SkipHeaderValidation, $ErrorAction)
    if ($Method -eq 'PUT') {
        if ($Headers.Authorization -ne 'Bearer mock-storage-token' -or $Headers['x-ms-file-request-intent'] -ne 'backup') { throw 'Files ACL requests must use the storage token with backup intent.' }
        if ($global:AvdTest.StorageState.properties.publicNetworkAccess -ne 'Enabled') { throw 'Files ACL request sent while the storage firewall was closed.' }
        if ($global:AvdTest.FilesForbidden -gt 0) {
            $global:AvdTest.FilesForbidden--
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Forbidden', [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::Forbidden))
        }
        $share = ([uri]$Uri).AbsolutePath.Trim('/')
        $global:AvdTest.Post.Add("acl:$share=$($Headers['x-ms-file-permission'])")
        return
    }
    Copy-Item -LiteralPath $global:AvdTest.PrepScript -Destination $OutFile
}
function global:Get-MgContext { [pscustomobject]@{ TenantId = $global:AvdTest.Tenant; Scopes = $global:AvdTest.GraphScopes } }
function global:Connect-MgGraph { param($TenantId, $Scopes, [switch]$NoWelcome) $global:AvdTest.Calls.Add('connect-graph'); $global:AvdTest.GraphScopes = $Scopes }
function global:New-GraphError {
    param([string]$Message)
    $record = [System.Management.Automation.ErrorRecord]::new([System.Exception]::new('Response status code does not indicate success: BadRequest (Bad Request).'), 'GraphError', 'InvalidOperation', $null)
    $record.ErrorDetails = [System.Management.Automation.ErrorDetails]::new("{`"error`":{`"message`":`"$Message`"}}")
    return $record
}
function global:Invoke-MgGraphRequest {
    param($Method, $Uri, $Body, $OutputType, $ContentType, $ErrorAction)
    $graph = $global:AvdTest.Graph
    $data = if ($Body -is [string]) { $Body | ConvertFrom-Json -AsHashtable } else { $Body }
    switch -Regex ("$Method $Uri") {
        "^GET .*servicePrincipals\(appId='270efc09" { return @{ id = 'wcl-sp' } }
        '^GET .*/servicePrincipals/wcl-sp/remoteDesktopSecurityConfiguration' { return @{ isRemoteDesktopProtocolEnabled = $graph.RdpEnabled } }
        '^PATCH .*/remoteDesktopSecurityConfiguration' { $graph.RdpEnabled = $data.isRemoteDesktopProtocolEnabled; $global:AvdTest.Post.Add('rdp-enable'); return }
        '^GET .*/applications\?' { return @{ value = @(if ($graph.App) { $graph.App }) } }
        '^GET .*/servicePrincipals\?\$filter=appId' { return @{ value = @(@{ id = 'storage-sp' }) } }
        "^GET .*servicePrincipals\(appId='00000003" { return @{ id = 'graph-sp' } }
        '^GET .*/oauth2PermissionGrants\?' { return @{ value = @(if ($graph.Grant) { $graph.Grant }) } }
        '^POST .*/oauth2PermissionGrants$' { $graph.Grant = @{ id = 'grant-1'; resourceId = $data.resourceId; consentType = $data.consentType; scope = $data.scope }; $global:AvdTest.Post.Add("consent:$($data.clientId)>$($data.resourceId)=$($data.scope)"); return }
        '^PATCH .*/oauth2PermissionGrants/' { $graph.Grant.scope = $data.scope; $global:AvdTest.Post.Add("consent-update=$($data.scope)"); return }
        '^PATCH .*/applications/app-object' {
            if ($data.ContainsKey('tags')) { $graph.App.tags = @($data.tags) }
            if ($data.ContainsKey('identifierUris')) { $graph.App.identifierUris = @($data.identifierUris) }
            $global:AvdTest.Post.Add("app:tags=$(@($graph.App.tags) -join '|');uris=$(@($graph.App.identifierUris).Count)")
            return
        }
        '^GET .*/identity/conditionalAccess/policies$' { return @{ value = @($graph.Policies) } }
        '^PATCH .*/identity/conditionalAccess/policies/(?<id>[^/]+)$' {
            $policy = $graph.Policies | Where-Object { $_.id -eq $Matches['id'] }
            if ($policy.displayName -like 'Microsoft-managed:*') { throw (New-GraphError '1184: You cannot change the properties of this Microsoft-managed policy, except for excluding users, groups, roles, or changing the state.') }
            $policy.conditions.applications.excludeApplications = @($data.conditions.applications.excludeApplications)
            if (@($data.conditions.applications.includeApplications) -notcontains 'All') { throw 'The include list must be preserved.' }
            $global:AvdTest.Post.Add("ca:$($policy.displayName)")
            return
        }
        '^GET .*/groups/(?<id>[^/?]+)\?\$select=onPremisesSecurityIdentifier' { return @{ onPremisesSecurityIdentifier = $graph.HybridSids[$Matches['id']] } }
        "^GET .*/devices\?\`$filter=displayName eq '(?<name>[^']+)'" { return @{ value = @(if ($graph.Devices.ContainsKey($Matches['name'])) { $graph.Devices[$Matches['name']] }) } }
    }
    if ($Method -eq 'POST') {
        $objectId = ($Body.'@odata.id' -split '/')[-1]
        $global:AvdTest.Calls.Add("group-add:$objectId")
        # Like Microsoft.Graph.Authentication 2.x: status line in the exception, service error body in ErrorDetails.
        $serviceMessage = if ($global:AvdTest.GraphDenied) { 'Insufficient privileges to complete the operation.' }
        elseif ($objectId -in $global:AvdTest.GraphExisting) { 'One or more added object references already exist for the following modified properties: ''members''.' }
        if ($serviceMessage) { throw (New-GraphError $serviceMessage) }
        return
    }
    throw "Unexpected Graph call in tests: $Method $Uri"
}
if (-not (Get-Command bicep -ErrorAction SilentlyContinue)) { function global:bicep { } }

try {
    # Preview ------------------------------------------------------------------------------------
    $pooled = New-TestConfiguration -Name 'pooled'
    Reset-State
    $result = Invoke-Cli @('-Mode', 'Preview', '-ConfigurationFile', $pooled)
    $plan = Get-Content -LiteralPath ([System.IO.Path]::ChangeExtension($pooled, '.plan.json')) -Raw | ConvertFrom-Json -AsHashtable
    Assert-True (-not $result.Error) "Fresh preview failed: $($result.Error)"
    Assert-True ($result.Calls -eq 'whatif-platform') "Fresh preview should only what-if the platform, got '$($result.Calls)'."
    Assert-True ($plan.blockers.Count -eq 0 -and ($plan.warnings -join ' ') -match 'does not exist yet') 'Fresh preview should warn about the core-only preview.'
    Assert-True ($result.Output -match 'Ready\. Deploy with') 'Preview should say it is ready to deploy.'
    Write-Pass 'fresh preview is read-only, platform-only and writes a plan with warnings.'

    Reset-State @{ ExistingPool = $true; PowerRole = $true }
    $result = Invoke-Cli @('-Mode', 'Preview', '-ConfigurationFile', $pooled)
    $plan = Get-Content -LiteralPath ([System.IO.Path]::ChangeExtension($pooled, '.plan.json')) -Raw | ConvertFrom-Json -AsHashtable
    Assert-True ($result.Calls -eq 'whatif-platform,whatif-hosts' -and $plan.changes.Count -eq 2 -and $plan.warnings.Count -eq 0) "Existing-pool preview should cover both stages with no warnings, got '$($result.Calls)'."
    Write-Pass 'preview of an existing pool covers platform and session hosts without reading secrets.'

    Reset-State @{ Tenant = '99999999-9999-4999-8999-999999999999' }
    $result = Invoke-Cli @('-Mode', 'Preview', '-ConfigurationFile', $pooled)
    Assert-True ($result.Calls -like 'connect-azure*' -and -not $result.Error) 'Preview should sign in to the configured tenant when the context is for another tenant.'
    Write-Pass 'preview signs in to the configured tenant when the current context is elsewhere.'

    Reset-State @{ MissingRg = $true }
    $result = Invoke-Cli @('-Mode', 'Preview', '-ConfigurationFile', $pooled)
    Assert-True ($result.Calls -eq '' -and $result.Output -match 'BLOCKED' -and $result.Output -match 'does not exist') 'A missing resource group should block without running what-if.'
    $blocked = Invoke-Cli @('-Mode', 'Deploy', '-ConfigurationFile', $pooled, '-AsSignedInUser', '-Approve', 'avd-example')
    Assert-True ($blocked.Error -match 'plan has blockers' -and $blocked.Calls -eq '') 'Deploy must refuse a plan with blockers.'
    Write-Pass 'blockers stop preview what-if and Deploy refuses a blocked plan.'

    $badDigest = New-TestConfiguration -Name 'bad-digest' -Change { param($c) $c.artifacts.sessionHostPrepSha256 = '0' * 64 }
    Reset-State
    $result = Invoke-Cli @('-Mode', 'Preview', '-ConfigurationFile', $badDigest)
    Assert-True ($result.Output -match 'BLOCKED' -and $result.Output -match 'SHA-256') 'A prep script digest mismatch should block.'
    Write-Pass 'session host prep script digest mismatch blocks the plan.'

    # Deploy gates -------------------------------------------------------------------------------
    $noPlan = New-TestConfiguration -Name 'no-plan'
    Reset-State
    $result = Invoke-Cli @('-Mode', 'Deploy', '-ConfigurationFile', $noPlan, '-AsSignedInUser', '-Approve', 'avd-example')
    Assert-True ($result.Error -match 'No plan found' -and $result.Calls -eq '') 'Deploy without a plan must fail before any change.'
    Write-Pass 'Deploy requires a preview plan.'

    Reset-State
    $null = Invoke-Cli @('-Mode', 'Preview', '-ConfigurationFile', $pooled)
    Reset-State
    $result = Invoke-Cli @('-Mode', 'Deploy', '-ConfigurationFile', $pooled, '-Approve', 'avd-example')
    Assert-True ($result.Error -match '-AsSignedInUser' -and $result.Calls -eq '') 'Deploy as a user must need -AsSignedInUser.'
    $result = Invoke-Cli @('-Mode', 'Deploy', '-ConfigurationFile', $pooled, '-AsSignedInUser', '-Approve', 'wrong-rg')
    Assert-True ($result.Error -match 'not approved' -and $result.Calls -eq '') 'Deploy must stop when approval does not match the resource group.'
    Write-Pass 'Deploy needs explicit signed-in-user consent and approval by resource group name.'

    $changed = Get-Content -LiteralPath $pooled -Raw | ConvertFrom-Json -AsHashtable
    $changed.sessionHosts.count = 3
    [System.IO.File]::WriteAllText($pooled, ($changed | ConvertTo-Json -Depth 32))
    Reset-State
    $result = Invoke-Cli @('-Mode', 'Deploy', '-ConfigurationFile', $pooled, '-AsSignedInUser', '-Approve', 'avd-example')
    Assert-True ($result.Error -match 'configuration changed' -and $result.Calls -eq '') 'Deploy must reject a plan when the configuration changed.'
    Reset-State
    $null = Invoke-Cli @('-Mode', 'Preview', '-ConfigurationFile', $pooled)
    $planPath = [System.IO.Path]::ChangeExtension($pooled, '.plan.json')
    $expiredPlan = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json -AsHashtable
    $expiredPlan.expiresUtc = [DateTime]::UtcNow.AddMinutes(-1).ToString('o')
    [System.IO.File]::WriteAllText($planPath, ($expiredPlan | ConvertTo-Json -Depth 8))
    Reset-State
    $result = Invoke-Cli @('-Mode', 'Deploy', '-ConfigurationFile', $pooled, '-AsSignedInUser', '-Approve', 'avd-example')
    Assert-True ($result.Error -match 'expired' -and $result.Calls -eq '') 'Deploy must reject an expired plan.'
    Write-Pass 'Deploy rejects changed configurations and expired plans.'

    # Deploy orchestration -----------------------------------------------------------------------
    $happy = New-TestConfiguration -Name 'happy'
    Reset-State
    $null = Invoke-Cli @('-Mode', 'Preview', '-ConfigurationFile', $happy)
    Reset-State
    $result = Invoke-Cli @('-Mode', 'Deploy', '-ConfigurationFile', $happy, '-AsSignedInUser', '-Approve', 'avd-example')
    Assert-True (-not $result.Error) "Happy-path deploy failed: $($result.Error)"
    Assert-True ($result.Calls -eq 'read-secret,deploy-platform,create-token,deploy-hosts,remove-token,verify-hosts') "Unexpected deploy order '$($result.Calls)'."
    Assert-True ($result.Output -notmatch 'mock-secret-token' -and $result.Output -notmatch 'mock-admin-password') 'Secrets leaked into output.'
    Assert-True ($global:AvdTest.HostParameters.profileMode -eq 'FSLogix' -and $global:AvdTest.HostParameters.hostPoolType -eq 'Pooled' -and $global:AvdTest.PlatformParameters.profile -eq 'AzureFilesHybridKerberos') 'Pooled hybrid deploy should pass FSLogix and pooled parameters.'
    Assert-True ($result.Output -match 'Registration token revoked') 'Deploy should report token revocation.'
    Write-Pass 'Deploy runs platform, token, hosts, revocation and verification in order without leaking secrets.'

    Reset-State
    $null = Invoke-Cli @('-Mode', 'Preview', '-ConfigurationFile', $happy)
    Reset-State @{ PlatformFail = $true }
    $result = Invoke-Cli @('-Mode', 'Deploy', '-ConfigurationFile', $happy, '-AsSignedInUser', '-Approve', 'avd-example')
    Assert-True ($result.Error -match 'mock-platform-failure' -and $result.Calls -eq 'read-secret,deploy-platform') 'A platform failure must stop before the token and hosts.'
    Reset-State @{ HostFail = $true }
    $result = Invoke-Cli @('-Mode', 'Deploy', '-ConfigurationFile', $happy, '-AsSignedInUser', '-Approve', 'avd-example')
    Assert-True ($result.Error -match 'mock-host-failure' -and $result.Calls -eq 'read-secret,deploy-platform,create-token,deploy-hosts,remove-token') 'A host failure must still revoke the token.'
    Reset-State @{ MissingHost = $true }
    $result = Invoke-Cli @('-Mode', 'Deploy', '-ConfigurationFile', $happy, '-AsSignedInUser', '-Approve', 'avd-example', '-RegistrationWaitMinutes', '0')
    Assert-True ($result.Error -match 'registration could not be verified for: AVDHOST-1') 'Missing registration must fail with the host name.'
    Write-Pass 'failures stop safely: platform failure skips hosts, host failure revokes the token, missing registration is reported.'

    # Dedicated users ----------------------------------------------------------------------------
    $dedicated = New-TestConfiguration -Name 'dedicated' -Change {
        param($c)
        $c.schemaVersion = '1.3.0'
        $c.profile = 'LocalProfile'
        $c.Remove('storage')
        $c.Remove('scaling')
        $c.identity.Remove('kerberosDomainName')
        $c.identity.Remove('kerberosDomainGuid')
        $c.workload = [ordered]@{ hosting = 'Dedicated'; persona = 'Standard'; users = 2; peakConcurrencyPct = 100 }
        $c.hostPool = [ordered]@{ type = 'Personal'; assignmentType = 'Direct' }
        $c.sessionHosts.vmSize = 'Standard_D4s_v5'
        $c.assignments = @(
            [ordered]@{ userPrincipalName = 'jane@example.com'; objectId = 'aaaaaaaa-0000-4000-8000-000000000001'; hostIndex = 0 },
            [ordered]@{ userPrincipalName = 'bob@example.com'; objectId = 'bbbbbbbb-0000-4000-8000-000000000002'; hostIndex = 1 }
        )
    }
    Reset-State
    $null = Invoke-Cli @('-Mode', 'Preview', '-ConfigurationFile', $dedicated)
    Reset-State @{ AssignedUsers = @{ 'AVDHOST-1' = 'bob@example.com' }; GraphExisting = @('bbbbbbbb-0000-4000-8000-000000000002') }
    $result = Invoke-Cli @('-Mode', 'Deploy', '-ConfigurationFile', $dedicated, '-AsSignedInUser', '-Approve', 'avd-example')
    Assert-True (-not $result.Error) "Dedicated deploy failed: $($result.Error)"
    Assert-True ($result.Calls -match 'assign:AVDHOST-0=jane@example.com' -and $result.Calls -notmatch 'assign:AVDHOST-1') 'Only the unassigned host should be assigned.'
    Assert-True ($result.Calls -match 'group-add:aaaaaaaa' -and $result.Output -match 'In AVD users group: bob@example.com') 'Users should be added to the group, treating existing membership as success.'
    Assert-True ($global:AvdTest.HostParameters.profileMode -eq 'Local' -and $global:AvdTest.HostParameters.hostPoolType -eq 'Personal' -and -not $global:AvdTest.HostParameters.ContainsKey('storageAccountName')) 'Dedicated deploy should use local profiles and no storage.'
    Write-Pass 'dedicated deploy assigns hosts to named users and adds them to the AVD users group.'

    Reset-State @{ AssignedUsers = @{ 'AVDHOST-1' = 'mallory@example.com' }; GraphDenied = $true }
    $result = Invoke-Cli @('-Mode', 'Deploy', '-ConfigurationFile', $dedicated, '-AsSignedInUser', '-Approve', 'avd-example')
    Assert-True (-not $result.Error) "Dedicated deploy with conflicts failed: $($result.Error)"
    Assert-True ($result.Calls -notmatch 'assign:AVDHOST-1' -and $result.Calls -notmatch 'group-add:bbbbbbbb') 'A host owned by someone else must not be reassigned, and its intended user must not be added to the group.'
    Assert-True ($result.Output -match 'already assigned to mallory@example.com' -and $result.Output -match 'could not change this group') 'Conflicts and delegated denial must become manual tasks.'
    Write-Pass 'dedicated deploy never reassigns another user''s host and reports delegated denial without fallback.'

    Reset-State @{ GraphScopes = @('User.ReadBasic.All') }
    $result = Invoke-Cli @('-Mode', 'Deploy', '-ConfigurationFile', $dedicated, '-AsSignedInUser', '-Approve', 'avd-example')
    Assert-True ($result.Calls -match 'connect-graph' -and $result.Calls -match 'group-add:aaaaaaaa') 'Deploy should sign in to Graph with GroupMember.ReadWrite.All when the session lacks it.'
    Write-Pass 'dedicated deploy requests the delegated group scope when needed.'

    # Discovery and foundation ------------------------------------------------------------------
    $discovered = Join-Path $temporaryDirectory 'discovered.json'
    Reset-State @{ MissingRg = $true }
    $result = Invoke-Cli @('-Mode', 'New', '-OutputFile', $discovered, '-SubscriptionId', 'Sandbox', '-Location', 'uksouth', '-Prefix', 'TST',
        '-NetworkMode', 'New', '-UsersGroup', 'AVD Users', '-AdminsGroup', 'AVD Admins', '-Hosting', 'Shared', '-Persona', 'Standard',
        '-Users', '20', '-PeakConcurrencyPct', '100', '-UserIdentity', 'CloudOnly', '-ScalingPreset', 'None')
    Assert-True (-not $result.Error) "Discovery New failed: $($result.Error)"
    $config = Get-Content -LiteralPath $discovered -Raw | ConvertFrom-Json -AsHashtable
    $pinned = Get-Content -LiteralPath (Join-Path $v2Root 'contracts/artifacts.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert-True ($config.schemaVersion -eq '1.5.0' -and $config.tenantId -eq $tenantId -and $config.subscriptionId -eq $subscriptionId -and $config.target.resourceGroupName -eq 'rg-tst-avd') 'Discovery should fill tenant, subscription and the default resource group.'
    Assert-True ($config.display.workspaceName -eq 'TST Workspace' -and $config.display.desktopName -eq 'TST Virtual Desktop' -and $config.fslogix.preventTempProfile -eq $false) "New should default the display names from the prefix and keep temporary profiles, got $($config.display | ConvertTo-Json -Compress) $($config.fslogix | ConvertTo-Json -Compress)"
    Assert-True ($config.foundation.createResourceGroup -and $config.foundation.network.addressSpace -eq '10.201.0.0/24' -and $config.network.resourceGroupName -eq 'rg-tst-avd') 'A new VNet should get the first range that does not overlap existing VNets (10.200.0.0/16 is taken).'
    Assert-True ($config.accessGroups.usersObjectId -eq '44444444-4444-4444-8444-444444444444' -and $config.accessGroups.adminsObjectId -eq '55555555-5555-4555-8555-555555555555' -and $config.identity.avdServicePrincipalObjectId -eq '66666666-6666-4666-8666-666666666666') 'Groups and the AVD service principal should be resolved from Entra.'
    Assert-True ($config.sessionHosts.adminPasswordSecretUri -eq "https://$($config.foundation.keyVault.name).vault.azure.net/secrets/sessionhost-admin" -and $config.execution.deploymentIdentityResourceId -like '*/resourceGroups/rg-tst-avd/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-tst-avd-deployer') 'Key Vault secret URI and deployment identity should match the foundation.'
    Assert-True ($config.artifacts.sessionHostPrepSha256 -eq $pinned.sessionHostPrep.sha256 -and $config.storage.accountName -match '^sttst[0-9a-f]{6}$' -and $config.sessionHosts.namePrefix -eq 'TSTSH') 'Pinned artifact, unique storage name and host prefix should be generated.'
    Assert-True ($result.Output -match 'Next: .*-Mode Preview') 'Discovery New should point to Preview next.'
    Write-Pass 'New discovers subscription, region, network range, groups and service principal, and generates unique names.'

    $withGroups = Join-Path $temporaryDirectory 'new-groups.json'
    Reset-State @{ MissingRg = $true; CreatedGroups = @() }
    $result = Invoke-Cli @('-Mode', 'New', '-OutputFile', $withGroups, '-SubscriptionId', 'Sandbox', '-Location', 'uksouth', '-Prefix', 'TST',
        '-NetworkMode', 'New', '-NewUsersGroup', 'sg-tst-avd-users', '-NewAdminsGroup', 'sg-tst-avd-admins', '-AddMeToUsersGroup',
        '-Hosting', 'Dedicated', '-Persona', 'Standard', '-Users', '2', '-ScalingPreset', 'None')
    $groupConfig = Get-Content -LiteralPath $withGroups -Raw | ConvertFrom-Json -AsHashtable
    Assert-True (-not $result.Error) "New with group creation failed: $($result.Error)"
    Assert-True ($result.Calls -match 'create-group:sg-tst-avd-users' -and $result.Calls -match 'create-group:sg-tst-avd-admins') 'Both groups should be created.'
    Assert-True ($result.Calls -match 'owner:aaaaaaaa-1111-4111-8111-111111111111=77777777' -and $result.Calls -match 'member:aaaaaaaa-1111-4111-8111-111111111111=77777777') 'The operator should own the new users group and be added as a test member.'
    Assert-True ($groupConfig.accessGroups.usersObjectId -eq 'aaaaaaaa-1111-4111-8111-111111111111' -and $groupConfig.accessGroups.adminsObjectId -eq 'bbbbbbbb-1111-4111-8111-111111111111') 'The new group IDs should be written to the configuration.'
    Reset-State @{ MissingRg = $true; CreatedGroups = @([pscustomobject]@{ Id = 'aaaaaaaa-1111-4111-8111-111111111111'; DisplayName = 'sg-tst-avd-users' }) }
    $result = Invoke-Cli @('-Mode', 'New', '-OutputFile', $withGroups, '-Force', '-SubscriptionId', 'Sandbox', '-Location', 'uksouth', '-Prefix', 'TST',
        '-NetworkMode', 'New', '-NewUsersGroup', 'sg-tst-avd-users', '-NewAdminsGroup', 'sg-tst-avd-admins',
        '-Hosting', 'Dedicated', '-Persona', 'Standard', '-Users', '2', '-ScalingPreset', 'None')
    Assert-True (-not $result.Error -and $result.Calls -notmatch 'create-group:sg-tst-avd-users' -and $result.Output -match "already exists; using it") 'Rerunning New should reuse a group it created earlier instead of duplicating it.'
    Write-Pass 'New can create the users and admins groups (operator as owner) and reuses them on rerun.'

    $prepPinned = $global:AvdTest.PrepScript
    Reset-State @{ MissingRg = $true; Unregistered = @('Microsoft.DesktopVirtualization') }
    $global:AvdTest.PrepScript = $prepPinned
    # The pinned artifact hash is for the published file; point the test download at a file with that hash.
    $config.artifacts.sessionHostPrepSha256 = $prepSha
    [System.IO.File]::WriteAllText($discovered, ($config | ConvertTo-Json -Depth 32))
    $result = Invoke-Cli @('-Mode', 'Preview', '-ConfigurationFile', $discovered)
    $plan = Get-Content -LiteralPath ([System.IO.Path]::ChangeExtension($discovered, '.plan.json')) -Raw | ConvertFrom-Json -AsHashtable
    Assert-True (-not $result.Error -and $result.Calls -eq 'whatif-foundation' -and $plan.blockers.Count -eq 0) "Fresh foundation preview should only what-if the foundation, got '$($result.Calls)' $($result.Error)."
    Assert-True (($plan.warnings -join ' ') -match 'only after the foundation' -and ($plan.warnings -join ' ') -match 'not registered') 'Preview should explain the staged preview and unregistered providers.'
    Assert-True (@($plan.changes | Where-Object { $_.resourceId -eq '/mock/foundation' -and $_.changeType -eq 'Create' }).Count -eq 1 -and @($plan.changes | Where-Object { $_.changeType -eq 'PotentialCreate' }).Count -eq 1 -and $result.Output -match 'Previewed changes: Create: 1, PotentialCreate: 1') 'The plan should record what-if changes and potential changes using FullyQualifiedResourceId.'
    Write-Pass 'preview of a new estate is read-only: foundation what-if only, with no blockers for the missing resource group.'

    Reset-State @{ MissingRg = $true; Unregistered = @('Microsoft.DesktopVirtualization'); Prefix = 'TSTSH' }
    $result = Invoke-Cli @('-Mode', 'Deploy', '-ConfigurationFile', $discovered, '-AsSignedInUser', '-Approve', 'rg-tst-avd', '-RegistrationWaitMinutes', '0')
    Assert-True (-not $result.Error) "Foundation deploy failed: $($result.Error)"
    Assert-True ($result.Calls -eq 'register:Microsoft.DesktopVirtualization,deploy-foundation,deploy-platform,create-token,deploy-hosts,remove-token,verify-hosts') "Unexpected foundation deploy order '$($result.Calls)'."
    Assert-True ($global:AvdTest.FoundationParameters.adminPassword -is [securestring] -and [object]::ReferenceEquals($global:AvdTest.FoundationParameters.adminPassword, $global:AvdTest.HostParameters.adminPassword) -and -not $global:AvdTest.ContainsKey('ReadSecret')) 'A new estate should generate one password, store it via the foundation and use it for hosts without reading Key Vault.'
    Assert-True ($global:AvdTest.FoundationParameters.operatorObjectId -eq '77777777-0000-4000-8000-000000000007' -and $global:AvdTest.FoundationParameters.network.addressSpace -eq '10.201.0.0/24') 'The operator and network should be passed to the foundation.'
    Assert-True ($result.Output -match 'Deployment identity client ID: 88888888' -and $result.Output -match 'PREVIEW cloud-only') 'Deploy should report the created identity and preview prerequisites.'
    Write-Pass 'Deploy registers providers, creates the foundation with a generated password, then deploys AVD.'

    Reset-State @{ SecretExists = $true; FoundationDone = $true; NetworkMissing = $true }
    $null = Invoke-Cli @('-Mode', 'Preview', '-ConfigurationFile', $discovered)
    Reset-State @{ SecretExists = $true; FoundationDone = $true; NetworkMissing = $true; Prefix = 'TSTSH' }
    $result = Invoke-Cli @('-Mode', 'Deploy', '-ConfigurationFile', $discovered, '-AsSignedInUser', '-Approve', 'rg-tst-avd', '-RegistrationWaitMinutes', '0')
    Assert-True ($result.Calls -eq 'deploy-foundation,read-secret,deploy-platform,create-token,deploy-hosts,remove-token,verify-hosts' -and -not $global:AvdTest.FoundationParameters.ContainsKey('adminPassword') -and $global:AvdTest.FoundationParameters.network -and -not $global:AvdTest.FoundationParameters.keyVault.create -and -not $global:AvdTest.FoundationParameters.createResourceGroup) "A partial rerun must create only the missing network, keep the existing password and read it from Key Vault, got '$($result.Calls)'."
    Write-Pass 'a partial rerun creates only missing foundation pieces and never rotates the stored admin password.'

    Reset-State @{ SecretExists = $true; FoundationDone = $true; Prefix = 'TSTSH' }
    $null = Invoke-Cli @('-Mode', 'Preview', '-ConfigurationFile', $discovered)
    Assert-True ($global:AvdTest.Calls -notcontains 'whatif-foundation') 'Preview should skip the foundation what-if when everything exists.'
    Reset-State @{ SecretExists = $true; FoundationDone = $true; Prefix = 'TSTSH' }
    $result = Invoke-Cli @('-Mode', 'Deploy', '-ConfigurationFile', $discovered, '-AsSignedInUser', '-Approve', 'rg-tst-avd', '-RegistrationWaitMinutes', '0')
    Assert-True ($result.Calls -eq 'read-secret,deploy-platform,create-token,deploy-hosts,remove-token,verify-hosts' -and $result.Output -match 'Foundation already in place') "An existing foundation must not be redeployed (it would overwrite later changes), got '$($result.Calls)' $($result.Error)"
    Write-Pass 'an existing foundation is left untouched on reruns.'

    Reset-State @{ SecretExists = $true; FoundationDone = $true; Prefix = 'TSTSH'; AccountType = 'ManagedService' }
    $null = Invoke-Cli @('-Mode', 'Preview', '-ConfigurationFile', $discovered)
    Reset-State @{ SecretExists = $true; FoundationDone = $true; Prefix = 'TSTSH'; AccountType = 'ManagedService' }
    $result = Invoke-Cli @('-Mode', 'Deploy', '-ConfigurationFile', $discovered, '-Approve', 'rg-tst-avd', '-RegistrationWaitMinutes', '0')
    Assert-True (-not $result.Error -and $result.Calls -eq 'read-secret,deploy-platform,create-token,deploy-hosts,remove-token,verify-hosts') "The managed identity should deploy without foundation or provider rights when everything exists, got '$($result.Calls)' $($result.Error)."
    Reset-State @{ MissingRg = $true; AccountType = 'ManagedService'; Unregistered = @('Microsoft.KeyVault') }
    $result = Invoke-Cli @('-Mode', 'Preview', '-ConfigurationFile', $discovered)
    Assert-True ($result.Output -match 'BLOCKED' -and $result.Output -match 'Ask a subscription administrator' -and $result.Calls -notmatch 'register') 'The managed identity must not register providers or create the foundation.'
    Write-Pass 'the managed identity never registers providers or creates the foundation.'

    Reset-State
    $result = Invoke-Cli @('-Mode', 'New', '-OutputFile', (Join-Path $temporaryDirectory 'misaligned.json'), '-SubscriptionId', 'Sandbox', '-Location', 'uksouth', '-Prefix', 'TST',
        '-NetworkMode', 'New', '-AddressSpace', '10.201.1.0/16', '-UsersGroup', 'AVD Users', '-AdminsGroup', 'AVD Admins', '-Hosting', 'Dedicated', '-Persona', 'Standard', '-Users', '2', '-ScalingPreset', 'None')
    Assert-True ($result.Error -match 'not a network boundary') 'A misaligned address space must be rejected before it reaches Azure.'
    $misaligned = Get-Content -LiteralPath $discovered -Raw | ConvertFrom-Json -AsHashtable
    $misaligned.foundation.network.addressSpace = '10.201.1.0/16'
    [System.IO.File]::WriteAllText((Join-Path $temporaryDirectory 'misaligned-config.json'), ($misaligned | ConvertTo-Json -Depth 32))
    $result = Invoke-Cli @('-Mode', 'Validate', '-ConfigurationFile', (Join-Path $temporaryDirectory 'misaligned-config.json'))
    Assert-True ($result.Error -match 'not a network boundary') 'Validate must reject a misaligned foundation address space.'
    Write-Pass 'misaligned address spaces are rejected in New and Validate.'

    # Autoscale prerequisite: AVD refuses to create a scaling plan without the subscription-scope power role.
    Reset-State @{ PowerRole = $false }
    $result = Invoke-Cli @('-Mode', 'Preview', '-ConfigurationFile', $pooled)
    Assert-True ($result.Output -match 'BLOCKED' -and $result.Output -match 'Autoscale prerequisite missing' -and $result.Calls -eq '') 'Without a foundation, a missing autoscale role must block the plan.'
    Write-Pass 'a missing autoscale role blocks Preview when there is no foundation to grant it.'

    $withScaling = Get-Content -LiteralPath $discovered -Raw | ConvertFrom-Json -AsHashtable
    $withScaling.scaling = (Get-Content -LiteralPath (Join-Path $v2Root 'config/avd.example.json') -Raw | ConvertFrom-Json -AsHashtable).scaling
    $scaledPath = Join-Path $temporaryDirectory 'discovered-scaling.json'
    [System.IO.File]::WriteAllText($scaledPath, ($withScaling | ConvertTo-Json -Depth 32))
    Reset-State @{ SecretExists = $true; FoundationDone = $true; PowerRole = $false; Prefix = 'TSTSH' }
    $result = Invoke-Cli @('-Mode', 'Preview', '-ConfigurationFile', $scaledPath)
    Assert-True ($result.Output -match 'foundation will grant' -and $result.Calls -eq 'whatif-foundation,whatif-platform') "With a foundation, Preview should plan to grant the role, got '$($result.Calls)'."
    Reset-State @{ SecretExists = $true; FoundationDone = $true; PowerRole = $false; Prefix = 'TSTSH'; PlatformAccessFailures = 1 }
    $env:AVDV2_RETRY_DELAY_SECONDS = '0'
    $result = Invoke-Cli @('-Mode', 'Deploy', '-ConfigurationFile', $scaledPath, '-AsSignedInUser', '-Approve', 'rg-tst-avd', '-RegistrationWaitMinutes', '0')
    Remove-Item Env:\AVDV2_RETRY_DELAY_SECONDS
    Assert-True (-not $result.Error) "Deploy with the autoscale grant failed: $($result.Error)"
    Assert-True ($global:AvdTest.FoundationParameters.autoscaleServicePrincipalId -eq $config.identity.avdServicePrincipalObjectId -and -not $global:AvdTest.FoundationParameters.network -and -not $global:AvdTest.FoundationParameters.createResourceGroup) 'The foundation should grant only the missing autoscale role.'
    Assert-True ($result.Calls -eq 'deploy-foundation,read-secret,deploy-platform,deploy-platform,create-token,deploy-hosts,remove-token,verify-hosts' -and $result.Output -match 'retrying') "The platform should retry while the new role takes effect, got '$($result.Calls)'."
    Write-Pass 'the foundation grants the autoscale role and the platform retries while it takes effect.'

    # Compute capacity and session-host validation
    Reset-State @{ ExistingPool = $true; QuotaLimit = 8 }
    $result = Invoke-Cli @('-Mode', 'Preview', '-ConfigurationFile', $happy)
    Assert-True ($result.Output -match 'BLOCKED' -and $result.Output -match 'Not enough quota for 2 x Standard_D8s_v5 in uksouth: standardDSv5Family vCPUs needs 16, 8 free') 'Insufficient vCPU quota should block Preview with the numbers.'
    Assert-True ($result.Output -match 'Available 8-vCPU sizes with enough quota: Standard_D8as_v5\.') "Quota blockers should suggest sizes from families with free quota, got: $($result.Output)"
    Reset-State @{ ExistingPool = $true; MissingVmSize = 'Standard_D8s_v5' }
    $result = Invoke-Cli @('-Mode', 'Preview', '-ConfigurationFile', $happy)
    Assert-True ($result.Output -match 'VM size Standard_D8s_v5 is not offered in uksouth') 'An unavailable VM size should block Preview.'
    Reset-State @{ ExistingPool = $true; RestrictedSizes = @('Standard_D8s_v5') }
    $result = Invoke-Cli @('-Mode', 'Preview', '-ConfigurationFile', $happy)
    Assert-True ($result.Output -match 'Standard_D8s_v5 is restricted for this subscription in uksouth.*Available 8-vCPU sizes with enough quota: Standard_D8as_v5\.') "A restricted size should suggest Gen2, unrestricted D-series alternatives only, got: $($result.Output)"
    Reset-State @{ ExistingPool = $true; RestrictedSizes = @('Standard_D8s_v5', 'Standard_D8as_v5') }
    $result = Invoke-Cli @('-Mode', 'Preview', '-ConfigurationFile', $happy)
    Assert-True ($result.Output -match 'No other 8-vCPU D-series size is available') 'With no alternative the blocker should say so.'
    Write-Pass 'Preview blocks on an unavailable, restricted, or under-quota VM size and suggests usable alternatives.'

    Reset-State
    $null = Invoke-Cli @('-Mode', 'Preview', '-ConfigurationFile', $happy)
    Reset-State @{ HostValidationError = $true }
    $result = Invoke-Cli @('-Mode', 'Deploy', '-ConfigurationFile', $happy, '-AsSignedInUser', '-Approve', 'avd-example')
    Assert-True ($result.Error -match 'Session host validation failed' -and $result.Error -match '\[QuotaExceeded\] Operation could not be completed') 'Host validation failures must show the nested Azure error.'
    Assert-True ($result.Calls -eq 'read-secret,deploy-platform') "No registration token or hosts should be created when validation fails, got '$($result.Calls)'."
    Write-Pass 'Deploy validates session hosts before creating a token and shows the nested Azure error.'

    Reset-State @{ MissingRg = $true; TakenNames = @($config.foundation.keyVault.name, $config.storage.accountName) }
    $result = Invoke-Cli @('-Mode', 'Preview', '-ConfigurationFile', $discovered)
    Assert-True ($result.Output -match "Key Vault name '$($config.foundation.keyVault.name)' is already taken" -and $result.Output -match 'Storage account name .* is already taken' -and $result.Calls -eq '') 'Taken Key Vault and storage names should block before what-if.'
    Reset-State @{ MissingRg = $true; DeletedVault = $true }
    $result = Invoke-Cli @('-Mode', 'Preview', '-ConfigurationFile', $discovered)
    Assert-True ($result.Output -match 'soft-deleted vault') 'A soft-deleted Key Vault with the same name should block.'
    Write-Pass 'taken or soft-deleted names block the plan.'

    # Display names, host restart and PostDeploy ---------------------------------------------------
    Assert-True ((ConvertTo-AvdCloudSid -ObjectId '73d664e4-0886-4a73-b745-c694da45ddb4') -eq 'S-1-12-1-1943430372-1249052806-2496021943-3034400218') 'Entra object IDs must convert to the documented S-1-12-1 SID.'
    $account = $config.storage.accountName
    $usersSid = ConvertTo-AvdCloudSid -ObjectId $config.accessGroups.usersObjectId
    $adminsSid = ConvertTo-AvdCloudSid -ObjectId $config.accessGroups.adminsObjectId

    Reset-State @{ SecretExists = $true; FoundationDone = $true; Prefix = 'TSTSH' }
    $null = Invoke-Cli @('-Mode', 'Preview', '-ConfigurationFile', $discovered)
    Reset-State @{ SecretExists = $true; FoundationDone = $true; Prefix = 'TSTSH'; ExistingVms = @('TSTSH-0') }
    $result = Invoke-Cli @('-Mode', 'Deploy', '-ConfigurationFile', $discovered, '-AsSignedInUser', '-Approve', 'rg-tst-avd', '-RegistrationWaitMinutes', '0')
    Assert-True (-not $result.Error -and $result.Calls -eq 'read-secret,deploy-platform,create-token,deploy-hosts,remove-token,verify-hosts') "Deploy with display names failed or changed order: '$($result.Calls)' $($result.Error)"
    Assert-True ($global:AvdTest.PlatformParameters.workspaceFriendlyName -eq 'TST Workspace' -and $global:AvdTest.Post -contains 'desktop:TST-AppGroup/SessionDesktop=TST Virtual Desktop' -and $result.Output -match 'Desktop name: TST Virtual Desktop') 'Deploy should set the workspace and desktop names users see.'
    Assert-True ($global:AvdTest.Post -contains 'restart:TSTSH-1' -and $global:AvdTest.Post -contains 'tag:TSTSH-1' -and $global:AvdTest.Post -notcontains 'restart:TSTSH-0' -and $global:AvdTest.HostParameters.preventTempProfile -eq $false) "Only hosts created by this run should restart and be tagged, got $($global:AvdTest.Post -join ', ')"
    Assert-True ($result.Output -match 'Restart TSTSH-0 once when no one is signed in') 'An existing host with no recorded restart should get a manual restart task.'
    Assert-True ($result.Output -match 'Mode PostDeploy' -and $result.Output -match 'authentication for RDP') 'Without -PostDeploy, Deploy should list the Entra steps and suggest PostDeploy.'
    Reset-State @{ SecretExists = $true; FoundationDone = $true; Prefix = 'TSTSH'; ExistingVms = @('TSTSH-0', 'TSTSH-1'); VmTags = @{ 'TSTSH-0' = @{ 'avdv2-kerberos-restart' = 'x' }; 'TSTSH-1' = @{ 'avdv2-kerberos-restart' = 'x' } } }
    $result = Invoke-Cli @('-Mode', 'Deploy', '-ConfigurationFile', $discovered, '-AsSignedInUser', '-Approve', 'rg-tst-avd', '-RegistrationWaitMinutes', '0')
    Assert-True (-not $result.Error -and -not ($global:AvdTest.Post -match '^restart') -and $result.Output -notmatch 'Restart TSTSH') 'Hosts already restarted by an earlier run must not be restarted or flagged again.'
    Reset-State @{ SecretExists = $true; FoundationDone = $true; Prefix = 'TSTSH'; DesktopRenameFails = $true }
    $result = Invoke-Cli @('-Mode', 'Deploy', '-ConfigurationFile', $discovered, '-AsSignedInUser', '-Approve', 'rg-tst-avd', '-RegistrationWaitMinutes', '0')
    Assert-True (-not $result.Error -and $result.Output -match "Set the desktop name: Update-AzWvdDesktop .* -FriendlyName 'TST Virtual Desktop'") 'A failed desktop rename should become a manual task, not fail the deployment.'
    Write-Pass 'Deploy sets the workspace and desktop names and restarts only new FSLogix hosts.'

    $oldPrep = Join-Path $temporaryDirectory 'old-prep.ps1'
    [System.IO.File]::WriteAllText($oldPrep, "param([string]`$ProfileMode, [string]`$ProfilesPath, [string]`$RedirectionPath)`n")
    $blocking = Get-Content -LiteralPath $discovered -Raw | ConvertFrom-Json -AsHashtable
    $blocking.fslogix.preventTempProfile = $true
    $blocking.artifacts.sessionHostPrepSha256 = (Get-FileHash -LiteralPath $oldPrep -Algorithm SHA256).Hash.ToLowerInvariant()
    $blockingPath = Join-Path $temporaryDirectory 'blocking.json'
    [System.IO.File]::WriteAllText($blockingPath, ($blocking | ConvertTo-Json -Depth 32))
    Reset-State @{ SecretExists = $true; FoundationDone = $true; Prefix = 'TSTSH'; PrepScript = $oldPrep }
    $result = Invoke-Cli @('-Mode', 'Preview', '-ConfigurationFile', $blockingPath)
    Assert-True ($result.Output -match 'BLOCKED' -and $result.Output -match 'preventTempProfile needs a newer session host prep script') 'Preview must block preventTempProfile with a pinned prep script that does not support it.'
    Write-Pass 'Preview blocks FSLogix sign-in protection when the pinned prep script is too old.'

    $env:AVDV2_RETRY_DELAY_SECONDS = '0'
    Reset-State @{ Prefix = 'TSTSH'; FilesForbidden = 1 }
    $global:AvdTest.Graph.App.identifierUris = @("api://$tenantId/HOST/$account.file.core.windows.net", "CIFS/$account.file.core.windows.net")
    $global:AvdTest.Graph.Devices = @{
        'TSTSH-0' = @(@{ displayName = 'TSTSH-0'; trustType = 'AzureAd'; isManaged = $true; operatingSystemVersion = '10.0.26100.8200'; approximateLastSignInDateTime = '2026-10-14T20:00:00Z' })
        'TSTSH-1' = @(
            @{ displayName = 'TSTSH-1'; trustType = 'AzureAd'; isManaged = $true; operatingSystemVersion = '10.0.26100.9000'; approximateLastSignInDateTime = '2026-01-01T00:00:00Z' },
            @{ displayName = 'TSTSH-1'; trustType = 'AzureAd'; isManaged = $false; operatingSystemVersion = '10.0.26100.4000'; approximateLastSignInDateTime = '2026-10-14T21:00:00Z' })
    }
    $result = Invoke-Cli @('-Mode', 'PostDeploy', '-ConfigurationFile', $discovered, '-ConditionalAccess', 'Exclude')
    $post = $global:AvdTest.Post
    Assert-True (-not $result.Error) "PostDeploy failed: $($result.Error)"
    Assert-True ($post -contains 'rdp-enable' -and $post -contains 'consent:storage-sp>graph-sp=openid profile User.Read' -and $post -contains 'app:tags=kdc_enable_cloud_group_sids;uris=4') "PostDeploy should enable Entra RDP auth, consent, tag and add private-link URIs, got $($post -join ', ')"
    Assert-True (@($global:AvdTest.Graph.App.identifierUris) -contains "api://$tenantId/HOST/$account.privatelink.file.core.windows.net" -and @($global:AvdTest.Graph.App.identifierUris) -contains "CIFS/$account.privatelink.file.core.windows.net") 'Private-link identifier URIs should mirror the existing ones.'
    Assert-True ($post -contains 'ca:101 - MFA For All' -and -not ($post -match '^ca:(Office|Priv|Microsoft)')) "Only the all-resources MFA policy should be changed, got $($post -join ', ')"
    Assert-True ($result.Output -match 'Microsoft-managed policies cannot exclude apps' -and $result.Output -match "Review Conditional Access policy 'Priv - Restrict Access to cPAW only'") 'Managed and device/privileged policies should be reported for review.'
    $aclIndex = [array]::IndexOf($post.ToArray(), "acl:profiles=O:BAG:SYD:P(A;OICIIO;0x1301bf;;;CO)(A;;0x1301bf;;;$usersSid)(A;OICI;FA;;;$adminsSid)(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)")
    Assert-True ($aclIndex -gt 0 -and $post -contains "acl:redirections=O:BAG:SYD:P(A;OICI;0x1200a9;;;$usersSid)(A;OICI;FA;;;$adminsSid)(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)") "FSLogix ACLs should use the cloud group SIDs, got $($post -join ', ')"
    $openIndex = [array]::IndexOf($post.ToArray(), 'storage:Enabled=203.0.113.7')
    $closeIndex = [array]::IndexOf($post.ToArray(), 'storage:Disabled=')
    Assert-True ($openIndex -ge 0 -and $openIndex -lt $aclIndex -and $closeIndex -gt $aclIndex -and $global:AvdTest.StorageState.properties.publicNetworkAccess -eq 'Disabled' -and @($global:AvdTest.StorageState.properties.networkAcls.ipRules).Count -eq 0) "The storage firewall must open only for this IP around the ACL calls and be restored, got $($post -join ', ')"
    Assert-True ($post -contains 'role-add:69566ab7-960f-475b-8e7c-b3118f30c6bd' -and $post -contains 'role-remove:69566ab7-960f-475b-8e7c-b3118f30c6bd' -and $post -contains 'detect-ip') 'The temporary data role should be added and removed, and the public IP detected.'
    Assert-True ($result.Output -match 'TSTSH-0: Microsoft Entra joined, Intune managed' -and $result.Output -match 'TSTSH-1 has 2 Entra device records' -and $result.Output -match 'needs 26100\.8116 or later' -and $result.Output -match 'TSTSH-1: Microsoft Entra joined, not Intune managed') 'Device checks should report join, Intune, stale records and the cloud-only build.'
    Write-Pass 'PostDeploy enables Entra RDP auth, configures the storage app, excludes it from MFA policies and sets FSLogix ACLs behind a temporary firewall rule.'

    $post.Clear()
    $result = Invoke-Cli @('-Mode', 'PostDeploy', '-ConfigurationFile', $discovered, '-ConditionalAccess', 'Exclude', '-OperatorPublicIp', '198.51.100.9')
    Assert-True (-not $result.Error -and -not ($post -match '^(rdp-enable|consent|app:|ca:|detect-ip)') -and $post -contains 'storage:Enabled=198.51.100.9') "A second PostDeploy should change nothing in Entra, got $($post -join ', ')"
    Assert-True ($result.Output -match 'already enabled' -and $result.Output -match 'consent for the storage account app was already granted' -and $result.Output -match 'No MFA Conditional Access policy needs') 'A rerun should report what was already in place.'
    Write-Pass 'PostDeploy is idempotent and accepts an explicit operator IP.'

    Reset-State @{ Prefix = 'TSTSH'; FilesForbidden = 1000 }
    $result = Invoke-Cli @('-Mode', 'PostDeploy', '-ConfigurationFile', $discovered, '-ConditionalAccess', 'Report')
    $post = $global:AvdTest.Post
    Assert-True (-not ($post -match '^ca:') -and $result.Output -match "Exclude '\[Storage Account\] $account\.file\.core\.windows\.net' from Conditional Access policy '101 - MFA For All'") 'Report mode must not change Conditional Access and should list the exclusions to make.'
    Assert-True ($result.Output -match 'automatic setup failed' -and $post -contains 'storage:Disabled=' -and $post -contains 'role-remove:69566ab7-960f-475b-8e7c-b3118f30c6bd' -and $global:AvdTest.StorageState.properties.publicNetworkAccess -eq 'Disabled') "A failed ACL step must still restore the firewall and remove the role, got $($post -join ', ')"
    Write-Pass 'Report mode leaves Conditional Access alone, and a failed ACL step always restores the storage firewall.'

    $hybrid = Get-Content -LiteralPath $happy -Raw | ConvertFrom-Json -AsHashtable
    Reset-State
    $result = Invoke-Cli @('-Mode', 'PostDeploy', '-ConfigurationFile', $happy, '-ConditionalAccess', 'Report')
    Assert-True ($result.Output -match 'not synced from Active Directory' -and -not ($global:AvdTest.Post -match '^(storage|acl|app:tags=kdc)')) "Hybrid estates with unsynced groups must not open storage or add the cloud-only tag, got $($global:AvdTest.Post -join ', ')"
    Reset-State
    $global:AvdTest.Graph.HybridSids = @{ $hybrid.accessGroups.usersObjectId = 'S-1-5-21-1-2-3-1001'; $hybrid.accessGroups.adminsObjectId = 'S-1-5-21-1-2-3-1002' }
    $result = Invoke-Cli @('-Mode', 'PostDeploy', '-ConfigurationFile', $happy, '-ConditionalAccess', 'Report', '-OperatorPublicIp', '198.51.100.9')
    Assert-True ($global:AvdTest.Post -contains 'acl:profiles=O:BAG:SYD:P(A;OICIIO;0x1301bf;;;CO)(A;;0x1301bf;;;S-1-5-21-1-2-3-1001)(A;OICI;FA;;;S-1-5-21-1-2-3-1002)(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)') "Hybrid ACLs should use the on-premises group SIDs, got $($global:AvdTest.Post -join ', ')"
    Write-Pass 'hybrid PostDeploy uses on-premises group SIDs and skips ACLs when groups are not synced.'

    Reset-State @{ SecretExists = $true; FoundationDone = $true; Prefix = 'TSTSH' }
    $null = Invoke-Cli @('-Mode', 'Preview', '-ConfigurationFile', $discovered)
    Reset-State @{ SecretExists = $true; FoundationDone = $true; Prefix = 'TSTSH' }
    $result = Invoke-Cli @('-Mode', 'Deploy', '-ConfigurationFile', $discovered, '-AsSignedInUser', '-Approve', 'rg-tst-avd', '-RegistrationWaitMinutes', '0', '-PostDeploy', '-ConditionalAccess', 'Exclude', '-OperatorPublicIp', '198.51.100.9')
    Assert-True (-not $result.Error -and $result.Output -match 'Post-deployment configuration:' -and $result.Output -notmatch 'PREVIEW cloud-only FSLogix: grant admin consent' -and $result.Output -notmatch 'to automate the Microsoft Entra') "Deploy -PostDeploy should replace the generic Entra reminders with the actual results: $($result.Error)"
    Remove-Item Env:\AVDV2_RETRY_DELAY_SECONDS
    Write-Pass 'Deploy -PostDeploy runs the post-deployment configuration and reports only what is left.'

    Write-Host "$passed Preview/Deploy orchestration tests passed."
} finally {
    Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($name in 'Get-AzContext', 'Connect-AzAccount', 'Set-AzContext', 'Get-AzResourceGroup', 'Get-AzVirtualNetwork', 'Get-AzRoleAssignment',
        'Get-AzResourceGroupDeploymentWhatIfResult', 'Get-AzWvdHostPool', 'Get-AzKeyVaultSecret', 'New-AzResourceGroupDeployment',
        'Update-AzWvdHostPool', 'Get-AzWvdHostPoolRegistrationToken', 'Get-AzWvdSessionHost', 'Update-AzWvdSessionHost', 'Invoke-WebRequest',
        'Get-MgContext', 'Connect-MgGraph', 'Invoke-MgGraphRequest', 'Get-AzResourceProvider', 'Register-AzResourceProvider', 'Get-AzLocation',
        'Get-AzSubscription', 'Get-AzADGroup', 'Get-AzADServicePrincipal', 'Get-AzADUser', 'Get-AzResource', 'Get-AzKeyVault', 'Invoke-AzRestMethod',
        'Get-AzDeploymentWhatIfResult', 'New-AzDeployment', 'Test-AzResourceGroupDeployment', 'New-AzADGroup', 'New-AzADGroupOwner', 'Add-AzADGroupMember',
        'Update-AzWvdDesktop', 'New-AzRoleAssignment', 'Remove-AzRoleAssignment', 'Get-AzAccessToken', 'Invoke-RestMethod', 'New-GraphError') {
        Remove-Item -LiteralPath "Function:\$name" -ErrorAction SilentlyContinue
    }
}
