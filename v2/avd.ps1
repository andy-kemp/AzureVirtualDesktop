#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Validate', 'Build')]
    [string]$Mode,
    [string]$ConfigurationFile = (Join-Path $PSScriptRoot 'config/avd.example.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$schemaPath = Join-Path $PSScriptRoot 'contracts/avd-config.schema.json'
$templatePaths = @(
    (Join-Path $PSScriptRoot 'infra/avd/platform.bicep'),
    (Join-Path $PSScriptRoot 'infra/avd/session-hosts.bicep')
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

    return $configuration
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

$configuration = Read-ValidatedConfiguration -Path $ConfigurationFile
Write-Output "Configuration valid: tenant $($configuration.tenantId), subscription $($configuration.subscriptionId), resource group $($configuration.target.resourceGroupName), hosts $($configuration.sessionHosts.count)."

if ($Mode -eq 'Build') {
    foreach ($templatePath in $templatePaths) {
        Invoke-BicepBuild -TemplatePath $templatePath
        Write-Output "Bicep compiled: $([System.IO.Path]::GetRelativePath($PSScriptRoot, $templatePath))"
    }
}