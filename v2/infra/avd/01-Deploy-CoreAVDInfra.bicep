param storageAccountName string
param kerberosDomainName string
param kerberosDomainGuid string
param avdUsersGroupOid string
param avdAdminsGroupOid string
param vnetResourceGroup string
param vnetName string
param subnetName string
param defaultPrefix string

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
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
    azureFilesIdentityBasedAuthentication: {
      directoryServiceOptions: 'AADKERB'
      activeDirectoryProperties: {
        domainName: kerberosDomainName
        domainGuid: kerberosDomainGuid
      }
    }
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
    supportsHttpsTrafficOnly: true
  }
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-01-01' = {
  name: 'default'
  parent: storageAccount
  properties: {
    shareDeleteRetentionPolicy: {
      enabled: false
    }
  }
}

resource fileShareProfiles 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-01-01' = {
  name: 'profiles'
  parent: fileService
}

resource fileShareRedirection 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-01-01' = {
  name: 'redirections'
  parent: fileService
}

resource avdUsersAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, avdUsersGroupOid, 'FileShareContributor')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb')
    principalId: avdUsersGroupOid
    principalType: 'Group'
  }
}

resource avdAdminsAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
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

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-05-01' = {
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
  properties: {
    friendlyName: '${defaultPrefix} Host Pool'
    description: '${defaultPrefix} AVD Host Pool for users to securely access resources from'
    hostPoolType: 'Pooled'
    loadBalancerType: 'BreadthFirst'
    maxSessionLimit: 5
    personalDesktopAssignmentType: 'Automatic'
    startVMOnConnect: true
    preferredAppGroupType: 'Desktop'
    customRdpProperty: 'enablecredsspsupport:i:1;authentication level:i:2;enablerdsaadauth:i:1;redirectwebauthn:i:1;'
  }
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
    friendlyName: '${defaultPrefix} Workspace'
    applicationGroupReferences: [
      appGroup.id
    ]
  }
}

output storageAccountId string = storageAccount.id
output profilesShareName string = fileShareProfiles.name
output redirectionShareName string = fileShareRedirection.name
output privateEndpointId string = privateEndpoint.id
output hostPoolId string = hostPool.id
output appGroupId string = appGroup.id
output workspaceId string = workspace.id