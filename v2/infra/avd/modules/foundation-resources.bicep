param location string
param network object?
@description('Optional Key Vault: { name, secretName, create }. create=false references an existing vault for the secret and role assignments.')
param keyVault object?
@secure()
param adminPassword string = ''
param deploymentIdentityName string = ''
@description('Create the deployment identity; false references an existing one for its role assignment.')
param createDeploymentIdentity bool = true
param operatorObjectId string = ''
@allowed(['User', 'ServicePrincipal'])
param operatorPrincipalType string = 'User'

var createNetwork = network != null
var useKeyVault = keyVault != null
var createVault = useKeyVault && (keyVault.?create ?? true)
var useIdentity = !empty(deploymentIdentityName)
var createIdentity = useIdentity && createDeploymentIdentity
var addressSpace = network.?addressSpace ?? '10.0.0.0/24'
// Session hosts get the first /25 (up to 123 usable addresses for 100 hosts); private endpoints get a /27 after it.
var sessionHostPrefix = cidrSubnet(addressSpace, 25, 0)
var privateEndpointPrefix = cidrSubnet(addressSpace, 27, 4)

resource sessionHostNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = if (createNetwork) {
  name: '${network.?vnetName ?? 'avd'}-sessionhosts-nsg'
  location: location
  properties: {
    // No inbound rules: AVD uses reverse connect, so session hosts need no inbound internet access.
    securityRules: []
  }
}

resource natPublicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = if (createNetwork) {
  name: '${network.?vnetName ?? 'avd'}-nat-pip'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

// New subnets are private by default, so outbound access to AVD, Entra and the prep script is explicit via NAT.
resource natGateway 'Microsoft.Network/natGateways@2024-05-01' = if (createNetwork) {
  name: '${network.?vnetName ?? 'avd'}-nat'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    idleTimeoutInMinutes: 4
    publicIpAddresses: [
      {
        id: natPublicIp.id
      }
    ]
  }
}

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' = if (createNetwork) {
  name: network.?vnetName ?? 'avd-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        addressSpace
      ]
    }
    subnets: [
      {
        name: network.?sessionHostSubnetName ?? 'session-hosts'
        properties: {
          addressPrefix: sessionHostPrefix
          defaultOutboundAccess: false
          natGateway: {
            id: natGateway.id
          }
          networkSecurityGroup: {
            id: sessionHostNsg.id
          }
        }
      }
      {
        name: network.?privateEndpointSubnetName ?? 'private-endpoints'
        properties: {
          addressPrefix: privateEndpointPrefix
          defaultOutboundAccess: false
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

// Only missing foundation resources are passed in, so these PUTs never overwrite later changes to existing ones.
resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = if (createVault) {
  name: keyVault.?name ?? 'unused'
  location: location
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    publicNetworkAccess: 'Enabled'
  }
}

resource deploymentIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (createIdentity) {
  name: useIdentity ? deploymentIdentityName : 'unused'
  location: location
}

module vaultAccess './foundation-vault-access.bicep' = if (useKeyVault || useIdentity) {
  params: {
    vaultName: keyVault.?name ?? ''
    secretName: keyVault.?secretName ?? 'sessionhost-admin'
    adminPassword: adminPassword
    deploymentIdentityName: deploymentIdentityName
    operatorObjectId: operatorObjectId
    operatorPrincipalType: operatorPrincipalType
  }
  dependsOn: [vault, deploymentIdentity]
}

output virtualNetworkId string = createNetwork ? virtualNetwork.id : ''
output keyVaultUri string = (useKeyVault || useIdentity) ? vaultAccess!.outputs.keyVaultUri : ''
output deploymentIdentityClientId string = (useKeyVault || useIdentity) ? vaultAccess!.outputs.deploymentIdentityClientId : ''
output deploymentIdentityPrincipalId string = (useKeyVault || useIdentity) ? vaultAccess!.outputs.deploymentIdentityPrincipalId : ''
