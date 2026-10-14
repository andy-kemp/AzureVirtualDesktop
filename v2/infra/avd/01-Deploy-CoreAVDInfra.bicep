@description('User profile option. LocalProfile deploys no storage, private endpoint or FSLogix shares.')
@allowed(['AzureFilesHybridKerberos', 'AzureFilesEntraKerberosCloudOnly', 'LocalProfile'])
param profile string = 'AzureFilesHybridKerberos'
param storageAccountName string = ''
@description('Hybrid AD domain name; only used by AzureFilesHybridKerberos.')
param kerberosDomainName string = ''
@description('Hybrid AD domain GUID; only used by AzureFilesHybridKerberos.')
param kerberosDomainGuid string = ''
param avdUsersGroupOid string
param avdAdminsGroupOid string
param vnetResourceGroup string
param vnetName string
param subnetName string
param defaultPrefix string
@allowed(['Pooled', 'Personal'])
param hostPoolType string = 'Pooled'
@minValue(1)
@maxValue(999)
param maxSessionLimit int = 5
@description('Workspace name users see; empty for "<prefix> Workspace".')
param workspaceFriendlyName string = ''
@allowed(['BreadthFirst', 'DepthFirst'])
param loadBalancerType string = 'BreadthFirst'
@allowed(['Automatic', 'Direct'])
param personalDesktopAssignmentType string = 'Automatic'

var isPersonal = hostPoolType == 'Personal'
var deployStorage = profile != 'LocalProfile'
// Cloud-only Entra Kerberos has no AD domain; hybrid supplies domain details for Windows ACL tooling.
var filesIdentity = profile == 'AzureFilesHybridKerberos'
  ? {
      directoryServiceOptions: 'AADKERB'
      activeDirectoryProperties: {
        domainName: kerberosDomainName
        domainGuid: kerberosDomainGuid
      }
    }
  : {
      directoryServiceOptions: 'AADKERB'
    }

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = if (deployStorage) {
  name: storageAccountName
  location: resourceGroup().location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    publicNetworkAccess: 'Disabled'
    minimumTlsVersion: 'TLS1_2'
    azureFilesIdentityBasedAuthentication: filesIdentity
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
    supportsHttpsTrafficOnly: true
  }
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-01-01' = if (deployStorage) {
  name: 'default'
  parent: storageAccount
  properties: {
    shareDeleteRetentionPolicy: {
      enabled: false
    }
  }
}

resource fileShareProfiles 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-01-01' = if (deployStorage) {
  name: 'profiles'
  parent: fileService
}

resource fileShareRedirection 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-01-01' = if (deployStorage) {
  name: 'redirections'
  parent: fileService
}

resource avdUsersAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployStorage) {
  name: guid(storageAccount.id, avdUsersGroupOid, 'FileShareContributor')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb')
    principalId: avdUsersGroupOid
    principalType: 'Group'
  }
}

resource avdAdminsAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployStorage) {
  name: guid(storageAccount.id, avdAdminsGroupOid, 'FileShareElevatedContributor')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'a7264617-510b-434b-a828-9731dc254ea7')
    principalId: avdAdminsGroupOid
    principalType: 'Group'
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-06-01' existing = {
  name: vnetName
  scope: resourceGroup(vnetResourceGroup)
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2023-06-01' existing = {
  parent: vnet
  name: subnetName
}

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-05-01' = if (deployStorage) {
  name: '${storageAccountName}-file-pe'
  location: resourceGroup().location
  properties: {
    subnet: {
      id: subnet.id
    }
    privateLinkServiceConnections: [
      {
        name: 'storageAccountFileConnection'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: [
            'file'
          ]
        }
      }
    ]
  }
}

resource hostPool 'Microsoft.DesktopVirtualization/hostPools@2021-07-12' = {
  name: '${defaultPrefix}-HostPool'
  location: resourceGroup().location
  properties: union({
    friendlyName: '${defaultPrefix} Host Pool'
    description: '${defaultPrefix} AVD Host Pool for users to securely access resources from'
    hostPoolType: hostPoolType
    loadBalancerType: isPersonal ? 'Persistent' : loadBalancerType
    personalDesktopAssignmentType: personalDesktopAssignmentType
    startVMOnConnect: true
    preferredAppGroupType: 'Desktop'
    customRdpProperty: 'enablecredsspsupport:i:1;authentication level:i:2;enablerdsaadauth:i:1;redirectwebauthn:i:1;'
  }, isPersonal ? {} : {
    maxSessionLimit: maxSessionLimit
  })
}

resource appGroup 'Microsoft.DesktopVirtualization/applicationGroups@2021-07-12' = {
  name: '${defaultPrefix}-AppGroup'
  location: resourceGroup().location
  properties: {
    description: '${defaultPrefix} Application Group'
    friendlyName: '${defaultPrefix} Desktop Application Group'
    hostPoolArmPath: hostPool.id
    applicationGroupType: 'Desktop'
  }
}

resource workspace 'Microsoft.DesktopVirtualization/workspaces@2021-07-12' = {
  name: '${defaultPrefix}-Workspace'
  location: resourceGroup().location
  properties: {
    description: '${defaultPrefix} Workspace'
    friendlyName: empty(workspaceFriendlyName) ? '${defaultPrefix} Workspace' : workspaceFriendlyName
    applicationGroupReferences: [
      appGroup.id
    ]
  }
}

output storageAccountId string = deployStorage ? storageAccount.id : ''
output profilesShareName string = deployStorage ? fileShareProfiles.name : ''
output redirectionShareName string = deployStorage ? fileShareRedirection.name : ''
output privateEndpointId string = deployStorage ? privateEndpoint.id : ''
output hostPoolId string = hostPool.id
output appGroupId string = appGroup.id
output workspaceId string = workspace.id
