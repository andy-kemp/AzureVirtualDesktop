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

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}

function Invoke-InvalidConfigurationCase {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Value,
        [Parameter(Mandatory)]
        [string]$Name
    )

    $path = Join-Path $temporaryDirectory "$Name.json"
    [System.IO.File]::WriteAllText($path, ($Value | ConvertTo-Json -Depth 32))
    $caughtError = $null
    try {
        $null = & $cliPath -Mode Validate -ConfigurationFile $path 2>&1
    } catch {
        $caughtError = $_.Exception.Message
    }
    Assert-True ($caughtError -match 'does not satisfy|must have different|longer than 15') "$Name was not rejected by the V2 CLI."
}

try {
    $validOutput = & $cliPath -Mode Validate -ConfigurationFile $examplePath
    Assert-True (($validOutput -join "`n") -match 'Configuration valid') 'Valid example configuration was not accepted.'
    Write-Host 'PASS: versioned example validates offline.'

    $plaintextSecret = $configuration.Clone()
    $plaintextSecret.sessionHosts = $configuration.sessionHosts.Clone()
    $plaintextSecret.sessionHosts.adminPassword = 'must-not-be-stored'
    Invoke-InvalidConfigurationCase -Value $plaintextSecret -Name 'plaintext-secret'
    Write-Host 'PASS: plaintext secrets are rejected.'

    $invalidHostCount = $configuration.Clone()
    $invalidHostCount.sessionHosts = $configuration.sessionHosts.Clone()
    $invalidHostCount.sessionHosts.count = 0
    Invoke-InvalidConfigurationCase -Value $invalidHostCount -Name 'invalid-host-count'
    Write-Host 'PASS: invalid host count is rejected.'

    $sameGroups = $configuration.Clone()
    $sameGroups.accessGroups = $configuration.accessGroups.Clone()
    $sameGroups.accessGroups.adminsObjectId = $sameGroups.accessGroups.usersObjectId
    Invoke-InvalidConfigurationCase -Value $sameGroups -Name 'duplicate-groups'
    Write-Host 'PASS: duplicate access groups are rejected.'

    $wrongIdentitySubscription = $configuration.Clone()
    $wrongIdentitySubscription.execution = $configuration.execution.Clone()
    $wrongIdentitySubscription.execution.deploymentIdentityResourceId = $wrongIdentitySubscription.execution.deploymentIdentityResourceId.Replace(
        $wrongIdentitySubscription.subscriptionId,
        '88888888-8888-4888-8888-888888888888'
    )
    $identityPath = Join-Path $temporaryDirectory 'wrong-identity-subscription.json'
    [System.IO.File]::WriteAllText($identityPath, ($wrongIdentitySubscription | ConvertTo-Json -Depth 32))
    $identityError = $null
    try {
        $null = & $cliPath -Mode Validate -ConfigurationFile $identityPath 2>&1
    } catch {
        $identityError = $_.Exception.Message
    }
    Assert-True ($identityError -like '*deployment UAMI must be in the configured customer subscription*') 'A UAMI from another subscription was not rejected.'
    Write-Host 'PASS: deployment UAMI is bound to the configured subscription.'

    $buildOutput = & $cliPath -Mode Build -ConfigurationFile $examplePath
    Assert-True (($buildOutput | Where-Object { $_ -match '^Bicep compiled:' }).Count -eq 2) 'Build did not compile both AVD templates.'
    Write-Host 'PASS: both isolated AVD Bicep entry points compile offline.'

    Write-Host '6 Phase 1 CLI tests passed.'
} finally {
    Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
}