targetScope = 'subscription'

@description('Resource group for the AVD deployment. Use a dedicated resource group.')
param resourceGroupName string
param location string
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

@description('Create an Azure Files private DNS zone and VNet link in the AVD resource group. Disable when using centrally managed DNS.')
param deployPrivateDns bool = true

resource avdResourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
}

module platform './modules/platform.bicep' = {
  scope: avdResourceGroup
  params: {
    defaultPrefix: defaultPrefix
    storageAccountName: storageAccountName
    kerberosDomainName: kerberosDomainName
    kerberosDomainGuid: kerberosDomainGuid
    avdUsersGroupOid: avdUsersGroupOid
    avdAdminsGroupOid: avdAdminsGroupOid
    avdServicePrincipalOid: avdServicePrincipalOid
    vnetResourceGroup: vnetResourceGroup
    vnetName: vnetName
    privateEndpointSubnetName: privateEndpointSubnetName
    deployPrivateDns: deployPrivateDns
  }
}

output resourceGroupName string = avdResourceGroup.name
output hostPoolName string = '${defaultPrefix}-HostPool'
output appGroupId string = platform.outputs.appGroupId
output workspaceId string = platform.outputs.workspaceId
output profilesPath string = '\\\\${storageAccountName}.file.${environment().suffixes.storage}\\profiles'
