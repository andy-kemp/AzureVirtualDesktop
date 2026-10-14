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
        PowerRole      = $false
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
function global:Get-AzResourceGroup { param($Name, $ErrorAction) if (-not $global:AvdTest.MissingRg) { [pscustomobject]@{ ResourceGroupName = $Name; Location = 'uksouth' } } }
function global:Get-AzVirtualNetwork {
    param($ResourceGroupName, $Name, $ErrorAction)
    [pscustomobject]@{ Subnets = @([pscustomobject]@{ Name = 'session-hosts' }, [pscustomobject]@{ Name = 'private-endpoints' }) }
}
function global:Get-AzRoleAssignment {
    param($ObjectId, $Scope, $ErrorAction)
    if ($global:AvdTest.PowerRole) { [pscustomobject]@{ RoleDefinitionId = '40c5ff49-9181-41f8-ae61-143b0e78555e'; Scope = $Scope } }
}
function global:Get-AzResourceGroupDeploymentWhatIfResult {
    param($ResourceGroupName, $TemplateFile, $TemplateParameterObject, $ErrorAction)
    $stage = if ($TemplateFile -like '*session-hosts.bicep') { 'hosts' } else { 'platform' }
    $global:AvdTest.Calls.Add("whatif-$stage")
    [pscustomobject]@{ Changes = @([pscustomobject]@{ ResourceId = "/mock/$stage"; ChangeType = 'Create' }) }
}
function global:Get-AzWvdHostPool { param($ResourceGroupName, $Name, $ErrorAction) if ($global:AvdTest.ExistingPool) { [pscustomobject]@{ Name = $Name } } }
function global:Get-AzKeyVaultSecret {
    param($VaultName, $Name, $Version, $ErrorAction)
    $global:AvdTest.Calls.Add('read-secret')
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
function global:Invoke-WebRequest { param($Uri, $OutFile, [switch]$UseBasicParsing) Copy-Item -LiteralPath $global:AvdTest.PrepScript -Destination $OutFile }
function global:Get-MgContext { [pscustomobject]@{ TenantId = $global:AvdTest.Tenant; Scopes = $global:AvdTest.GraphScopes } }
function global:Connect-MgGraph { param($TenantId, $Scopes, [switch]$NoWelcome) $global:AvdTest.Calls.Add('connect-graph'); $global:AvdTest.GraphScopes = $Scopes }
function global:Invoke-MgGraphRequest {
    param($Method, $Uri, $Body, $OutputType, $ErrorAction)
    if ($Method -eq 'POST') {
        $objectId = ($Body.'@odata.id' -split '/')[-1]
        $global:AvdTest.Calls.Add("group-add:$objectId")
        # Like Microsoft.Graph.Authentication 2.x: status line in the exception, service error body in ErrorDetails.
        $serviceMessage = if ($global:AvdTest.GraphDenied) { 'Insufficient privileges to complete the operation.' }
        elseif ($objectId -in $global:AvdTest.GraphExisting) { 'One or more added object references already exist for the following modified properties: ''members''.' }
        if ($serviceMessage) {
            $record = [System.Management.Automation.ErrorRecord]::new([System.Exception]::new('Response status code does not indicate success: BadRequest (Bad Request).'), 'GraphError', 'InvalidOperation', $null)
            $record.ErrorDetails = [System.Management.Automation.ErrorDetails]::new("{`"error`":{`"message`":`"$serviceMessage`"}}")
            throw $record
        }
    }
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
    Assert-True ($plan.blockers.Count -eq 0 -and ($plan.warnings -join ' ') -match 'does not exist yet' -and ($plan.warnings -join ' ') -match 'Power On Off Contributor') 'Fresh preview should warn about the core-only preview and the missing power role.'
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
    Assert-True ($result.Output -match 'Power On Off Contributor' -and $result.Output -match 'Registration token revoked') 'Deploy should report the missing power role and token revocation.'
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

    Write-Host "$passed Preview/Deploy orchestration tests passed."
} finally {
    Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($name in 'Get-AzContext', 'Connect-AzAccount', 'Set-AzContext', 'Get-AzResourceGroup', 'Get-AzVirtualNetwork', 'Get-AzRoleAssignment',
        'Get-AzResourceGroupDeploymentWhatIfResult', 'Get-AzWvdHostPool', 'Get-AzKeyVaultSecret', 'New-AzResourceGroupDeployment',
        'Update-AzWvdHostPool', 'Get-AzWvdHostPoolRegistrationToken', 'Get-AzWvdSessionHost', 'Update-AzWvdSessionHost', 'Invoke-WebRequest',
        'Get-MgContext', 'Connect-MgGraph', 'Invoke-MgGraphRequest') {
        Remove-Item -LiteralPath "Function:\$name" -ErrorAction SilentlyContinue
    }
}
