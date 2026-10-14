#requires -Version 7.2
Set-StrictMode -Version Latest

# Azure/Entra orchestration for avd.ps1 -Mode Preview and -Mode Deploy.
# Preview is read-only. Deploy only runs a fresh, blocker-free plan whose hashes still match.

$script:V2Root = Split-Path $PSScriptRoot -Parent
$script:PowerOnOffRoleId = '40c5ff49-9181-41f8-ae61-143b0e78555e'
$script:PlanLifetimeHours = 24
$script:RequiredAzCommands = [ordered]@{
    'Az.Accounts'              = @('Get-AzContext', 'Connect-AzAccount', 'Set-AzContext')
    'Az.Resources'             = @('Get-AzResourceGroup', 'Get-AzResourceGroupDeploymentWhatIfResult', 'New-AzResourceGroupDeployment', 'Get-AzRoleAssignment')
    'Az.Network'               = @('Get-AzVirtualNetwork')
    'Az.DesktopVirtualization' = @('Get-AzWvdHostPool', 'Update-AzWvdHostPool', 'Get-AzWvdHostPoolRegistrationToken', 'Get-AzWvdSessionHost', 'Update-AzWvdSessionHost')
    'Az.KeyVault'              = @('Get-AzKeyVaultSecret')
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
    }
    if ($Configuration.Contains('storage')) { $parameters.storageAccountName = $Configuration.storage.accountName }
    return $parameters
}

function Get-AvdSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
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
    } catch {
        return [pscustomobject]@{ Ok = $false; Message = "Session host prep script could not be downloaded from $($Configuration.artifacts.sessionHostPrepUri)." }
    } finally {
        Remove-Item -LiteralPath $temporaryFile -Force -ErrorAction SilentlyContinue
    }
    if ($actual -ne $Configuration.artifacts.sessionHostPrepSha256.ToLowerInvariant()) {
        return [pscustomobject]@{ Ok = $false; Message = "Session host prep script SHA-256 is $actual but the configuration expects $($Configuration.artifacts.sessionHostPrepSha256). Publish the reviewed v2/scripts/session-host-prep.ps1 and record its hash." }
    }
    return [pscustomobject]@{ Ok = $true; Message = "Session host prep script digest verified ($actual)." }
}

function Get-AvdAdminPassword {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Configuration)

    $match = [regex]::Match($Configuration.sessionHosts.adminPasswordSecretUri, '^https://(?<vault>[^.]+)\.vault\.azure\.net/secrets/(?<name>[^/?#]+)(?:/(?<version>[^/?#]+))?$')
    $arguments = @{ VaultName = $match.Groups['vault'].Value; Name = $match.Groups['name'].Value; ErrorAction = 'Stop' }
    if ($match.Groups['version'].Success) { $arguments.Version = $match.Groups['version'].Value }
    try {
        $secret = Get-AzKeyVaultSecret @arguments
    } catch {
        throw "The session host admin password could not be read from Key Vault secret '$($arguments.Name)' in '$($arguments.VaultName)'. Check the secret exists and you have Key Vault Secrets User."
    }
    if (-not $secret -or -not $secret.SecretValue) {
        throw "Key Vault secret '$($arguments.Name)' in '$($arguments.VaultName)' was not found."
    }
    return $secret.SecretValue
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

function Get-AvdManualTasks {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Configuration)

    $tasks = [System.Collections.Generic.List[string]]::new()
    switch ($Configuration.profile) {
        'AzureFilesHybridKerberos' {
            $tasks.Add('Grant admin consent to the storage account''s Entra app, exclude it from MFA Conditional Access, and set FSLogix share/folder ACLs from a machine that can reach a domain controller.')
        }
        'AzureFilesEntraKerberosCloudOnly' {
            $tasks.Add('PREVIEW cloud-only FSLogix: grant admin consent to the storage account''s Entra app, add the cloud group SID manifest tag, exclude only that app from MFA Conditional Access, and set share/folder permissions (see ADR 0011).')
        }
    }
    if (-not $Configuration.network.deployPrivateDns) {
        $tasks.Add('Custom DNS: make sure the storage private endpoint resolves (forward privatelink.file.core.windows.net to Azure DNS or add records).')
    }
    $tasks.Add('Sign in as a test user from the AVD users group and confirm the desktop launches and the profile persists.')
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

    $resourceGroup = Get-AzResourceGroup -Name $resourceGroupName -ErrorAction SilentlyContinue
    if (-not $resourceGroup) {
        $blockers.Add("Resource group '$resourceGroupName' does not exist. Create it (or ask your Azure administrator) before deploying.")
    } elseif ($resourceGroup.Location -ne $Configuration.target.location) {
        $blockers.Add("Resource group '$resourceGroupName' is in '$($resourceGroup.Location)' but the configuration says '$($Configuration.target.location)'.")
    }

    $network = $Configuration.network
    $virtualNetwork = Get-AzVirtualNetwork -ResourceGroupName $network.resourceGroupName -Name $network.virtualNetworkName -ErrorAction SilentlyContinue
    if (-not $virtualNetwork) {
        $blockers.Add("Virtual network '$($network.virtualNetworkName)' was not found in resource group '$($network.resourceGroupName)'.")
    } else {
        $subnetNames = @($virtualNetwork.Subnets | ForEach-Object { $_.Name })
        foreach ($subnet in @($network.sessionHostSubnetName, $network.privateEndpointSubnetName) | Select-Object -Unique) {
            if ($subnet -notin $subnetNames) {
                $blockers.Add("Subnet '$subnet' was not found in virtual network '$($network.virtualNetworkName)'.")
            }
        }
    }

    $artifact = Test-AvdArtifactDigest -Configuration $Configuration
    if ($artifact.Ok) { Write-Host $artifact.Message } else { $blockers.Add($artifact.Message) }

    if ($Configuration.Contains('scaling')) {
        try {
            $powerRole = @(Get-AzRoleAssignment -ObjectId $Configuration.identity.avdServicePrincipalObjectId -Scope "/subscriptions/$($Configuration.subscriptionId)" -ErrorAction Stop |
                    Where-Object { $_.RoleDefinitionId -match $script:PowerOnOffRoleId -and $_.Scope -eq "/subscriptions/$($Configuration.subscriptionId)" })
            if ($powerRole.Count -eq 0) {
                $warnings.Add("Autoscale prerequisite missing: assign 'Desktop Virtualization Power On Off Contributor' to the Azure Virtual Desktop service principal at subscription scope. The scaling plan deploys but cannot start/stop hosts until then.")
            }
        } catch {
            $warnings.Add('Could not verify the autoscale power role at subscription scope (needs role assignment read access). Check it manually.')
        }
    }

    if ($Configuration.profile -eq 'AzureFilesEntraKerberosCloudOnly') {
        $warnings.Add('Cloud-only FSLogix is a Microsoft PREVIEW feature and needs the admin prerequisites in ADR 0011.')
    }

    if ($blockers.Count -eq 0) {
        Write-Host ''
        Write-Host "What-if: platform ($hostPoolName, app group, workspace$(if ($Configuration.profile -ne 'LocalProfile') { ', FSLogix storage' })$(if ($Configuration.Contains('scaling')) { ', scaling plan' }))"
        $platformResult = Get-AzResourceGroupDeploymentWhatIfResult -ResourceGroupName $resourceGroupName -TemplateFile (Join-Path $script:V2Root 'infra/avd/platform.bicep') -TemplateParameterObject (Get-AvdPlatformParameters -Configuration $Configuration) -ErrorAction Stop
        $platformResult | Out-Host
        foreach ($change in @($platformResult.Changes)) { $changes.Add([ordered]@{ stage = 'platform'; resourceId = [string]$change.ResourceId; changeType = [string]$change.ChangeType }) }

        $existingPool = Get-AzWvdHostPool -ResourceGroupName $resourceGroupName -Name $hostPoolName -ErrorAction SilentlyContinue
        if ($existingPool) {
            Write-Host "What-if: $($Configuration.sessionHosts.count) session host(s)"
            $hostParameters = Get-AvdSessionHostParameters -Configuration $Configuration -AdminPassword (New-AvdPlaceholderSecret) -RegistrationToken (New-AvdPlaceholderSecret)
            $hostResult = Get-AzResourceGroupDeploymentWhatIfResult -ResourceGroupName $resourceGroupName -TemplateFile (Join-Path $script:V2Root 'infra/avd/session-hosts.bicep') -TemplateParameterObject $hostParameters -ErrorAction Stop
            $hostResult | Out-Host
            foreach ($change in @($hostResult.Changes)) { $changes.Add([ordered]@{ stage = 'sessionHosts'; resourceId = [string]$change.ResourceId; changeType = [string]$change.ChangeType }) }
        } else {
            $warnings.Add("Host pool '$hostPoolName' does not exist yet, so the session-host stage cannot be previewed in Azure. Deploy creates the platform first, then $($Configuration.sessionHosts.count) host(s) named $($Configuration.sessionHosts.namePrefix)-0 onward.")
        }
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
    $adminPassword = Get-AvdAdminPassword -Configuration $Configuration
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddHHmmss')

    Write-Host "Deploying AVD platform to $resourceGroupName..."
    $platform = New-AzResourceGroupDeployment -Name "avdv2-platform-$stamp" -ResourceGroupName $resourceGroupName -TemplateFile (Join-Path $script:V2Root 'infra/avd/platform.bicep') -TemplateParameterObject (Get-AvdPlatformParameters -Configuration $Configuration) -ErrorAction Stop
    if ($platform.ProvisioningState -ne 'Succeeded') {
        throw 'The AVD platform deployment did not succeed. Session hosts were not deployed.'
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

    $manualTasks = Get-AvdManualTasks -Configuration $Configuration
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

    [pscustomobject]@{
        ResourceGroup     = $resourceGroupName
        HostPool          = $hostPoolName
        SessionHosts      = @($registered | ForEach-Object { "$($_.ComputerName) ($($_.Status))" })
        Assignments       = @($assignedHosts)
        AddedToUsersGroup = $groupMembers
        ManualTasks       = @($manualTasks)
    }
}

Export-ModuleMember -Function Invoke-AvdPreview, Invoke-AvdDeploy, Get-AvdPlatformParameters, Get-AvdSessionHostParameters, Get-AvdTemplateHash
