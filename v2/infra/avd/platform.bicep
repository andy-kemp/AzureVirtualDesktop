targetScope = 'resourceGroup'

import { hostPoolConfiguration, scalingConfiguration } from './types.bicep'

@description('Prefix for AVD resources and host pool.')
param defaultPrefix string
@description('User profile option: FSLogix on Azure Files for hybrid or cloud-only (preview) identities, or local profiles on dedicated VMs.')
@allowed(['AzureFilesHybridKerberos', 'AzureFilesEntraKerberosCloudOnly', 'LocalProfile'])
param profile string = 'AzureFilesHybridKerberos'
@description('Globally unique Azure Storage account name; empty for LocalProfile.')
param storageAccountName string = ''
@description('Hybrid Kerberos domain name; AzureFilesHybridKerberos only.')
param kerberosDomainName string = ''
@description('Hybrid Kerberos domain GUID; AzureFilesHybridKerberos only.')
param kerberosDomainGuid string = ''
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
@description('Optional host pool behaviour from persona sizing. Omit for the legacy pooled default (5 sessions, breadth-first).')
param hostPool hostPoolConfiguration?
@description('Optional AVD autoscale plan for the host pool. Omit to deploy no scaling plan.')
param scaling scalingConfiguration?
@description('Workspace name users see in Windows App; empty for the default "<prefix> Workspace".')
@maxLength(64)
param workspaceFriendlyName string = ''

module platform './modules/platform.bicep' = {
  params: {
    defaultPrefix: defaultPrefix
    profile: profile
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
    hostPool: hostPool
    scaling: scaling
    workspaceFriendlyName: workspaceFriendlyName
  }
}

output resourceGroupName string = resourceGroup().name
output hostPoolName string = '${defaultPrefix}-HostPool'
output hostPoolType string = hostPool.?type ?? 'Pooled'
output appGroupId string = platform.outputs.appGroupId
output workspaceId string = platform.outputs.workspaceId
output scalingPlanId string = platform.outputs.scalingPlanId
output profilesPath string = profile == 'LocalProfile' ? '' : '\\\\${storageAccountName}.file.${environment().suffixes.storage}\\profiles'