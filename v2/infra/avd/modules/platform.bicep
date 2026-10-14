import { hostPoolConfiguration, scalingConfiguration } from '../types.bicep'

param defaultPrefix string
@allowed(['AzureFilesHybridKerberos', 'AzureFilesEntraKerberosCloudOnly', 'LocalProfile'])
param profile string = 'AzureFilesHybridKerberos'
param storageAccountName string = ''
param kerberosDomainName string = ''
param kerberosDomainGuid string = ''
param avdUsersGroupOid string
param avdAdminsGroupOid string
param avdServicePrincipalOid string
param vnetResourceGroup string
param vnetName string
param privateEndpointSubnetName string
param deployPrivateDns bool
param hostPool hostPoolConfiguration?
param scaling scalingConfiguration?
param workspaceFriendlyName string = ''

var hostPoolType = hostPool.?type ?? 'Pooled'
var isPersonal = hostPoolType == 'Personal'
var deployStorage = profile != 'LocalProfile'
var deployFileDns = deployStorage && deployPrivateDns

module core '../01-Deploy-CoreAVDInfra.bicep' = {
  params: {
    defaultPrefix: defaultPrefix
    profile: profile
    storageAccountName: storageAccountName
    kerberosDomainName: kerberosDomainName
    kerberosDomainGuid: kerberosDomainGuid
    avdUsersGroupOid: avdUsersGroupOid
    avdAdminsGroupOid: avdAdminsGroupOid
    vnetResourceGroup: vnetResourceGroup
    vnetName: vnetName
    subnetName: privateEndpointSubnetName
    hostPoolType: hostPoolType
    maxSessionLimit: hostPool.?maxSessionLimit ?? 5
    loadBalancerType: hostPool.?loadBalancer ?? 'BreadthFirst'
    personalDesktopAssignmentType: hostPool.?assignmentType ?? 'Automatic'
    workspaceFriendlyName: workspaceFriendlyName
  }
}

resource appGroup 'Microsoft.DesktopVirtualization/applicationGroups@2024-04-03' existing = {
  name: '${defaultPrefix}-AppGroup'
}

var desktopUserRole = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63')
resource desktopAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for principalId in union([avdUsersGroupOid], [avdAdminsGroupOid]): {
  name: guid(appGroup.id, principalId, desktopUserRole)
  scope: appGroup
  properties: {
    principalId: principalId
    principalType: 'Group'
    roleDefinitionId: desktopUserRole
  }
  dependsOn: [core]
}]

var loginAssignments = [
  {
    principalId: avdUsersGroupOid
    roleId: 'fb879df8-f326-4884-b1cf-06f3ad86be52'
  }
  {
    principalId: avdAdminsGroupOid
    roleId: '1c0163c0-47e6-4577-8991-ea5c82e286e4'
  }
]
resource vmLogin 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for assignment in loginAssignments: {
  name: guid(resourceGroup().id, assignment.principalId, assignment.roleId)
  properties: {
    principalId: assignment.principalId
    principalType: 'Group'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', assignment.roleId)
  }
}]

// Desktop Virtualization Power On Contributor (Start VM on Connect).
var powerOnRole = '489581de-a3bd-480d-9518-53dea7416b33'
resource startOnConnect 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, avdServicePrincipalOid, powerOnRole)
  properties: {
    principalId: avdServicePrincipalOid
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', powerOnRole)
  }
}

resource hostPoolResource 'Microsoft.DesktopVirtualization/hostPools@2024-04-03' existing = {
  name: '${defaultPrefix}-HostPool'
}

func toScalingTime(value string) object => {
  hour: int(split(value, ':')[0])
  minute: int(split(value, ':')[1])
}

func toEnabled(value bool) string => value ? 'Enable' : 'Disable'

// Null-safe access because ARM can expand copy loops even when the resource condition is false.
var configuredSchedules = scaling.?schedules ?? []

var pooledSchedules = [for schedule in (isPersonal ? [] : configuredSchedules): {
  name: schedule.name
  daysOfWeek: schedule.daysOfWeek
  rampUpStartTime: toScalingTime(schedule.rampUp.startTime)
  rampUpMinimumHostsPct: schedule.rampUp.minimumHostsPct
  rampUpCapacityThresholdPct: schedule.rampUp.capacityThresholdPct
  rampUpLoadBalancingAlgorithm: schedule.rampUp.loadBalancing
  peakStartTime: toScalingTime(schedule.peak.startTime)
  peakLoadBalancingAlgorithm: schedule.peak.loadBalancing
  rampDownStartTime: toScalingTime(schedule.rampDown.startTime)
  rampDownMinimumHostsPct: schedule.rampDown.minimumHostsPct
  rampDownCapacityThresholdPct: schedule.rampDown.capacityThresholdPct
  rampDownLoadBalancingAlgorithm: schedule.rampDown.loadBalancing
  rampDownForceLogoffUsers: schedule.rampDown.forceLogoffUsers
  rampDownWaitTimeMinutes: schedule.rampDown.waitTimeMinutes
  rampDownNotificationMessage: schedule.rampDown.?notificationMessage ?? ''
  rampDownStopHostsWhen: schedule.rampDown.stopHostsWhen
  offPeakStartTime: toScalingTime(schedule.offPeak.startTime)
  offPeakLoadBalancingAlgorithm: schedule.offPeak.loadBalancing
}]

// Power management only: the subscription-scope Power On Off Contributor grant for the AVD service principal is a customer prerequisite, not created here.
resource scalingPlan 'Microsoft.DesktopVirtualization/scalingPlans@2024-04-03' = if (scaling != null) {
  name: '${defaultPrefix}-ScalingPlan'
  location: resourceGroup().location
  properties: {
    friendlyName: '${defaultPrefix} Scaling Plan'
    description: '${defaultPrefix} AVD autoscale schedule for ${hostPoolResource.name}'
    // The service accepts 'Personal' (as used by the Azure Verified Module) although published API types list only 'Pooled'.
    hostPoolType: any(hostPoolType)
    timeZone: scaling.?timeZone ?? ''
    exclusionTag: scaling.?exclusionTag
    hostPoolReferences: [
      {
        hostPoolArmPath: hostPoolResource.id
        scalingPlanEnabled: scaling.?enabled ?? false
      }
    ]
    schedules: pooledSchedules
  }
  dependsOn: [core]
}

resource personalSchedules 'Microsoft.DesktopVirtualization/scalingPlans/personalSchedules@2024-04-03' = [for schedule in (isPersonal ? configuredSchedules : []): {
  parent: scalingPlan
  name: schedule.name
  properties: {
    daysOfWeek: schedule.daysOfWeek
    rampUpStartTime: toScalingTime(schedule.rampUp.startTime)
    rampUpAutoStartHosts: schedule.rampUp.autoStartHosts
    rampUpStartVMOnConnect: toEnabled(schedule.rampUp.startVMOnConnect)
    rampUpActionOnDisconnect: schedule.rampUp.actionOnDisconnect
    rampUpMinutesToWaitOnDisconnect: schedule.rampUp.minutesToWaitOnDisconnect
    rampUpActionOnLogoff: schedule.rampUp.actionOnLogoff
    rampUpMinutesToWaitOnLogoff: schedule.rampUp.minutesToWaitOnLogoff
    peakStartTime: toScalingTime(schedule.peak.startTime)
    peakStartVMOnConnect: toEnabled(schedule.peak.startVMOnConnect)
    peakActionOnDisconnect: schedule.peak.actionOnDisconnect
    peakMinutesToWaitOnDisconnect: schedule.peak.minutesToWaitOnDisconnect
    peakActionOnLogoff: schedule.peak.actionOnLogoff
    peakMinutesToWaitOnLogoff: schedule.peak.minutesToWaitOnLogoff
    rampDownStartTime: toScalingTime(schedule.rampDown.startTime)
    rampDownStartVMOnConnect: toEnabled(schedule.rampDown.startVMOnConnect)
    rampDownActionOnDisconnect: schedule.rampDown.actionOnDisconnect
    rampDownMinutesToWaitOnDisconnect: schedule.rampDown.minutesToWaitOnDisconnect
    rampDownActionOnLogoff: schedule.rampDown.actionOnLogoff
    rampDownMinutesToWaitOnLogoff: schedule.rampDown.minutesToWaitOnLogoff
    offPeakStartTime: toScalingTime(schedule.offPeak.startTime)
    offPeakStartVMOnConnect: toEnabled(schedule.offPeak.startVMOnConnect)
    offPeakActionOnDisconnect: schedule.offPeak.actionOnDisconnect
    offPeakMinutesToWaitOnDisconnect: schedule.offPeak.minutesToWaitOnDisconnect
    offPeakActionOnLogoff: schedule.offPeak.actionOnLogoff
    offPeakMinutesToWaitOnLogoff: schedule.offPeak.minutesToWaitOnLogoff
  }
}]

resource vnet 'Microsoft.Network/virtualNetworks@2023-06-01' existing = {
  name: vnetName
  scope: resourceGroup(vnetResourceGroup)
}

resource fileDns 'Microsoft.Network/privateDnsZones@2020-06-01' = if (deployFileDns) {
  name: 'privatelink.file.${environment().suffixes.storage}'
  location: 'global'
}

resource vnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = if (deployFileDns) {
  parent: fileDns
  name: '${defaultPrefix}-files'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-05-01' existing = {
  name: '${storageAccountName}-file-pe'
}

resource dnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-05-01' = if (deployFileDns) {
  parent: privateEndpoint
  name: 'files'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'files'
        properties: {
          privateDnsZoneId: fileDns.id
        }
      }
    ]
  }
  dependsOn: [core]
}

output appGroupId string = core.outputs.appGroupId
output workspaceId string = core.outputs.workspaceId
output scalingPlanId string = scaling != null ? scalingPlan.id : ''