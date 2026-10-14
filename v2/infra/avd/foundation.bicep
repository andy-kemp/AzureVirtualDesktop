targetScope = 'subscription'

@description('Target resource group for the AVD workload.')
param resourceGroupName string
@description('Azure region for the resource group and foundation resources.')
param location string
@description('Create the resource group if it does not exist.')
param createResourceGroup bool = true
@description('Optional new network: { addressSpace, vnetName, sessionHostSubnetName, privateEndpointSubnetName }. Omit to use an existing network.')
param network object?
@description('Optional Key Vault: { name, secretName }. Omit to use an existing vault.')
param keyVault object?
@secure()
@description('Generated session host admin password; only supplied when the secret does not exist yet, so reruns never rotate it.')
param adminPassword string = ''
@description('Optional user-assigned managed identity name for deployments.')
param deploymentIdentityName string = ''
@description('Create the deployment identity; false references an existing one for its Key Vault role assignment.')
param createDeploymentIdentity bool = true
@description('Object ID of the signed-in operator; receives Key Vault Secrets User so Deploy can read the password on reruns.')
param operatorObjectId string = ''
@description('Principal type of operatorObjectId.')
@allowed(['User', 'ServicePrincipal'])
param operatorPrincipalType string = 'User'
@description('Azure Virtual Desktop service principal object ID. When set, grants Desktop Virtualization Power On Off Contributor at subscription scope, which AVD requires before a scaling plan can be created.')
param autoscaleServicePrincipalId string = ''

var powerOnOffRole = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '40c5ff49-9181-41f8-ae61-143b0e78555e')

resource autoscaleRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(autoscaleServicePrincipalId)) {
  name: guid(subscription().id, autoscaleServicePrincipalId, powerOnOffRole)
  properties: {
    principalId: autoscaleServicePrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: powerOnOffRole
  }
}

resource workloadGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = if (createResourceGroup) {
  name: resourceGroupName
  location: location
}

module resources './modules/foundation-resources.bicep' = {
  scope: resourceGroup(resourceGroupName)
  params: {
    location: location
    network: network
    keyVault: keyVault
    adminPassword: adminPassword
    deploymentIdentityName: deploymentIdentityName
    createDeploymentIdentity: createDeploymentIdentity
    operatorObjectId: operatorObjectId
    operatorPrincipalType: operatorPrincipalType
  }
  dependsOn: [workloadGroup]
}

output resourceGroupId string = subscriptionResourceId('Microsoft.Resources/resourceGroups', resourceGroupName)
output virtualNetworkId string = resources.outputs.virtualNetworkId
output keyVaultUri string = resources.outputs.keyVaultUri
output deploymentIdentityClientId string = resources.outputs.deploymentIdentityClientId
output deploymentIdentityPrincipalId string = resources.outputs.deploymentIdentityPrincipalId
