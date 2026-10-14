#requires -Version 7.2
[CmdletBinding()]
param()

# Tests for avd.ps1 -Mode Web. The wizard runs in a child pwsh process with Azure/Entra mocks; this process talks to it over HTTP.

$ErrorActionPreference = 'Stop'
$v2Root = Split-Path $PSScriptRoot -Parent
$temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
[System.IO.Directory]::CreateDirectory($temporaryDirectory) | Out-Null
$outputFile = Join-Path $temporaryDirectory 'web-avd.json'
$passed = 0
$process = $null

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Write-Pass {
    param([string]$Message)
    $script:passed++
    Write-Host "PASS: $Message"
}

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$listener.Start()
$port = $listener.LocalEndpoint.Port
$listener.Stop()

$bootstrap = @'
param($CliPath, $Port, $OutputFile)
$ErrorActionPreference = 'Stop'
foreach ($name in 'Get-AzResourceGroupDeploymentWhatIfResult', 'New-AzResourceGroupDeployment', 'Test-AzResourceGroupDeployment', 'Get-AzRoleAssignment',
    'New-AzRoleAssignment', 'Remove-AzRoleAssignment', 'Get-AzAccessToken', 'Update-AzWvdDesktop', 'Get-AzDeploymentWhatIfResult',
    'New-AzDeployment', 'Register-AzResourceProvider', 'Get-AzWvdHostPool', 'Update-AzWvdHostPool', 'Get-AzWvdHostPoolRegistrationToken',
    'Get-AzWvdSessionHost', 'Update-AzWvdSessionHost', 'Get-AzKeyVaultSecret', 'Connect-AzAccount', 'bicep') {
    Set-Item -Path "Function:\global:$name" -Value { throw "Unexpected call in web tests" }
}
function global:Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = '11111111-1111-4111-8111-111111111111' }; Subscription = [pscustomobject]@{ Id = '22222222-2222-4222-8222-222222222222' }; Account = [pscustomobject]@{ Id = 'tester@example.com'; Type = 'User' } } }
function global:Set-AzContext { param($Tenant, $Subscription) }
function global:Get-AzSubscription { param($ErrorAction, $WarningAction) @([pscustomobject]@{ Id = '22222222-2222-4222-8222-222222222222'; Name = 'Sandbox'; TenantId = '11111111-1111-4111-8111-111111111111'; State = 'Enabled' }) }
function global:Get-AzResourceProvider { param($ProviderNamespace, $ErrorAction) [pscustomobject]@{ RegistrationState = 'Registered'; ResourceTypes = @([pscustomobject]@{ ResourceTypeName = 'hostpools'; Locations = @('UK South', 'West Europe') }) } }
function global:Get-AzLocation { @([pscustomobject]@{ Location = 'uksouth'; DisplayName = 'UK South' }, [pscustomobject]@{ Location = 'westeurope'; DisplayName = 'West Europe' }) }
function global:Get-AzResourceGroup { param($Name, $ErrorAction) }
function global:Get-AzKeyVault { param($VaultName, $ResourceGroupName, $Location, [switch]$InRemovedState, $ErrorAction) }
function global:Get-AzResource { param($ResourceId, $ResourceGroupName, $Name, $ResourceType, $ErrorAction) }
function global:Invoke-AzRestMethod {
    param($Method, $Path, $Payload)
    if ($Method -eq 'GET' -and $Path -match '/skus\?') {
        $skus = foreach ($size in 'Standard_D8s_v5', 'Standard_D8as_v5') {
            @{ resourceType = 'virtualMachines'; name = $size; family = $(if ($size -like '*as_v5') { 'standardDASv5Family' } else { 'standardDSv5Family' })
                restrictions = @(if ($size -eq 'Standard_D8s_v5') { @{ type = 'Location'; reasonCode = 'NotAvailableForSubscription' } })
                capabilities = @(@{ name = 'vCPUs'; value = '8' }, @{ name = 'HyperVGenerations'; value = 'V1,V2' }, @{ name = 'PremiumIO'; value = 'True' }) }
        }
        return [pscustomobject]@{ StatusCode = 200; Content = (@{ value = @($skus) } | ConvertTo-Json -Depth 6) }
    }
    if ($Method -eq 'GET' -and $Path -match '/usages\?') {
        return [pscustomobject]@{ StatusCode = 200; Content = (@{ value = @(@{ name = @{ value = 'standardDASv5Family' }; currentValue = 0; limit = 20 }, @{ name = @{ value = 'cores' }; currentValue = 0; limit = 20 }) } | ConvertTo-Json -Depth 6) }
    }
    [pscustomobject]@{ StatusCode = 200; Content = '{"nameAvailable":true}' }
}
function global:Invoke-WebRequest { param($Uri, $OutFile, [switch]$UseBasicParsing) throw 'offline' }
function global:Get-AzVirtualNetwork {
    param($ResourceGroupName, $Name, $ErrorAction)
    if (-not $Name) {
        @([pscustomobject]@{ Name = 'vnet-existing'; Id = '/mock/vnet-existing'; ResourceGroupName = 'network-rg'; Location = 'uksouth'
            AddressSpace = [pscustomobject]@{ AddressPrefixes = @('10.200.0.0/16') }; DhcpOptions = [pscustomobject]@{ DnsServers = @() }
            Subnets = @([pscustomobject]@{ Name = 'hosts' }, [pscustomobject]@{ Name = 'endpoints' }) })
    }
}
$global:CreatedGroups = @()
function global:Get-AzADGroup {
    param($ObjectId, $DisplayNameStartsWith, $DisplayName, $First, $ErrorAction)
    $groups = @([pscustomobject]@{ Id = '44444444-4444-4444-8444-444444444444'; DisplayName = 'AVD Users' }, [pscustomobject]@{ Id = '55555555-5555-4555-8555-555555555555'; DisplayName = 'AVD Admins' }) + $global:CreatedGroups
    if ($ObjectId) { return $groups | Where-Object { $_.Id -eq $ObjectId } }
    if ($DisplayName) { return $groups | Where-Object { $_.DisplayName -eq $DisplayName } }
    if ($DisplayNameStartsWith) { return $groups | Where-Object { $_.DisplayName -like "$DisplayNameStartsWith*" } }
    $groups
}
function global:New-AzADGroup {
    param($DisplayName, $MailNickname, [switch]$SecurityEnabled, $Description, $ErrorAction)
    $group = [pscustomobject]@{ Id = $(if ($DisplayName -like '*admins') { 'bbbbbbbb-1111-4111-8111-111111111111' } else { 'aaaaaaaa-1111-4111-8111-111111111111' }); DisplayName = $DisplayName }
    $global:CreatedGroups += $group
    $group
}
function global:New-AzADGroupOwner { param($GroupId, $OwnerId, $ErrorAction) }
function global:Add-AzADGroupMember { param($TargetGroupObjectId, $MemberObjectId, $ErrorAction, $WarningAction) }
function global:Get-AzADUser { param([switch]$SignedIn, $ErrorAction) [pscustomobject]@{ Id = '77777777-0000-4000-8000-000000000007' } }
function global:Get-AzADServicePrincipal { param($ApplicationId, $ErrorAction) [pscustomobject]@{ Id = '66666666-6666-4666-8666-666666666666' } }
& $CliPath -Mode Web -NoBrowser -Port $Port -OutputFile $OutputFile
'@
$bootstrapPath = Join-Path $temporaryDirectory 'web-bootstrap.ps1'
[System.IO.File]::WriteAllText($bootstrapPath, $bootstrap)

function Invoke-Wizard {
    param([string]$Path, [string]$Method = 'GET', $Body, [hashtable]$Headers = @{})
    $arguments = @{ Uri = "http://localhost:$port$Path"; Method = $Method; Headers = $Headers; SkipHttpErrorCheck = $true; UseBasicParsing = $true }
    if ($null -ne $Body) { $arguments.Body = ($Body | ConvertTo-Json -Depth 10); $arguments.ContentType = 'application/json' }
    $response = Invoke-WebRequest @arguments
    $json = $null
    if ($response.Headers['Content-Type'] -like 'application/json*') { $json = $response.Content | ConvertFrom-Json -AsHashtable }
    return [pscustomobject]@{ Status = [int]$response.StatusCode; Json = $json; Content = [string]$response.Content }
}

try {
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    foreach ($argument in '-NoProfile', '-File', $bootstrapPath, (Join-Path $v2Root 'avd.ps1'), $port, $outputFile) { $startInfo.ArgumentList.Add([string]$argument) }
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.UseShellExecute = $false
    if (-not (Get-Command bicep -ErrorAction SilentlyContinue)) { $startInfo.Environment['PATH'] = $env:PATH }
    $process = [System.Diagnostics.Process]::Start($startInfo)
    $url = $null
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    $lineTask = $null
    while (-not $url -and [DateTime]::UtcNow -lt $deadline -and -not $process.HasExited) {
        if (-not $lineTask) { $lineTask = $process.StandardOutput.ReadLineAsync() }
        if ($lineTask.Wait(1000)) {
            if ($lineTask.Result -match 'WEB-READY (\S+)') { $url = $Matches[1] }
            $lineTask = $null
        }
    }
    Assert-True ([bool]$url) "The web wizard did not start: $(if ($process.HasExited) { $process.StandardError.ReadToEnd() })"
    $token = ([uri]$url).Query.TrimStart('?').Split('=')[1]
    $auth = @{ 'X-AVD-Token' = $token }

    # Security
    Assert-True ((Invoke-Wizard -Path '/').Status -eq 403) 'The page must not be served without the session token.'
    $page = Invoke-Wizard -Path "/?token=$token"
    Assert-True ($page.Status -eq 200 -and $page.Content -match 'Azure Virtual Desktop deployment wizard') 'The page should be served with the session token.'
    Assert-True ((Invoke-Wizard -Path '/api/context').Status -eq 403) 'APIs must require the token header.'
    Assert-True ((Invoke-Wizard -Path '/api/context' -Headers @{ 'X-AVD-Token' = 'wrong' }).Status -eq 403) 'APIs must reject a wrong token.'
    Assert-True ((Invoke-Wizard -Path '/api/context' -Headers ($auth + @{ Origin = 'https://evil.example' })).Status -eq 403) 'APIs must reject cross-site origins.'
    Write-Pass 'the wizard requires its session token and rejects cross-site requests.'

    # Discovery APIs
    $context = Invoke-Wizard -Path '/api/context' -Headers $auth
    Assert-True ($context.Status -eq 200 -and $context.Json.account -eq 'tester@example.com' -and $context.Json.outputFile -eq $outputFile) 'Context should show the signed-in account and output file.'
    $subscriptions = Invoke-Wizard -Path '/api/subscriptions' -Headers $auth
    Assert-True ($subscriptions.Status -eq 200 -and @($subscriptions.Json)[0].name -eq 'Sandbox') 'Subscriptions should be listed.'
    $regions = Invoke-Wizard -Path '/api/regions' -Headers $auth
    Assert-True (@($regions.Json | ForEach-Object { $_.name }) -contains 'uksouth') 'AVD regions should be listed.'
    $networks = Invoke-Wizard -Path '/api/networks?region=uksouth' -Headers $auth
    Assert-True ($networks.Json.proposedAddressSpace -eq '10.201.0.0/24' -and @($networks.Json.networks)[0].name -eq 'vnet-existing') 'Networks and a free address space should be returned.'
    $groups = Invoke-Wizard -Path '/api/groups?search=AVD%20Ad' -Headers $auth
    Assert-True (@($groups.Json).Count -eq 1 -and @($groups.Json)[0].displayName -eq 'AVD Admins') 'Group search should filter by name.'
    $zones = Invoke-Wizard -Path '/api/timezones?region=uksouth' -Headers $auth
    Assert-True ($zones.Json.suggested -eq 'GMT Standard Time' -and @($zones.Json.zones).Count -gt 50) 'Time zones should be listed with a regional suggestion.'
    $sizing = Invoke-Wizard -Path '/api/sizing' -Method POST -Headers $auth -Body @{ hosting = 'Shared'; persona = 'Standard'; users = 100; peakConcurrencyPct = 80 }
    Assert-True ($sizing.Json.sessionHosts.count -eq 4 -and $sizing.Json.hostPool.maxSessionLimit -eq 32) 'Sizing should match the CLI recommendation.'
    $capacity = Invoke-Wizard -Path '/api/capacity' -Method POST -Headers $auth -Body @{ location = 'uksouth'; vmSize = 'Standard_D8s_v5'; count = 2 }
    Assert-True ($capacity.Status -eq 200 -and $capacity.Json.checked -and -not $capacity.Json.ok -and (@($capacity.Json.blockers) -join ' ') -match 'restricted for this subscription' -and @($capacity.Json.alternatives) -contains 'Standard_D8as_v5') "Capacity should flag a restricted size and offer alternatives, got $($capacity.Content)"
    $capacity = Invoke-Wizard -Path '/api/capacity' -Method POST -Headers $auth -Body @{ location = 'uksouth'; vmSize = 'Standard_D8as_v5'; count = 2 }
    Assert-True ($capacity.Json.ok) "An unrestricted size with quota should pass, got $($capacity.Content)"
    Write-Pass 'discovery APIs list subscriptions, regions, networks, groups, time zones, sizing and VM size availability.'

    # Generate
    $answers = @{
        SubscriptionId = '22222222-2222-4222-8222-222222222222'; Location = 'uksouth'; Prefix = 'WEB'; ResourceGroupName = 'rg-web-avd'
        NetworkMode = 'New'; AddressSpace = '10.201.0.0/24'; NewUsersGroup = 'sg-web-avd-users'; NewAdminsGroup = 'sg-web-avd-admins'; AddMeToUsersGroup = $true
        Hosting = 'Shared'; Persona = 'Standard'; Users = 10; PeakConcurrencyPct = 100; UserIdentity = 'CloudOnly'
        ScalingPreset = 'BusinessHours'; WorkdayStart = '08:00'
    }
    $missing = Invoke-Wizard -Path '/api/generate' -Method POST -Headers $auth -Body $answers
    Assert-True ($missing.Status -eq 400 -and $missing.Json.error -match 'Missing answer') "A missing answer must fail instead of prompting in the server window; got $($missing.Status) $($missing.Content)"
    $answers.WorkdayEnd = '18:00'
    $answers.TimeZone = 'GMT Standard Time'
    $answers.WorkspaceName = 'Contoso Workspace'
    $answers.DesktopName = 'Contoso Desktop'
    $answers.ProfileFailureAction = 'Block'
    $answers.Overwrite = $true
    $generated = Invoke-Wizard -Path '/api/generate' -Method POST -Headers $auth -Body $answers
    Assert-True ($generated.Status -eq 200) "Generate failed: $($generated.Json.error)"
    $config = Get-Content -LiteralPath $outputFile -Raw | ConvertFrom-Json -AsHashtable
    Assert-True ($config.schemaVersion -eq '1.5.0' -and $config.target.resourceGroupName -eq 'rg-web-avd' -and $config.accessGroups.usersObjectId -eq 'aaaaaaaa-1111-4111-8111-111111111111' -and $config.scaling.timeZone -eq 'GMT Standard Time') 'Generate should write a complete 1.5.0 configuration with the created groups.'
    Assert-True ($config.display.workspaceName -eq 'Contoso Workspace' -and $config.display.desktopName -eq 'Contoso Desktop' -and $config.fslogix.preventTempProfile -eq $true) 'Generate should carry the display names and the FSLogix failure choice.'
    Assert-True (@($generated.Json.next)[1] -match '-PostDeploy') 'The Deploy command should include -PostDeploy.'
    Assert-True (@($generated.Json.next)[0] -match '-Mode Preview' -and (@($generated.Json.summary) -join ' ') -match 'Configuration valid') 'Generate should return the summary and next commands.'
    Write-Pass 'generate writes the same validated configuration as -Mode New and never prompts.'

    $preview = Invoke-Wizard -Path '/api/preview' -Method POST -Headers $auth -Body @{}
    Assert-True ($preview.Status -eq 200 -and -not $preview.Json.ready -and (@($preview.Json.blockers) -join ' ') -match 'Standard_D8s_v5 is restricted' -and (Test-Path -LiteralPath $preview.Json.planFile)) "Preview should run from the page, write the plan and return blockers, got $($preview.Status) $($preview.Content)"
    Assert-True ((@($preview.Json.log) -join ' ') -match 'Preview as tester@example.com' -and -not $preview.Json.next) 'Preview should return its progress log and no Deploy command when blocked.'
    $answers.VmSize = 'Standard_D8as_v5'
    $generated = Invoke-Wizard -Path '/api/generate' -Method POST -Headers $auth -Body $answers
    $config = Get-Content -LiteralPath $outputFile -Raw | ConvertFrom-Json -AsHashtable
    Assert-True ($generated.Status -eq 200 -and $config.sessionHosts.vmSize -eq 'Standard_D8as_v5') "The chosen VM size should replace the recommendation, got $($generated.Json.error)"
    $preview = Invoke-Wizard -Path '/api/preview' -Method POST -Headers $auth -Body @{}
    Assert-True ((@($preview.Json.blockers) -join ' ') -notmatch 'restricted') "Preview should accept the replacement size, got $($preview.Content)"
    $answers.VmSize = 'Standard_D8; rm -rf'
    $bad = Invoke-Wizard -Path '/api/generate' -Method POST -Headers $auth -Body $answers
    Assert-True ($bad.Status -eq 400) 'An invalid VM size must be rejected.'
    Write-Pass 'Preview runs from the page and a replacement VM size flows into the configuration.'

    $shutdown = Invoke-Wizard -Path '/api/shutdown' -Method POST -Headers $auth -Body @{}
    Assert-True ($shutdown.Status -eq 200 -and $process.WaitForExit(15000)) 'Shutdown should stop the wizard.'
    Write-Pass 'the wizard closes from the page.'

    Write-Host "$passed web wizard tests passed."
} finally {
    if ($process -and -not $process.HasExited) { $process.Kill($true) }
    Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
