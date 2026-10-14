#requires -Version 7.2
Set-StrictMode -Version Latest

# Helpers for avd.ps1 -Mode New Azure discovery. Read-only: nothing here creates or changes resources.

$script:AvdApplicationId = '9cdead84-a844-4324-93f2-b2e6bb768d07'

function Get-AvdNameSuffix {
    param([Parameter(Mandatory)][string]$Seed)
    $bytes = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($Seed.ToLowerInvariant()))
    return [System.Convert]::ToHexString($bytes).Substring(0, 6).ToLowerInvariant()
}

function New-AvdResourceNames {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [int]$Attempt = 0
    )

    $clean = ($Prefix -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
    $suffix = Get-AvdNameSuffix -Seed "$SubscriptionId/$ResourceGroupName/$Attempt"
    return [ordered]@{
        keyVault            = "kv-$clean-$suffix"
        storageAccount      = "st$clean$suffix"
        secretName          = 'sessionhost-admin'
        deploymentIdentity  = "id-$clean-avd-deployer"
        virtualNetwork      = "vnet-$clean-avd"
        sessionHostSubnet   = 'snet-sessionhosts'
        privateEndpointSubnet = 'snet-privateendpoints'
    }
}

function ConvertTo-AvdCidrRange {
    param([Parameter(Mandatory)][string]$Cidr)
    $parts = $Cidr.Split('/')
    $bytes = [System.Net.IPAddress]::Parse($parts[0]).GetAddressBytes()
    [Array]::Reverse($bytes)
    $start = [BitConverter]::ToUInt32($bytes, 0)
    $size = [uint64][Math]::Pow(2, 32 - [int]$parts[1])
    $start = [uint32]($start - ($start % $size))
    return [pscustomobject]@{ Start = [uint64]$start; End = [uint64]$start + $size - 1 }
}

function Test-AvdCidrAligned {
    # Azure rejects prefixes with host bits set (for example 10.200.1.0/16).
    param([Parameter(Mandatory)][string]$Cidr)
    $parts = $Cidr.Split('/')
    $address = $null
    if ($parts.Count -ne 2 -or -not [System.Net.IPAddress]::TryParse($parts[0], [ref]$address)) { return $false }
    $bytes = $address.GetAddressBytes()
    [Array]::Reverse($bytes)
    $start = [uint64][BitConverter]::ToUInt32($bytes, 0)
    $size = [uint64][Math]::Pow(2, 32 - [int]$parts[1])
    return ($start % $size) -eq 0
}

function Test-AvdCidrOverlap {
    param([Parameter(Mandatory)][string]$First, [Parameter(Mandatory)][string]$Second)
    $a = ConvertTo-AvdCidrRange -Cidr $First
    $b = ConvertTo-AvdCidrRange -Cidr $Second
    return ($a.Start -le $b.End -and $b.Start -le $a.End)
}

function Get-AvdFreeAddressSpace {
    [CmdletBinding()]
    param([string[]]$ExistingPrefixes = @())

    $ipv4 = @($ExistingPrefixes | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+/\d+$' })
    for ($second = 200; $second -le 250; $second++) {
        $candidate = "10.$second.0.0/24"
        if (-not ($ipv4 | Where-Object { Test-AvdCidrOverlap -First $candidate -Second $_ })) {
            return $candidate
        }
    }
    throw 'No free 10.200-250.0.0/24 range was found; supply -AddressSpace with an approved private range.'
}

function Get-AvdHostPoolRegions {
    [CmdletBinding()]
    param()

    $provider = @(Get-AzResourceProvider -ProviderNamespace 'Microsoft.DesktopVirtualization' -ErrorAction Stop)
    $displayNames = @($provider | ForEach-Object { $_.ResourceTypes } | Where-Object { $_.ResourceTypeName -eq 'hostpools' } | ForEach-Object { $_.Locations } | Select-Object -Unique)
    $locations = @(Get-AzLocation)
    $regions = foreach ($display in $displayNames) {
        $match = $locations | Where-Object { $_.DisplayName -eq $display -or $_.Location -eq ($display -replace '\s', '').ToLowerInvariant() } | Select-Object -First 1
        if ($match) { [pscustomobject]@{ Name = $match.Location; DisplayName = $match.DisplayName } }
    }
    return @($regions | Sort-Object DisplayName)
}

function Get-AvdServicePrincipalObjectId {
    [CmdletBinding()]
    param()
    $principal = @(Get-AzADServicePrincipal -ApplicationId $script:AvdApplicationId -ErrorAction SilentlyContinue)
    if ($principal.Count -ne 1) {
        throw 'The Azure Virtual Desktop service principal was not found in this tenant. Register the provider (Register-AzResourceProvider -ProviderNamespace Microsoft.DesktopVirtualization), wait a few minutes and retry.'
    }
    return [string]$principal[0].Id
}

Export-ModuleMember -Function Get-AvdNameSuffix, New-AvdResourceNames, Test-AvdCidrAligned, Test-AvdCidrOverlap, Get-AvdFreeAddressSpace, Get-AvdHostPoolRegions, Get-AvdServicePrincipalObjectId
