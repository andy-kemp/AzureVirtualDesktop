#requires -Version 7.2
<#
.SYNOPSIS
Deploys AVD infrastructure and session hosts from one non-secret configuration.
.DESCRIPTION
Uses Bicep for Azure resources and Az PowerShell for orchestration and temporary
host-pool registration. Does not change tenant Conditional Access or file ACLs.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ConfigurationFile,
    [ValidateSet('Validate', 'Preview', 'Deploy')]
    [string]$Mode = 'Preview',
    [securestring]$AdminPassword
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$configuration = Import-PowerShellDataFile -LiteralPath (Resolve-Path -LiteralPath $ConfigurationFile).Path
$requiredKeys = @(
    'SubscriptionId', 'ResourceGroupName', 'Location', 'DefaultPrefix',
    'StorageAccountName', 'KerberosDomainName', 'KerberosDomainGuid',
    'AvdUsersGroupOid', 'AvdAdminsGroupOid', 'VnetResourceGroup', 'VnetName',
    'PrivateEndpointSubnetName', 'SessionHostSubnetName', 'DeployPrivateDns',
    'SessionHostPrefix', 'NumberOfHosts', 'AdminUsername', 'VmSize',
    'Dns1', 'Dns2', 'SessionHostPrepScriptUrl'
)
foreach ($key in $requiredKeys) {
    if (-not $configuration.ContainsKey($key)) {
        throw "Configuration is missing '$key'. See avd.config.example.psd1."
    }
    if ($key -notin @('Dns1', 'Dns2') -and [string]::IsNullOrWhiteSpace([string]$configuration[$key])) {
        throw "Configuration '$key' cannot be blank."
    }
}
foreach ($key in @('SubscriptionId', 'KerberosDomainGuid', 'AvdUsersGroupOid', 'AvdAdminsGroupOid')) {
    $parsedGuid = [guid]::Empty
    if (-not [guid]::TryParse([string]$configuration[$key], [ref]$parsedGuid) -or $parsedGuid -eq [guid]::Empty) {
        throw "Configuration '$key' must be a non-empty GUID."
    }
}
if ($configuration.StorageAccountName -cnotmatch '^[a-z0-9]{3,24}$') {
    throw 'StorageAccountName must contain 3-24 lowercase letters or digits.'
}
if ($configuration.NumberOfHosts -isnot [int] -or $configuration.NumberOfHosts -lt 1 -or $configuration.NumberOfHosts -gt 100) {
    throw 'NumberOfHosts must be an integer between 1 and 100.'
}
if ($configuration.SessionHostPrefix -notmatch '^[a-zA-Z][a-zA-Z0-9-]{0,10}$') {
    throw 'SessionHostPrefix must start with a letter and contain at most 11 letters, digits or hyphens.'
}
if ($configuration.DeployPrivateDns -isnot [bool]) {
    throw 'DeployPrivateDns must be a Boolean.'
}
$prepUri = $null
if (-not [uri]::TryCreate($configuration.SessionHostPrepScriptUrl, [UriKind]::Absolute, [ref]$prepUri) -or
    $prepUri.Scheme -ne 'https' -or $prepUri.Query -or $prepUri.Fragment -or $prepUri.AbsolutePath -notlike '*.ps1') {
    throw 'SessionHostPrepScriptUrl must be a direct HTTPS .ps1 URL without a query or fragment.'
}
foreach ($key in @('Dns1', 'Dns2')) {
    $parsedAddress = $null
    if ($configuration[$key] -and -not [System.Net.IPAddress]::TryParse($configuration[$key], [ref]$parsedAddress)) {
        throw "Configuration '$key' must be an IP address or blank."
    }
}

if (-not (Get-Command bicep -ErrorAction SilentlyContinue)) {
    throw 'Install the standalone Bicep CLI and make bicep available on PATH before running Azure PowerShell deployments.'
}
foreach ($moduleName in @('Az.Accounts', 'Az.Resources', 'Az.DesktopVirtualization')) {
    if (-not (Get-Module -ListAvailable -Name $moduleName)) {
        throw "Install required modules first: Install-Module Az.Accounts, Az.Resources, Az.DesktopVirtualization -Scope CurrentUser"
    }
    Import-Module $moduleName
}
if (-not (Get-AzContext)) {
    Connect-AzAccount | Out-Null
}
Set-AzContext -SubscriptionId $configuration.SubscriptionId | Out-Null
$context = Get-AzContext
if ($context.Subscription.Id -ne $configuration.SubscriptionId) {
    throw 'The Azure context does not match the configured subscription.'
}
$avdPrincipals = @(Get-AzADServicePrincipal -ApplicationId '9cdead84-a844-4324-93f2-b2e6bb768d07')
if ($avdPrincipals.Count -ne 1) {
    throw 'The Azure Virtual Desktop service principal must already exist in this tenant.'
}

$platformParameters = @{}
foreach ($key in @(
    'ResourceGroupName', 'Location', 'DefaultPrefix', 'StorageAccountName',
    'KerberosDomainName', 'KerberosDomainGuid', 'AvdUsersGroupOid',
    'AvdAdminsGroupOid', 'VnetResourceGroup', 'VnetName',
    'PrivateEndpointSubnetName', 'DeployPrivateDns'
)) {
    $platformParameters[$key] = $configuration[$key]
}
$platformParameters.avdServicePrincipalOid = $avdPrincipals[0].Id
$platformArguments = @{
    Location = $configuration.Location
    TemplateFile = Join-Path $PSScriptRoot 'main.bicep'
    TemplateParameterObject = $platformParameters
    ErrorAction = 'Stop'
}
$hostPoolName = "$($configuration.DefaultPrefix)-HostPool"
$hostsArguments = @{
    ResourceGroupName = $configuration.ResourceGroupName
    TemplateFile = Join-Path $PSScriptRoot '02-Deploy-SessionHosts.Bicep'
    TemplateParameterObject = @{
        sessionHostPrefix = $configuration.SessionHostPrefix
        hostPoolName = $hostPoolName
        numberOfHosts = $configuration.NumberOfHosts
        adminUsername = $configuration.AdminUsername
        vmSize = $configuration.VmSize
        vNetResourceGroup = $configuration.VnetResourceGroup
        vNetName = $configuration.VnetName
        subnetName = $configuration.SessionHostSubnetName
        storageAccountName = $configuration.StorageAccountName
        dns1 = $configuration.Dns1
        dns2 = $configuration.Dns2
        sessionHostPrepScriptUrl = $configuration.SessionHostPrepScriptUrl
    }
    ErrorAction = 'Stop'
}

if ($Mode -ne 'Deploy') {
    if ($Mode -eq 'Validate') {
        $validationErrors = @(Test-AzSubscriptionDeployment @platformArguments)
        if ($validationErrors.Count -gt 0) {
            throw ($validationErrors | Out-String)
        }
    } else {
        Get-AzSubscriptionDeploymentWhatIfResult @platformArguments
    }
    $existingPool = Get-AzWvdHostPool -ResourceGroupName $configuration.ResourceGroupName -Name $hostPoolName -ErrorAction SilentlyContinue
    if ($existingPool) {
        if (-not $AdminPassword) {
            $AdminPassword = Read-Host 'Session host local administrator password' -AsSecureString
        }
        $hostsArguments.TemplateParameterObject.adminPassword = $AdminPassword
        $hostsArguments.TemplateParameterObject.hostPoolRegistrationInfoToken = ConvertTo-SecureString 'preview-only-not-a-registration-token' -AsPlainText -Force
        if ($Mode -eq 'Validate') {
            $validationErrors = @(Test-AzResourceGroupDeployment @hostsArguments)
            if ($validationErrors.Count -gt 0) {
                throw ($validationErrors | Out-String)
            }
        } else {
            Get-AzResourceGroupDeploymentWhatIfResult @hostsArguments
        }
    } else {
        Write-Warning 'Core-only preflight: session-host Azure validation/preview requires the resource group and host pool to exist. No resources were created.'
    }
    return
}

if (-not $AdminPassword) {
    $AdminPassword = Read-Host 'Session host local administrator password' -AsSecureString
}
Write-Host "Deploying AVD platform to $($configuration.ResourceGroupName)..."
$platformDeployment = New-AzSubscriptionDeployment @platformArguments -Name "$($configuration.DefaultPrefix)-platform"
if ($platformDeployment.ProvisioningState -ne 'Succeeded') {
    throw 'The AVD platform deployment did not succeed. Session hosts were not deployed.'
}

Write-Host 'Creating a temporary host-pool registration token...'
try {
    $registration = New-AzWvdRegistrationInfo -ResourceGroupName $configuration.ResourceGroupName -HostPoolName $hostPoolName -ExpirationTime ([DateTime]::UtcNow.AddHours(4).ToString('o'))
    if ([string]::IsNullOrWhiteSpace($registration.Token)) {
        throw 'Azure did not return a host-pool registration token.'
    }
    $hostsArguments.TemplateParameterObject.adminPassword = $AdminPassword
    $hostsArguments.TemplateParameterObject.hostPoolRegistrationInfoToken = ConvertTo-SecureString $registration.Token -AsPlainText -Force
    $registration = $null
    Write-Host "Deploying $($configuration.NumberOfHosts) session hosts..."
    $hostsDeployment = New-AzResourceGroupDeployment @hostsArguments -Name "$($configuration.DefaultPrefix)-hosts"
    if ($hostsDeployment.ProvisioningState -ne 'Succeeded') {
        throw 'The session-host deployment did not succeed.'
    }
} finally {
    Remove-AzWvdRegistrationInfo -ResourceGroupName $configuration.ResourceGroupName -HostPoolName $hostPoolName -ErrorAction Stop | Out-Null
    $hostsArguments.TemplateParameterObject.Remove('hostPoolRegistrationInfoToken')
}

$sessionHosts = @(Get-AzWvdSessionHost -ResourceGroupName $configuration.ResourceGroupName -HostPoolName $hostPoolName)
$expectedNames = @(0..($configuration.NumberOfHosts - 1) | ForEach-Object { "$($configuration.SessionHostPrefix)-$_" })
$registeredNames = @($sessionHosts | ForEach-Object { ($_.Name -split '/')[-1].Split('.')[0] })
$missingNames = @($expectedNames | Where-Object { $_ -notin $registeredNames })
if ($missingNames.Count -gt 0) {
    throw "VM deployment completed but host-pool registration could not be verified for: $($missingNames -join ', '). Check DSC extension status and rerun."
}
Write-Host 'Azure infrastructure deployed and session-host registration verified. User readiness still requires the checks below.'
Write-Warning 'Complete Azure Files Kerberos admin consent, approved Conditional Access exceptions, and NTFS share ACLs with your tenant/domain administrators. Custom DNS needs forwarding to Azure Private DNS or your existing DNS records.'
[pscustomobject]@{
    ResourceGroupName = $configuration.ResourceGroupName
    HostPoolName = $hostPoolName
    WorkspaceId = $platformDeployment.Outputs.workspaceId.Value
    SessionHosts = $sessionHosts | Select-Object Name, Status
    UserReadiness = 'Pending identity, DNS and file ACL verification'
}