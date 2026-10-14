@description('Prefix for all session hosts.')
param sessionHostPrefix string
@description('Existing host pool to register with; independent of VM names.')
param hostPoolName string
@description('Session host VM size.')
param vmSize string
@description('Number of session hosts to deploy.')
@minValue(1)
@maxValue(100)
param numberOfHosts int
@secure()
@description('Local session host administrator password, supplied at execution time from the configured secret reference.')
param adminPassword string
@description('Local session host administrator username.')
param adminUsername string
@secure()
@description('Temporary registration token created for this host-pool operation.')
param hostPoolRegistrationInfoToken string
@description('Resource group containing the existing VNet.')
param vNetResourceGroup string
@description('Existing VNet name.')
param vNetName string
@description('Existing session-host subnet name.')
param subnetName string
@description('Azure Files storage account name for profile paths; empty for local profiles.')
param storageAccountName string = ''
@description('Optional primary DNS server.')
param dns1 string = ''
@description('Optional secondary DNS server.')
param dns2 string = ''
@description('Reviewed, immutable HTTPS session host preparation script URI.')
param sessionHostPrepScriptUrl string
@description('Existing host pool type; selects the multi-session (Pooled) or single-session (Personal) Windows 11 image.')
@allowed(['Pooled', 'Personal'])
param hostPoolType string = 'Pooled'
@description('FSLogix configures profile containers on Azure Files; Local keeps profiles on the VM (dedicated hosts).')
@allowed(['FSLogix', 'Local'])
param profileMode string = 'FSLogix'
@description('FSLogix only: block sign-in instead of issuing a temporary profile when the container cannot attach.')
param preventTempProfile bool = false

var fsProfilesPath = '\\\\${storageAccountName}.file.${environment().suffixes.storage}\\profiles'
var fsRedirectionPath = '\\\\${storageAccountName}.file.${environment().suffixes.storage}\\redirections'
var modulesURL = 'https://wvdportalstorageblob.blob.${environment().suffixes.storage}/galleryartifacts/Configuration_1.0.02797.442.zip'
var sessionHostPrepScriptName = substring(sessionHostPrepScriptUrl, lastIndexOf(sessionHostPrepScriptUrl, '/') + 1)
var sessionHostPrepArguments = profileMode == 'FSLogix'
  ? '-ProfileMode FSLogix -ProfilesPath "${fsProfilesPath}" -RedirectionPath "${fsRedirectionPath}"${preventTempProfile ? ' -PreventTempProfile' : ''}'
  : '-ProfileMode Local'
var dnsServers = concat(empty(dns1) ? [] : [dns1], empty(dns2) ? [] : [dns2])

resource hostPool 'Microsoft.DesktopVirtualization/hostPools@2021-07-12' existing = {
  name: hostPoolName
}

resource existingSubnet 'Microsoft.Network/virtualNetworks/subnets@2021-05-01' existing = {
  name: '${vNetName}/${subnetName}'
  scope: resourceGroup(vNetResourceGroup)
}

resource nic 'Microsoft.Network/networkInterfaces@2020-11-01' = [for i in range(0, numberOfHosts): {
  name: '${sessionHostPrefix}-${i}-nic'
  location: resourceGroup().location
  properties: union({
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: existingSubnet.id
          }
        }
      }
    ]
  }, empty(dnsServers) ? {} : {
    dnsSettings: {
      dnsServers: dnsServers
    }
  })
}]

resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = [for i in range(0, numberOfHosts): {
  name: '${sessionHostPrefix}-${i}'
  location: resourceGroup().location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
    osProfile: {
      computerName: '${sessionHostPrefix}-${i}'
      adminUsername: adminUsername
      adminPassword: adminPassword
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsDesktop'
        offer: 'Windows-11'
        sku: hostPoolType == 'Personal' ? 'win11-24h2-ent' : 'win11-24h2-avd'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: 256
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic[i].id
        }
      ]
    }
  }
}]

resource entraIdJoin 'Microsoft.Compute/virtualMachines/extensions@2021-11-01' = [for i in range(0, numberOfHosts): {
  parent: vm[i]
  name: '${sessionHostPrefix}-${i}-EntraJoinEntrollIntune'
  location: resourceGroup().location
  properties: {
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: 'AADLoginForWindows'
    typeHandlerVersion: '2.2'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: false
    settings: {
      mdmId: '0000000a-0000-0000-c000-000000000000'
    }
  }
}]

resource guestAttestationExtension 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = [for i in range(0, numberOfHosts): {
  parent: vm[i]
  name: '${sessionHostPrefix}-${i}-guestAttestationExtension'
  location: resourceGroup().location
  properties: {
    publisher: 'Microsoft.Azure.Security.WindowsAttestation'
    type: 'GuestAttestation'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
  }
  dependsOn: [
    entraIdJoin
  ]
}]

resource sessionPrep 'Microsoft.Compute/virtualMachines/extensions@2021-03-01' = [for i in range(0, numberOfHosts): {
  parent: vm[i]
  name: '${sessionHostPrefix}-${i}-SessionPrep'
  location: resourceGroup().location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    settings: {
      fileUris: [
        sessionHostPrepScriptUrl
      ]
      commandToExecute: 'powershell -ExecutionPolicy Unrestricted -File .\\${sessionHostPrepScriptName} ${sessionHostPrepArguments}'
    }
  }
  dependsOn: [
    guestAttestationExtension
  ]
}]

resource joinHostPool 'Microsoft.Compute/virtualMachines/extensions@2024-03-01' = [for i in range(0, numberOfHosts): {
  parent: vm[i]
  name: '${sessionHostPrefix}-${i}-JointoHostPool'
  location: resourceGroup().location
  properties: {
    publisher: 'Microsoft.Powershell'
    type: 'DSC'
    typeHandlerVersion: '2.76'
    settings: {
      modulesUrl: modulesURL
      configurationFunction: 'Configuration.ps1\\AddSessionHost'
      properties: {
        hostPoolName: hostPool.name
        aadJoin: true
      }
    }
    protectedSettings: {
      properties: {
        registrationInfoToken: hostPoolRegistrationInfoToken
      }
    }
  }
  dependsOn: [
    sessionPrep
  ]
}]

output sessionHostNames array = [for hostIndex in range(0, numberOfHosts): '${sessionHostPrefix}-${hostIndex}']