# V2 session host preparation, run by the CustomScriptExtension in infra/avd/session-hosts.bicep.
# Behaviour matches the root 02a-SessionHostPrep.ps1, with -ProfileMode selecting FSLogix (shared pools on
# Azure Files with Microsoft Entra Kerberos) or Local (dedicated hosts that keep the profile on the VM).
# Publish it as an immutable HTTPS artifact and record its SHA-256 in artifacts.sessionHostPrepSha256.
# Runs under Windows PowerShell 5.1 on the session host.
[CmdletBinding()]
param(
    [ValidateSet('FSLogix', 'Local')]
    [string]$ProfileMode = 'FSLogix',
    [string]$ProfilesPath,
    [string]$RedirectionPath,
    # Block sign-in instead of issuing a temporary profile when the container cannot attach.
    [switch]$PreventTempProfile
)

$ErrorActionPreference = 'Stop'

if ($ProfileMode -eq 'FSLogix') {
    if ([string]::IsNullOrWhiteSpace($ProfilesPath) -or [string]::IsNullOrWhiteSpace($RedirectionPath)) {
        throw 'FSLogix profile mode requires -ProfilesPath and -RedirectionPath.'
    }

    # Retrieve the Microsoft Entra Kerberos ticket at sign-in so Azure Files accepts the user's identity
    # (hybrid and cloud-only identities). Takes effect after a restart, which Deploy performs once hosts register.
    $kerberosPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters'
    if (-not (Test-Path $kerberosPath)) {
        New-Item -Path $kerberosPath -Force | Out-Null
    }
    New-ItemProperty -Path $kerberosPath -Name 'CloudKerberosTicketRetrievalEnabled' -Value 1 -PropertyType DWord -Force | Out-Null

    # Entra ID with roaming profiles: load Credential Manager keys from the profile so tokens work on any host.
    $credentialKeyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\AzureADAccount'
    if (-not (Test-Path $credentialKeyPath)) {
        New-Item -Path $credentialKeyPath -Force | Out-Null
    }
    New-ItemProperty -Path $credentialKeyPath -Name 'LoadCredKeyFromProfile' -Value 1 -PropertyType DWord -Force | Out-Null

    $profilesKey = 'HKLM:\SOFTWARE\FSLogix\Profiles'
    if (-not (Test-Path $profilesKey)) {
        New-Item -Path $profilesKey -Force | Out-Null
    }
    New-ItemProperty -Path $profilesKey -Name 'Enabled' -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $profilesKey -Name 'VHDLocations' -Value $ProfilesPath -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $profilesKey -Name 'VolumeType' -Value 'VHDX' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $profilesKey -Name 'FlipFlopProfileDirectoryName' -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $profilesKey -Name 'DeleteLocalProfileWhenVHDShouldApply' -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $profilesKey -Name 'RedirXMLSourceFolder' -Value $RedirectionPath -PropertyType String -Force | Out-Null
    $prevent = if ($PreventTempProfile) { 1 } else { 0 }
    New-ItemProperty -Path $profilesKey -Name 'PreventLoginWithFailure' -Value $prevent -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $profilesKey -Name 'PreventLoginWithTempProfile' -Value $prevent -PropertyType DWord -Force | Out-Null
} else {
    # Dedicated hosts keep the user profile on the VM, like Windows 365. Make sure FSLogix is not left enabled
    # by an image or earlier configuration.
    $profilesKey = 'HKLM:\SOFTWARE\FSLogix\Profiles'
    if (Test-Path $profilesKey) {
        New-ItemProperty -Path $profilesKey -Name 'Enabled' -Value 0 -PropertyType DWord -Force | Out-Null
    }
}

# Consumer and inbox apps only. Framework packages (WindowsAppRuntime) and shell components (Start menu, people
# and print experience hosts, capture picker and similar) are deliberately kept: removing them breaks Windows or apps.
$appsToRemove = @(
    'Clipchamp.Clipchamp'
    'Microsoft.BingNews'
    'Microsoft.BingSearch'
    'Microsoft.BingWeather'
    'Microsoft.GamingApp'
    'Microsoft.GetHelp'
    'Microsoft.MicrosoftOfficeHub'
    'Microsoft.MicrosoftSolitaireCollection'
    'Microsoft.MicrosoftStickyNotes'
    'Microsoft.OutlookForWindows'
    'Microsoft.People'
    'Microsoft.PowerAutomateDesktop'
    'Microsoft.Todos'
    'Microsoft.Windows.DevHome'
    'Microsoft.WindowsAlarms'
    'Microsoft.WindowsCamera'
    'Microsoft.WindowsCommunicationsApps'
    'Microsoft.WindowsFeedbackHub'
    'Microsoft.WindowsMaps'
    'Microsoft.WindowsSoundRecorder'
    'Microsoft.Xbox.TCUI'
    'Microsoft.XboxGameOverlay'
    'Microsoft.XboxGamingOverlay'
    'Microsoft.XboxIdentityProvider'
    'Microsoft.XboxSpeechToTextOverlay'
    'Microsoft.YourPhone'
    'Microsoft.ZuneMusic'
    'Microsoft.ZuneVideo'
    'MicrosoftCorporationII.QuickAssist'
    '*Microsoft.Getstarted*'
)

# App removal is best effort; a package missing from the image must not fail host preparation.
foreach ($app in $appsToRemove) {
    Get-AppxPackage -Name $app -AllUsers -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
    Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
        Where-Object DisplayName -like $app |
        Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Out-Null
}
