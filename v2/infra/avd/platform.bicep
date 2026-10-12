targetScope = 'resourceGroup'

@description('Prefix for AVD resources and host pool.')
param defaultPrefix string
@description('Globally unique Azure Storage account name.')
param storageAccountName string
@description('Hybrid Kerberos domain name.')
param kerberosDomainName string
@description('Hybrid Kerberos domain GUID.')
param kerberosDomainGuid string
@description('Existing Entra group object ID for AVD users.')
param avdUsersGroupOid string
@description('Existing Entra group object ID for AVD administrators.')
param avdAdminsGroupOid string
@description('Existing Azure Virtual Desktop service principal object ID.')
param avdServicePrincipalOid string
@description('Resource group containing the existing VNet.')
param vnetResourceGroup string
@description('Existing VNet name.')
param vnetName string
@description('Existing private endpoint subnet name.')
param privateEndpointSubnetName string
@description('Create/link private DNS in this resource group; false for centrally managed DNS.')
param deployPrivateDns bool = true

module platform './modules/platform.bicep' = {
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

output resourceGroupName string = resourceGroup().name
output hostPoolName string = '${defaultPrefix}-HostPool'
output appGroupId string = platform.outputs.appGroupId
output workspaceId string = platform.outputs.workspaceId
output profilesPath string = '\\\\${storageAccountName}.file.${environment().suffixes.storage}\\profiles'