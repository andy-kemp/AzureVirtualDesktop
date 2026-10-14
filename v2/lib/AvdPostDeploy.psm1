Set-StrictMode -Version Latest

# Post-deployment tenant and profile-share configuration for a V2 estate. Every step is idempotent, reports what it
# changed, and turns anything it cannot do into a manual task instead of failing the deployment.

$script:Graph = 'https://graph.microsoft.com/v1.0'
$script:WindowsCloudLoginAppId = '270efc09-cd0d-444b-a71f-39af4910ec45'
$script:MicrosoftGraphAppId = '00000003-0000-0000-c000-000000000000'
$script:StorageAppScopes = @('openid', 'profile', 'User.Read')
$script:CloudGroupSidTag = 'kdc_enable_cloud_group_sids'
$script:FilePrivilegedContributorRoleId = '69566ab7-960f-475b-8e7c-b3118f30c6bd'
$script:FilesApiVersion = '2024-08-04'
# Cloud-only FSLogix (preview) needs these builds or later (Windows 11 24H2/25H2 with KB5079391).
$script:MinimumCloudOnlyRevision = @{ 26100 = 8116; 26200 = 8116 }

function Get-AvdPostDeployScopes {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Configuration)
    $scopes = [System.Collections.Generic.List[string]]::new()
    foreach ($scope in 'Application-RemoteDesktopConfig.ReadWrite.All', 'Device.Read.All') { $scopes.Add($scope) }
    if ($Configuration.Contains('storage')) {
        foreach ($scope in 'Application.ReadWrite.All', 'DelegatedPermissionGrant.ReadWrite.All', 'Policy.Read.All', 'Policy.ReadWrite.ConditionalAccess') { $scopes.Add($scope) }
        if ($Configuration.profile -eq 'AzureFilesHybridKerberos') { $scopes.Add('Group.Read.All') }
    }
    return , $scopes.ToArray()
}

function Connect-AvdGraph {
    param([Parameter(Mandatory)][string]$TenantId, [Parameter(Mandatory)][string[]]$Scopes)
    if (-not (Get-Command Connect-MgGraph -ErrorAction SilentlyContinue)) { return $false }
    $context = Get-MgContext
    $missing = @($Scopes | Where-Object { -not $context -or @($context.Scopes) -notcontains $_ })
    if (-not $context -or $context.TenantId -ne $TenantId -or $missing.Count -gt 0) {
        Write-Host "Signing in to Microsoft Graph for tenant $TenantId (delegated: $($Scopes -join ', '))..."
        try { Connect-MgGraph -TenantId $TenantId -Scopes $Scopes -NoWelcome | Out-Null } catch { return $false }
        $context = Get-MgContext
    }
    return [bool]($context -and $context.TenantId -eq $TenantId)
}

function Get-AvdGraphErrorText {
    param($ErrorRecord)
    # The Graph SDK puts the service error body in ErrorDetails; the exception message is only the status line.
    return "$($ErrorRecord.ErrorDetails.Message) $($ErrorRecord.Exception.Message)".Trim()
}

function ConvertTo-AvdCloudSid {
    # Microsoft Entra object ID -> the S-1-12-1 SID that Entra Kerberos puts in tickets for cloud groups.
    param([Parameter(Mandatory)][string]$ObjectId)
    $bytes = [guid]::Parse($ObjectId).ToByteArray()
    $parts = 0..3 | ForEach-Object { [BitConverter]::ToUInt32($bytes, $_ * 4) }
    return "S-1-12-1-$($parts -join '-')"
}

function Get-AvdProfileShareSddl {
    # FSLogix recommended user-based access: users may create their own folder (this folder only), CREATOR OWNER
    # gets Modify on what they create, admins get Full Control. No inherited or default Authenticated Users access.
    param([Parameter(Mandatory)][string]$UsersSid, [Parameter(Mandatory)][string]$AdminsSid, [Parameter(Mandatory)][ValidateSet('profiles', 'redirections')][string]$Share)
    $modify = '0x1301bf'
    $readExecute = '0x1200a9'
    $common = "(A;OICI;FA;;;$AdminsSid)(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)"
    if ($Share -eq 'profiles') { return "O:BAG:SYD:P(A;OICIIO;$modify;;;CO)(A;;$modify;;;$UsersSid)$common" }
    return "O:BAG:SYD:P(A;OICI;$readExecute;;;$UsersSid)$common"
}

function Enable-AvdRdpEntraAuthentication {
    $result = [pscustomobject]@{ Done = ''; Manual = '' }
    try {
        $servicePrincipal = Invoke-MgGraphRequest -Method GET -Uri "$script:Graph/servicePrincipals(appId='$script:WindowsCloudLoginAppId')?`$select=id" -ErrorAction Stop
        $configurationUri = "$script:Graph/servicePrincipals/$($servicePrincipal.id)/remoteDesktopSecurityConfiguration"
        $current = $null
        try { $current = Invoke-MgGraphRequest -Method GET -Uri $configurationUri -ErrorAction Stop } catch { $current = $null }
        if ($current -and $current['isRemoteDesktopProtocolEnabled']) {
            $result.Done = 'Microsoft Entra authentication for RDP (Windows Cloud Login) was already enabled.'
        } else {
            Invoke-MgGraphRequest -Method PATCH -Uri $configurationUri -Body (@{ isRemoteDesktopProtocolEnabled = $true } | ConvertTo-Json) -ContentType 'application/json' -ErrorAction Stop | Out-Null
            $result.Done = 'Enabled Microsoft Entra authentication for RDP (Windows Cloud Login) for the tenant.'
        }
    } catch {
        $result.Manual = "Enable Microsoft Entra authentication for RDP: Entra ID > Devices > Remote connection configuration > Windows Cloud Login > enable ($(Get-AvdGraphErrorText $_))."
    }
    return $result
}

function Set-AvdStorageApplication {
    # Admin consent, the cloud-group SID tag (cloud-only) and private-link identifier URIs on the storage account's
    # auto-created Entra app. Nothing else on that app is touched (Microsoft warns other edits can break it).
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Configuration)
    $done = [System.Collections.Generic.List[string]]::new()
    $manual = [System.Collections.Generic.List[string]]::new()
    $account = $Configuration.storage.accountName
    $displayName = "[Storage Account] $account.file.core.windows.net"
    $filter = [uri]::EscapeDataString("displayName eq '$displayName'")
    try {
        $application = @((Invoke-MgGraphRequest -Method GET -Uri "$script:Graph/applications?`$filter=$filter&`$select=id,appId,tags,identifierUris" -ErrorAction Stop).value) | Select-Object -First 1
    } catch {
        $manual.Add("Configure the '$displayName' app manually (lookup failed: $(Get-AvdGraphErrorText $_)).")
        return [pscustomobject]@{ AppId = ''; Done = $done; Manual = $manual }
    }
    if (-not $application) {
        $manual.Add("The '$displayName' app was not found. Check that Microsoft Entra Kerberos is enabled on storage account $account, then run -Mode PostDeploy again.")
        return [pscustomobject]@{ AppId = ''; Done = $done; Manual = $manual }
    }

    try {
        $client = @((Invoke-MgGraphRequest -Method GET -Uri "$script:Graph/servicePrincipals?`$filter=appId eq '$($application.appId)'&`$select=id" -ErrorAction Stop).value) | Select-Object -First 1
        $resource = Invoke-MgGraphRequest -Method GET -Uri "$script:Graph/servicePrincipals(appId='$script:MicrosoftGraphAppId')?`$select=id" -ErrorAction Stop
        $grant = @((Invoke-MgGraphRequest -Method GET -Uri "$script:Graph/oauth2PermissionGrants?`$filter=clientId eq '$($client.id)'" -ErrorAction Stop).value) |
            Where-Object { $_.resourceId -eq $resource.id -and $_.consentType -eq 'AllPrincipals' } | Select-Object -First 1
        if (-not $grant) {
            $body = @{ clientId = $client.id; consentType = 'AllPrincipals'; resourceId = $resource.id; scope = ($script:StorageAppScopes -join ' ') }
            Invoke-MgGraphRequest -Method POST -Uri "$script:Graph/oauth2PermissionGrants" -Body ($body | ConvertTo-Json) -ContentType 'application/json' -ErrorAction Stop | Out-Null
            $done.Add("Granted tenant-wide admin consent ($($script:StorageAppScopes -join ', ')) to the storage account app.")
        } else {
            $granted = @(([string]$grant.scope).Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries))
            $missingScopes = @($script:StorageAppScopes | Where-Object { $_ -notin $granted })
            if ($missingScopes.Count -gt 0) {
                Invoke-MgGraphRequest -Method PATCH -Uri "$script:Graph/oauth2PermissionGrants/$($grant.id)" -Body (@{ scope = (@($granted) + $missingScopes) -join ' ' } | ConvertTo-Json) -ContentType 'application/json' -ErrorAction Stop | Out-Null
                $done.Add("Added admin consent for $($missingScopes -join ', ') to the storage account app.")
            } else {
                $done.Add('Admin consent for the storage account app was already granted.')
            }
        }
    } catch {
        $manual.Add("Grant admin consent: Entra ID > App registrations > All applications > '$displayName' > API permissions > Grant admin consent ($(Get-AvdGraphErrorText $_)).")
    }

    $tags = @($application.tags)
    $uris = @($application.identifierUris)
    $newTags = $tags
    if ($Configuration.profile -eq 'AzureFilesEntraKerberosCloudOnly' -and $tags -notcontains $script:CloudGroupSidTag) { $newTags = @($tags + $script:CloudGroupSidTag) }
    # Storage is reached through its private endpoint, so Kerberos also needs the privatelink names or Windows falls back to NTLM.
    $privateLinkUris = @($uris | Where-Object { $_ -like "*$account.file.core.windows.net" } | ForEach-Object { $_ -ireplace [regex]::Escape("$account.file.core.windows.net"), "$account.privatelink.file.core.windows.net" })
    $newUris = @(@($uris) + $privateLinkUris | Select-Object -Unique)
    $tagChanged = $newTags.Count -ne $tags.Count
    $urisChanged = $newUris.Count -ne $uris.Count
    if ($tagChanged -or $urisChanged) {
        $patch = @{}
        if ($tagChanged) { $patch.tags = $newTags }
        if ($urisChanged) { $patch.identifierUris = $newUris }
        try {
            Invoke-MgGraphRequest -Method PATCH -Uri "$script:Graph/applications/$($application.id)" -Body ($patch | ConvertTo-Json -Depth 4) -ContentType 'application/json' -ErrorAction Stop | Out-Null
            if ($tagChanged) { $done.Add("Added the $script:CloudGroupSidTag tag to the storage account app (required for cloud-only identities).") }
            if ($urisChanged) { $done.Add("Added $($newUris.Count - $uris.Count) private-link identifier URI(s) to the storage account app.") }
        } catch {
            $manual.Add("Update the '$displayName' app manifest: add tag '$script:CloudGroupSidTag' (cloud-only) and the $account.privatelink.file.core.windows.net identifier URIs ($(Get-AvdGraphErrorText $_)).")
        }
    } else {
        $done.Add('Storage account app tag and private-link identifier URIs were already in place.')
    }
    return [pscustomobject]@{ AppId = [string]$application.appId; Done = $done; Manual = $manual }
}

function Get-AvdConditionalAccessReview {
    # MFA or authentication-strength policies that apply to all resources must exclude the storage app (Entra
    # Kerberos to Azure Files cannot do MFA). Other device or privileged-access policies are listed for review.
    param([Parameter(Mandatory)][string]$StorageAppId)
    $policies = [System.Collections.Generic.List[object]]::new()
    $uri = "$script:Graph/identity/conditionalAccess/policies"
    while ($uri) {
        $page = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop
        foreach ($policy in @($page.value)) { $policies.Add($policy) }
        $uri = if ($page.ContainsKey('@odata.nextLink')) { $page['@odata.nextLink'] } else { $null }
    }
    $exclude = [System.Collections.Generic.List[object]]::new()
    $managed = [System.Collections.Generic.List[object]]::new()
    $review = [System.Collections.Generic.List[object]]::new()
    foreach ($policy in $policies) {
        $applications = $policy.conditions.applications
        if ($policy.state -eq 'disabled' -or @($applications.includeApplications) -notcontains 'All' -or @($applications.excludeApplications) -contains $StorageAppId) { continue }
        $grant = $policy['grantControls']
        $controls = @(if ($grant) { $grant['builtInControls'] })
        $strength = $grant -and $grant['authenticationStrength']
        if ($controls -contains 'mfa' -or $strength) {
            if ($policy.displayName -like 'Microsoft-managed:*') { $managed.Add($policy) } else { $exclude.Add($policy) }
            continue
        }
        $devices = $policy.conditions['devices']
        $users = $policy.conditions['users']
        $deviceBound = @($controls | Where-Object { $_ -in 'block', 'compliantDevice', 'domainJoinedDevice', 'approvedApplication', 'compliantApplication' }).Count -gt 0
        $filtered = $devices -and $devices['deviceFilter']
        $privileged = $users -and @($users['includeRoles']).Count -gt 0
        if ($deviceBound -or $filtered -or $privileged) { $review.Add($policy) }
    }
    return [pscustomobject]@{ Exclude = $exclude; Managed = $managed; Review = $review }
}

function Add-AvdConditionalAccessExclusion {
    param([Parameter(Mandatory)]$Policy, [Parameter(Mandatory)][string]$StorageAppId)
    $applications = $Policy.conditions.applications
    $body = @{
        includeApplications                         = @($applications.includeApplications)
        excludeApplications                         = @(@($applications.excludeApplications) + $StorageAppId | Select-Object -Unique)
        includeUserActions                          = @($applications['includeUserActions'])
        includeAuthenticationContextClassReferences = @($applications['includeAuthenticationContextClassReferences'])
    }
    if ($applications['applicationFilter']) { $body.applicationFilter = $applications['applicationFilter'] }
    Invoke-MgGraphRequest -Method PATCH -Uri "$script:Graph/identity/conditionalAccess/policies/$($Policy.id)" -Body (@{ conditions = @{ applications = $body } } | ConvertTo-Json -Depth 10) -ContentType 'application/json' -ErrorAction Stop | Out-Null
}

function Invoke-AvdConditionalAccessStep {
    param([Parameter(Mandatory)][string]$StorageAppId, [Parameter(Mandatory)][string]$AppName, [ValidateSet('Ask', 'Exclude', 'Report')][string]$Mode = 'Ask')
    $done = [System.Collections.Generic.List[string]]::new()
    $manual = [System.Collections.Generic.List[string]]::new()
    try { $review = Get-AvdConditionalAccessReview -StorageAppId $StorageAppId }
    catch {
        $manual.Add("Exclude '$AppName' from every Conditional Access policy that requires MFA for all resources (policies could not be read: $(Get-AvdGraphErrorText $_)).")
        return [pscustomobject]@{ Done = $done; Manual = $manual }
    }

    if ($review.Exclude.Count -gt 0) {
        Write-Host ''
        Write-Host "These Conditional Access policies require MFA for all resources and must exclude '$AppName' (Entra Kerberos to Azure Files cannot do MFA):"
        foreach ($policy in $review.Exclude) { Write-Host "  - $($policy.displayName) [$($policy.state)]" }
        $apply = switch ($Mode) {
            'Exclude' { $true }
            'Report' { $false }
            default { (Read-Host "Add '$AppName' to the excluded apps of these $($review.Exclude.Count) policies? Only the storage app is excluded; nothing else changes. Type 'yes' to apply") -eq 'yes' }
        }
        foreach ($policy in $review.Exclude) {
            if (-not $apply) {
                $manual.Add("Exclude '$AppName' from Conditional Access policy '$($policy.displayName)'.")
                continue
            }
            try {
                Add-AvdConditionalAccessExclusion -Policy $policy -StorageAppId $StorageAppId
                $done.Add("Excluded the storage app from Conditional Access policy '$($policy.displayName)'.")
            } catch {
                $manual.Add("Exclude '$AppName' from Conditional Access policy '$($policy.displayName)' in the portal (the change was refused: $(Get-AvdGraphErrorText $_)).")
            }
        }
    } else {
        $done.Add('No MFA Conditional Access policy needs a storage app exclusion.')
    }
    foreach ($policy in $review.Managed) {
        $manual.Add("Review '$($policy.displayName)': Microsoft-managed policies cannot exclude apps. It only applies to risky sign-ins; when it does, the FSLogix profile cannot mount for that session.")
    }
    foreach ($policy in $review.Review) {
        $manual.Add("Review Conditional Access policy '$($policy.displayName)': it applies to all resources with device, block or privileged-role conditions that a session host's storage sign-in may not meet. Test with an ordinary user and check the storage app's sign-in log.")
    }
    return [pscustomobject]@{ Done = $done; Manual = $manual }
}

function Get-AvdOperatorPublicIp {
    param([string]$OperatorPublicIp)
    if ($OperatorPublicIp) { return $OperatorPublicIp }
    $detected = ([string](Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 15 -ErrorAction Stop)).Trim()
    if ($detected -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { throw "Could not detect this machine's public IPv4 address (got '$detected'). Pass -OperatorPublicIp." }
    return $detected
}

function ConvertFrom-AvdAccessToken {
    param($Token)
    if ($Token -is [securestring]) { return [System.Net.NetworkCredential]::new('', $Token).Password }
    return [string]$Token
}

function Set-AvdShareRootPermission {
    param([Parameter(Mandatory)][string]$Account, [Parameter(Mandatory)][string]$Share, [Parameter(Mandatory)][string]$Sddl, [Parameter(Mandatory)][string]$Token)
    $headers = @{
        Authorization              = "Bearer $Token"
        'x-ms-version'             = $script:FilesApiVersion
        'x-ms-date'                = [DateTime]::UtcNow.ToString('R')
        'x-ms-file-request-intent' = 'backup'
        'x-ms-file-permission'     = $Sddl
    }
    Invoke-WebRequest -Method PUT -Uri "https://$Account.file.core.windows.net/$Share`?restype=directory&comp=properties" -Headers $headers -SkipHeaderValidation -UseBasicParsing -ErrorAction Stop | Out-Null
}

function Set-AvdProfileSharePermissions {
    # Storage public access is off, so open it to this machine's public IP only, set the share-root ACLs over the
    # Files REST API with a temporary data role, then always restore the network settings and remove the role.
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Configuration,
        [string]$OperatorPublicIp
    )
    $done = [System.Collections.Generic.List[string]]::new()
    $manual = [System.Collections.Generic.List[string]]::new()
    $account = $Configuration.storage.accountName
    $usersId = $Configuration.accessGroups.usersObjectId
    $adminsId = $Configuration.accessGroups.adminsObjectId

    if ($Configuration.profile -eq 'AzureFilesHybridKerberos') {
        # Hybrid users' tickets carry on-premises group SIDs, so the groups must be synced from AD.
        $sids = @{}
        foreach ($entry in @(@{ Key = 'users'; Id = $usersId }, @{ Key = 'admins'; Id = $adminsId })) {
            try { $sids[$entry.Key] = [string](Invoke-MgGraphRequest -Method GET -Uri "$script:Graph/groups/$($entry.Id)?`$select=onPremisesSecurityIdentifier" -ErrorAction Stop)['onPremisesSecurityIdentifier'] } catch { $sids[$entry.Key] = '' }
        }
        if (-not $sids.users -or -not $sids.admins) {
            $manual.Add('Set FSLogix folder permissions from a machine that can reach a domain controller: the AVD users or admins group is not synced from Active Directory, so it has no on-premises SID to use.')
            return [pscustomobject]@{ Done = $done; Manual = $manual }
        }
        $usersSid = $sids.users; $adminsSid = $sids.admins
    } else {
        $usersSid = ConvertTo-AvdCloudSid -ObjectId $usersId
        $adminsSid = ConvertTo-AvdCloudSid -ObjectId $adminsId
    }

    $storageId = "/subscriptions/$($Configuration.subscriptionId)/resourceGroups/$($Configuration.target.resourceGroupName)/providers/Microsoft.Storage/storageAccounts/$account"
    $apiVersion = 'api-version=2023-05-01'
    try { $ip = Get-AvdOperatorPublicIp -OperatorPublicIp $OperatorPublicIp }
    catch {
        $manual.Add("Set FSLogix folder permissions: $($_.Exception.Message)")
        return [pscustomobject]@{ Done = $done; Manual = $manual }
    }
    $current = Invoke-AzRestMethod -Method GET -Path "$storageId`?$apiVersion"
    if ($current.StatusCode -ne 200) {
        $manual.Add("Set FSLogix folder permissions: storage account $account could not be read (HTTP $($current.StatusCode)).")
        return [pscustomobject]@{ Done = $done; Manual = $manual }
    }
    $original = ($current.Content | ConvertFrom-Json -AsHashtable).properties
    $originalAcls = $original['networkAcls']
    $restoreBody = @{ properties = @{ publicNetworkAccess = $(if ($original['publicNetworkAccess']) { $original['publicNetworkAccess'] } else { 'Disabled' }); networkAcls = $originalAcls } } | ConvertTo-Json -Depth 10

    $operator = Get-AvdOperator -Context (Get-AzContext)
    $roleCreated = $false
    $opened = $false
    try {
        if (-not @(Get-AzRoleAssignment -ObjectId $operator.ObjectId -Scope $storageId -ErrorAction SilentlyContinue | Where-Object { $_.RoleDefinitionId -match $script:FilePrivilegedContributorRoleId -and $_.Scope -eq $storageId }).Count) {
            New-AzRoleAssignment -ObjectId $operator.ObjectId -RoleDefinitionId $script:FilePrivilegedContributorRoleId -Scope $storageId -ErrorAction Stop | Out-Null
            $roleCreated = $true
        }
        $openAcls = @{
            defaultAction       = 'Deny'
            bypass              = $(if ($originalAcls -and $originalAcls['bypass']) { $originalAcls['bypass'] } else { 'AzureServices' })
            ipRules             = @(@(if ($originalAcls) { $originalAcls['ipRules'] }) + @{ value = $ip; action = 'Allow' })
            virtualNetworkRules = @(if ($originalAcls) { $originalAcls['virtualNetworkRules'] })
        }
        Write-Host "Temporarily allowing $ip through the storage firewall of $account to set FSLogix folder permissions..."
        $open = Invoke-AzRestMethod -Method PATCH -Path "$storageId`?$apiVersion" -Payload (@{ properties = @{ publicNetworkAccess = 'Enabled'; networkAcls = $openAcls } } | ConvertTo-Json -Depth 10)
        if ($open.StatusCode -notin 200, 202) { throw "the storage firewall could not be opened (HTTP $($open.StatusCode))" }
        $opened = $true

        $token = ConvertFrom-AvdAccessToken (Get-AzAccessToken -ResourceUrl 'https://storage.azure.com/' -ErrorAction Stop).Token
        $retryDelay = if ($env:AVDV2_RETRY_DELAY_SECONDS) { [int]$env:AVDV2_RETRY_DELAY_SECONDS } else { 20 }
        foreach ($share in 'profiles', 'redirections') {
            $sddl = Get-AvdProfileShareSddl -UsersSid $usersSid -AdminsSid $adminsSid -Share $share
            # Firewall rules and new role assignments take a few minutes to apply; 403 until then.
            for ($attempt = 1; ; $attempt++) {
                try {
                    Set-AvdShareRootPermission -Account $account -Share $share -Sddl $sddl -Token $token
                    break
                } catch {
                    $status = if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
                    if ($status -ne 403 -or $attempt -ge 30) { throw }
                    if ($attempt -eq 1) { Write-Host 'Waiting for the firewall rule and temporary role to apply...' }
                    Start-Sleep -Seconds $retryDelay
                }
            }
        }
        $done.Add('Set FSLogix-recommended permissions on the profiles share (users create their own folder; only the owner and admins can open it) and read-only access to redirections. Existing profile folders keep their current permissions.')
    } catch {
        $manual.Add("Set FSLogix folder permissions on $account (automatic setup failed: $($_.Exception.Message)). The share's default permissions still let FSLogix work, but users can open each other's profile folders.")
    } finally {
        if ($opened) {
            $restore = Invoke-AzRestMethod -Method PATCH -Path "$storageId`?$apiVersion" -Payload $restoreBody
            if ($restore.StatusCode -in 200, 202) { Write-Host "Storage firewall of $account restored (public network access $($original['publicNetworkAccess']))." }
            else { $manual.Add("IMPORTANT: restore the storage firewall of $account - set public network access to Disabled and remove the IP rule for $ip (automatic restore returned HTTP $($restore.StatusCode)).") }
        }
        if ($roleCreated) {
            try { Remove-AzRoleAssignment -ObjectId $operator.ObjectId -RoleDefinitionId $script:FilePrivilegedContributorRoleId -Scope $storageId -ErrorAction Stop | Out-Null }
            catch { $manual.Add("Remove your temporary 'Storage File Data Privileged Contributor' role assignment on $account.") }
        }
    }
    return [pscustomobject]@{ Done = $done; Manual = $manual }
}

function Get-AvdHostDeviceReport {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Configuration)
    $done = [System.Collections.Generic.List[string]]::new()
    $manual = [System.Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt [int]$Configuration.sessionHosts.count; $index++) {
        $name = "$($Configuration.sessionHosts.namePrefix)-$index"
        try {
            $devices = @((Invoke-MgGraphRequest -Method GET -Uri "$script:Graph/devices?`$filter=displayName eq '$name'&`$select=displayName,trustType,isManaged,operatingSystemVersion,approximateLastSignInDateTime" -ErrorAction Stop).value)
        } catch {
            $manual.Add("Check that $name is Microsoft Entra joined (device lookup failed: $(Get-AvdGraphErrorText $_)).")
            continue
        }
        if ($devices.Count -eq 0) { $manual.Add("$name was not found in Microsoft Entra ID. Check its AADLoginForWindows extension."); continue }
        $device = $devices | Sort-Object { [string]$_['approximateLastSignInDateTime'] } -Descending | Select-Object -First 1
        if ($devices.Count -gt 1) { $manual.Add("$name has $($devices.Count) Entra device records; delete the stale ones (left by earlier deployments with the same host names).") }
        $joined = $device['trustType'] -eq 'AzureAd'
        $managed = [bool]$device['isManaged']
        $done.Add("$name`: $(if ($joined) { 'Microsoft Entra joined' } else { "trust type $($device['trustType'])" }), $(if ($managed) { 'Intune managed' } else { 'not Intune managed' }), Windows $($device['operatingSystemVersion']).")
        if (-not $joined) { $manual.Add("$name is not Microsoft Entra joined; users cannot sign in with Entra ID or reach FSLogix storage with Entra Kerberos.") }
        if ($Configuration.profile -eq 'AzureFilesEntraKerberosCloudOnly') {
            $version = [string]$device['operatingSystemVersion']
            $parts = $version.Split('.')
            if ($parts.Count -ge 4) {
                $build = [int]$parts[2]; $revision = [int]$parts[3]
                if ($script:MinimumCloudOnlyRevision.ContainsKey($build) -and $revision -lt $script:MinimumCloudOnlyRevision[$build]) {
                    $manual.Add("$name runs Windows $version; cloud-only FSLogix needs $build.$($script:MinimumCloudOnlyRevision[$build]) or later (KB5079391). Install updates and restart it.")
                }
            }
        }
    }
    return [pscustomobject]@{ Done = $done; Manual = $manual }
}

function Invoke-AvdPostDeploy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Configuration,
        [ValidateSet('Ask', 'Exclude', 'Report')][string]$ConditionalAccess = 'Ask',
        [string]$OperatorPublicIp
    )
    $done = [System.Collections.Generic.List[string]]::new()
    $manual = [System.Collections.Generic.List[string]]::new()
    $usesStorage = $Configuration.Contains('storage') -and $Configuration.profile -ne 'LocalProfile'

    Write-Host ''
    Write-Host 'Post-deployment configuration (Microsoft Entra and FSLogix storage)...'
    $scopes = Get-AvdPostDeployScopes -Configuration $Configuration
    if (-not (Connect-AvdGraph -TenantId $Configuration.tenantId -Scopes $scopes)) {
        $manual.Add("Microsoft Graph sign-in for tenant $($Configuration.tenantId) was not available (install Microsoft.Graph.Authentication; needs an admin who can consent to $($scopes -join ', ')). Do the Entra steps in docs/sandbox-test.md manually.")
        return [pscustomobject]@{ Done = $done; Manual = $manual }
    }

    $rdp = Enable-AvdRdpEntraAuthentication
    if ($rdp.Done) { $done.Add($rdp.Done) }
    if ($rdp.Manual) { $manual.Add($rdp.Manual) }

    if ($usesStorage) {
        $application = Set-AvdStorageApplication -Configuration $Configuration
        foreach ($item in $application.Done) { $done.Add($item) }
        foreach ($item in $application.Manual) { $manual.Add($item) }
        if ($application.AppId) {
            $access = Invoke-AvdConditionalAccessStep -StorageAppId $application.AppId -AppName "[Storage Account] $($Configuration.storage.accountName).file.core.windows.net" -Mode $ConditionalAccess
            foreach ($item in $access.Done) { $done.Add($item) }
            foreach ($item in $access.Manual) { $manual.Add($item) }
        }
        $permissions = Set-AvdProfileSharePermissions -Configuration $Configuration -OperatorPublicIp $OperatorPublicIp
        foreach ($item in $permissions.Done) { $done.Add($item) }
        foreach ($item in $permissions.Manual) { $manual.Add($item) }
    }

    $devices = Get-AvdHostDeviceReport -Configuration $Configuration
    foreach ($item in $devices.Done) { $done.Add($item) }
    foreach ($item in $devices.Manual) { $manual.Add($item) }
    return [pscustomobject]@{ Done = $done; Manual = $manual }
}

Export-ModuleMember -Function Invoke-AvdPostDeploy, ConvertTo-AvdCloudSid, Get-AvdProfileShareSddl
