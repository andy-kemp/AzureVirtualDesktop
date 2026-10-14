param defaultPrefix string
param storageAccountName string
param kerberosDomainName string
param kerberosDomainGuid string
param avdUsersGroupOid string
param avdAdminsGroupOid string
param avdServicePrincipalOid string
param vnetResourceGroup string
param vnetName string
param privateEndpointSubnetName string
param deployPrivateDns bool

module core '../01-Deploy-CoreAVDInfra.bicep' = {
  params: {
    defaultPrefix: defaultPrefix
    storageAccountName: storageAccountName
    kerberosDomainName: kerberosDomainName
    kerberosDomainGuid: kerberosDomainGuid
    avdUsersGroupOid: avdUsersGroupOid
    avdAdminsGroupOid: avdAdminsGroupOid
    vnetResourceGroup: vnetResourceGroup
    vnetName: vnetName
    subnetName: privateEndpointSubnetName
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

resource vnet 'Microsoft.Network/virtualNetworks@2023-06-01' existing = {
  name: vnetName
  scope: resourceGroup(vnetResourceGroup)
}

resource fileDns 'Microsoft.Network/privateDnsZones@2020-06-01' = if (deployPrivateDns) {
  name: 'privatelink.file.${environment().suffixes.storage}'
  location: 'global'
}

resource vnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = if (deployPrivateDns) {
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

resource dnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-05-01' = if (deployPrivateDns) {
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
