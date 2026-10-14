#requires -Version 7.2
Set-StrictMode -Version Latest

$script:ProfilePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'contracts/sizing-profiles.json'
$script:MaximumHosts = 100

function Get-AvdSizingProfile {
    [CmdletBinding()]
    param()

    return (ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($script:ProfilePath)) -AsHashtable -Depth 16)
}

function Get-AvdSizingRecommendation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Shared', 'Dedicated')]
        [string]$Hosting,
        [Parameter(Mandatory)]
        [ValidateSet('Frontline', 'Standard', 'Heavy')]
        [string]$Persona,
        [Parameter(Mandatory)]
        [ValidateRange(1, 5000)]
        [int]$Users,
        [ValidateRange(1, 100)]
        [int]$PeakConcurrencyPct = 100
    )

    $sizing = Get-AvdSizingProfile
    $personaProfile = $sizing.personas[$Persona]

    if ($Hosting -eq 'Dedicated') {
        if ($Users -gt $script:MaximumHosts) {
            throw "Dedicated hosting needs one VM per user; $Users users exceeds the V2 maximum of $script:MaximumHosts session hosts per pool."
        }
        return [ordered]@{
            hostPool     = [ordered]@{ type = 'Personal'; assignmentType = 'Direct' }
            sessionHosts = [ordered]@{ count = $Users; vmSize = $personaProfile.dedicatedVmSize }
            explanation  = @(
                "Dedicated: one personal VM per user ($Users users = $Users hosts), assigned to named users with -Mode AddUser.",
                "$($personaProfile.label) ($($personaProfile.microsoftWorkload) workload): $($personaProfile.dedicatedVmSize) per user."
            )
        }
    }

    $usersPerHost = [int]($sizing.shared.vcpus * $personaProfile.usersPerVcpu)
    $peakUsers = [int][Math]::Max(1, [Math]::Ceiling($Users * $PeakConcurrencyPct / 100.0))
    $capacityHosts = [int][Math]::Ceiling($peakUsers / [double]$usersPerHost)
    $hostCount = $capacityHosts + [int]$sizing.shared.spareHosts
    if ($hostCount -gt $script:MaximumHosts) {
        throw "Shared sizing needs $hostCount session hosts, which exceeds the V2 maximum of $script:MaximumHosts per pool. Split users across pools."
    }

    return [ordered]@{
        hostPool     = [ordered]@{ type = 'Pooled'; maxSessionLimit = $usersPerHost; loadBalancer = $sizing.shared.loadBalancer }
        sessionHosts = [ordered]@{ count = $hostCount; vmSize = $sizing.shared.vmSize }
        explanation  = @(
            "Shared: $Users users at $PeakConcurrencyPct% peak = $peakUsers concurrent sessions.",
            "$($personaProfile.label) ($($personaProfile.microsoftWorkload) workload): $($personaProfile.usersPerVcpu) users/vCPU x $($sizing.shared.vcpus) vCPU $($sizing.shared.vmSize) = $usersPerHost sessions per host.",
            "$capacityHosts host(s) for capacity + $($sizing.shared.spareHosts) spare = $hostCount host(s)."
        )
    }
}

function ConvertTo-ScheduleTime {
    param([TimeSpan]$Value)
    return $Value.ToString('hh\:mm', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-AvdSpareHostThreshold {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(1, 999)]
        [int]$MaxSessionLimit
    )

    # Autoscale needs ceil(sessions / (limit x threshold%)) hosts. A threshold just under one session's
    # share of a host makes that sessions + 1, keeping one empty host ready until every host is running.
    return [int][Math]::Max(1, [Math]::Ceiling(100.0 / $MaxSessionLimit) - 1)
}

function New-AvdBusinessHoursSchedule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Pooled', 'Personal')]
        [string]$HostPoolType,
        [string]$WorkdayStart = '08:00',
        [string]$WorkdayEnd = '18:00',
        [ValidateRange(1, 999)]
        [int]$MaxSessionLimit = 5
    )

    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $start = [TimeSpan]::ParseExact($WorkdayStart, 'hh\:mm', $culture)
    $end = [TimeSpan]::ParseExact($WorkdayEnd, 'hh\:mm', $culture)
    $oneHour = [TimeSpan]::FromHours(1)
    if ($start -lt $oneHour -or $end -gt [TimeSpan]::FromHours(22) -or $end -le $start) {
        throw 'Working hours must start at 01:00 or later, end at 22:00 or earlier, and end after they start.'
    }

    $times = [ordered]@{
        rampUp   = ConvertTo-ScheduleTime ($start - $oneHour)
        peak     = ConvertTo-ScheduleTime $start
        rampDown = ConvertTo-ScheduleTime $end
        offPeak  = ConvertTo-ScheduleTime ($end + $oneHour)
    }
    $weekdays = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday')
    $weekend = @('Saturday', 'Sunday')

    if ($HostPoolType -eq 'Pooled') {
        $spareThreshold = Get-AvdSpareHostThreshold -MaxSessionLimit $MaxSessionLimit
        # Minimum host percentages round up to whole hosts, so 1% keeps exactly one host on in pools of up to 100.
        $pooled = {
            param([string]$Name, [string[]]$Days, [int]$RampUpMinimum, [int]$RampUpThreshold, [string]$DaytimeBalancing)
            [ordered]@{
                name       = $Name
                daysOfWeek = $Days
                rampUp     = [ordered]@{ startTime = $times.rampUp; minimumHostsPct = $RampUpMinimum; capacityThresholdPct = $RampUpThreshold; loadBalancing = $DaytimeBalancing }
                peak       = [ordered]@{ startTime = $times.peak; loadBalancing = $DaytimeBalancing }
                rampDown   = [ordered]@{
                    startTime            = $times.rampDown
                    minimumHostsPct      = 1
                    capacityThresholdPct = 90
                    loadBalancing        = 'DepthFirst'
                    forceLogoffUsers     = $false
                    waitTimeMinutes      = 30
                    notificationMessage  = 'This session host will shut down soon. Please save your work and sign out.'
                    stopHostsWhen        = 'ZeroSessions'
                }
                offPeak    = [ordered]@{ startTime = $times.offPeak; loadBalancing = 'DepthFirst' }
            }
        }
        return @(
            (& $pooled 'weekdays' $weekdays 20 $spareThreshold 'BreadthFirst'),
            (& $pooled 'weekend' $weekend 1 90 'DepthFirst')
        )
    }

    $phase = {
        param([string]$StartTime, [int]$DisconnectMinutes, [int]$LogoffMinutes)
        [ordered]@{
            startTime                 = $StartTime
            startVMOnConnect          = $true
            actionOnDisconnect        = 'Deallocate'
            minutesToWaitOnDisconnect = $DisconnectMinutes
            actionOnLogoff            = 'Deallocate'
            minutesToWaitOnLogoff     = $LogoffMinutes
        }
    }
    $personal = {
        param([string]$Name, [string[]]$Days, [int]$DaytimeDisconnectMinutes)
        $rampUp = & $phase $times.rampUp 60 15
        $rampUp.Insert(1, 'autoStartHosts', 'None')
        [ordered]@{
            name       = $Name
            daysOfWeek = $Days
            rampUp     = $rampUp
            peak       = (& $phase $times.peak $DaytimeDisconnectMinutes 30)
            rampDown   = (& $phase $times.rampDown 30 15)
            offPeak    = (& $phase $times.offPeak 15 5)
        }
    }
    return @(
        (& $personal 'weekdays' $weekdays 120),
        (& $personal 'weekend' $weekend 30)
    )
}

Export-ModuleMember -Function Get-AvdSizingProfile, Get-AvdSizingRecommendation, Get-AvdSpareHostThreshold, New-AvdBusinessHoursSchedule
