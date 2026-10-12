#requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$examplePath = Join-Path $repoRoot 'avd.config.example.psd1'
$baseConfiguration = Import-PowerShellDataFile $examplePath
foreach ($key in @('SubscriptionId', 'KerberosDomainGuid', 'AvdUsersGroupOid', 'AvdAdminsGroupOid')) {
    $baseConfiguration[$key] = [guid]::NewGuid().ToString()
}
$testState = @{}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Import-PowerShellDataFile { param($LiteralPath) $testState.Configuration.Clone() }
function Get-Command { param($Name, $ErrorAction) 'mock-bicep' }
function Get-Module { param([switch]$ListAvailable, $Name) 'mock-module' }
function Import-Module { param($Name) }
function Get-AzContext { [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = $baseConfiguration.SubscriptionId } } }
function Set-AzContext { param($SubscriptionId) }
function Connect-AzAccount { throw 'Unexpected authentication attempt in offline tests.' }
function Get-AzADServicePrincipal { param($ApplicationId) [pscustomobject]@{ Id = '11111111-1111-1111-1111-111111111111' } }
function Get-AzWvdHostPool {
    param($ResourceGroupName, $Name, $ErrorAction)
    if ($testState.ExistingPool) { [pscustomobject]@{ Name = $Name } }
}
function Test-AzSubscriptionDeployment {
    param($Location, $TemplateFile, $TemplateParameterObject, $ErrorAction)
    $testState.Calls.Add('validate-platform')
    if ($testState.ValidationFailure) { [pscustomobject]@{ Message = 'mock-validation-failure' } }
}
function Test-AzResourceGroupDeployment {
    param($ResourceGroupName, $TemplateFile, $TemplateParameterObject, $ErrorAction)
    $testState.Calls.Add('validate-hosts')
}
function Get-AzSubscriptionDeploymentWhatIfResult {
    param($Location, $TemplateFile, $TemplateParameterObject, $ErrorAction)
    $testState.Calls.Add('preview-platform')
}
function Get-AzResourceGroupDeploymentWhatIfResult {
    param($ResourceGroupName, $TemplateFile, $TemplateParameterObject, $ErrorAction)
    $testState.Calls.Add('preview-hosts')
}
function New-AzSubscriptionDeployment {
    param($Location, $TemplateFile, $TemplateParameterObject, $ErrorAction, $Name)
    $testState.Calls.Add('deploy-platform')
    Assert-True ($TemplateParameterObject.avdServicePrincipalOid -eq '11111111-1111-1111-1111-111111111111') 'AVD service principal was not forwarded.'
    if ($testState.PlatformFailure) { throw 'mock-platform-failure' }
    [pscustomobject]@{ ProvisioningState = 'Succeeded'; Outputs = @{ workspaceId = @{ Value = 'mock-workspace' } } }
}
function New-AzWvdRegistrationInfo {
    param($ResourceGroupName, $HostPoolName, $ExpirationTime)
    $testState.Calls.Add('create-token')
    Assert-True ($HostPoolName -eq 'AVD-HostPool') 'Wrong host pool selected.'
    [pscustomobject]@{ Token = 'mock-secret-token' }
}
function New-AzResourceGroupDeployment {
    param($ResourceGroupName, $TemplateFile, $TemplateParameterObject, $ErrorAction, $Name)
    $testState.Calls.Add('deploy-hosts')
    Assert-True ($TemplateParameterObject.adminPassword -is [securestring]) 'Password is not secure.'
    Assert-True ($TemplateParameterObject.hostPoolRegistrationInfoToken -is [securestring]) 'Registration token is not secure.'
    Assert-True ($TemplateParameterObject.hostPoolName -eq 'AVD-HostPool') 'Pool name must be independent of VM prefix.'
    Assert-True ($TemplateParameterObject.sessionHostPrefix -eq 'DESKTOP') 'VM prefix was not forwarded.'
    if ($testState.HostFailure) { throw 'mock-host-failure' }
    [pscustomobject]@{ ProvisioningState = 'Succeeded' }
}
function Remove-AzWvdRegistrationInfo {
    param($ResourceGroupName, $HostPoolName, $ErrorAction)
    $testState.Calls.Add('remove-token')
    if ($testState.CleanupFailure) { throw 'mock-cleanup-failure' }
}
function Get-AzWvdSessionHost {
    param($ResourceGroupName, $HostPoolName)
    $testState.Calls.Add('verify-hosts')
    if (-not $testState.MissingHost) {
        [pscustomobject]@{ Name = 'AVD-HostPool/DESKTOP-0.contoso.com'; Status = 'Available' }
        [pscustomobject]@{ Name = 'AVD-HostPool/DESKTOP-1.contoso.com'; Status = 'Available' }
    }
}

$cases = @(
    @{ Name = 'Fresh preview does not deploy'; Mode = 'Preview'; Expected = 'preview-platform' }
    @{ Name = 'Existing preview covers both stages'; Mode = 'Preview'; ExistingPool = $true; Expected = 'preview-platform,preview-hosts' }
    @{ Name = 'Existing validation covers both stages'; Mode = 'Validate'; ExistingPool = $true; Expected = 'validate-platform,validate-hosts' }
    @{ Name = 'Validation errors fail'; Mode = 'Validate'; ValidationFailure = $true; Error = 'mock-validation-failure'; Expected = 'validate-platform' }
    @{ Name = 'Deployment order and secure values'; Mode = 'Deploy'; Expected = 'deploy-platform,create-token,deploy-hosts,remove-token,verify-hosts' }
    @{ Name = 'Platform failure stops hosts'; Mode = 'Deploy'; PlatformFailure = $true; Error = 'mock-platform-failure'; Expected = 'deploy-platform' }
    @{ Name = 'Host failure cleans token'; Mode = 'Deploy'; HostFailure = $true; Error = 'mock-host-failure'; Expected = 'deploy-platform,create-token,deploy-hosts,remove-token' }
    @{ Name = 'Cleanup failure is surfaced'; Mode = 'Deploy'; CleanupFailure = $true; Error = 'mock-cleanup-failure'; Expected = 'deploy-platform,create-token,deploy-hosts,remove-token' }
    @{ Name = 'Missing host registration fails'; Mode = 'Deploy'; MissingHost = $true; Error = 'registration could not be verified'; Expected = 'deploy-platform,create-token,deploy-hosts,remove-token,verify-hosts' }
    @{ Name = 'Missing configuration is rejected'; Mode = 'Preview'; RemoveKey = 'VmSize'; Error = "missing 'VmSize'"; Expected = '' }
    @{ Name = 'Placeholder GUID is rejected'; Mode = 'Preview'; InvalidGuid = $true; Error = 'non-empty GUID'; Expected = '' }
    @{ Name = 'Invalid host count is rejected'; Mode = 'Preview'; InvalidCount = $true; Error = 'between 1 and 100'; Expected = '' }
)

foreach ($case in $cases) {
    $testState = @{
        Configuration = $baseConfiguration.Clone()
        Calls = [System.Collections.Generic.List[string]]::new()
        ExistingPool = $false; ValidationFailure = $false; PlatformFailure = $false
        HostFailure = $false; CleanupFailure = $false; MissingHost = $false
    }
    $testState.Configuration.SessionHostPrefix = 'DESKTOP'
    foreach ($flag in @('ExistingPool', 'ValidationFailure', 'PlatformFailure', 'HostFailure', 'CleanupFailure', 'MissingHost')) {
        if ($case.ContainsKey($flag)) { $testState[$flag] = $case[$flag] }
    }
    if ($case.RemoveKey) { $testState.Configuration.Remove($case.RemoveKey) }
    if ($case.InvalidGuid) { $testState.Configuration.SubscriptionId = [guid]::Empty.ToString() }
    if ($case.InvalidCount) { $testState.Configuration.NumberOfHosts = 0 }
    $caughtError = $null
    try {
        $result = & (Join-Path $repoRoot 'Deploy-AvdSolution.ps1') -ConfigurationFile $examplePath -Mode $case.Mode -AdminPassword (ConvertTo-SecureString 'mock-password' -AsPlainText -Force) -WarningAction SilentlyContinue
    } catch {
        $caughtError = $_.Exception.Message
    }
    if ($case.Error) {
        Assert-True ($caughtError -like "*$($case.Error)*") "$($case.Name): expected '$($case.Error)', got '$caughtError'."
    } else {
        Assert-True (-not $caughtError) "$($case.Name): unexpected error '$caughtError'."
    }
    Assert-True (($testState.Calls -join ',') -eq $case.Expected) "$($case.Name): unexpected call sequence '$($testState.Calls -join ',')'."
    Assert-True (($result | Out-String) -notmatch 'mock-secret-token') 'Secret leaked into output.'
    Write-Host "PASS: $($case.Name)"
}
Write-Host "$($cases.Count) offline orchestration tests passed."