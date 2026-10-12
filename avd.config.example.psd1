@{
    SubscriptionId = '00000000-0000-0000-0000-000000000000'
    ResourceGroupName = 'avd-prod'
    Location = 'uksouth'
    DefaultPrefix = 'AVD'
    StorageAccountName = 'replacewithuniquename'
    KerberosDomainName = 'corp.contoso.com'
    KerberosDomainGuid = '00000000-0000-0000-0000-000000000000'
    AvdUsersGroupOid = '00000000-0000-0000-0000-000000000000'
    AvdAdminsGroupOid = '00000000-0000-0000-0000-000000000000'
    VnetResourceGroup = 'Core-Services'
    VnetName = 'Master-vNet'
    PrivateEndpointSubnetName = 'Storage'
    SessionHostSubnetName = 'AzureVirtualDesktop'
    DeployPrivateDns = $true
    SessionHostPrefix = 'AVD'
    NumberOfHosts = 2
    AdminUsername = 'AVD-Admin'
    VmSize = 'Standard_D2as_v5'
    Dns1 = ''
    Dns2 = ''
    SessionHostPrepScriptUrl = 'https://raw.githubusercontent.com/andrew-kemp/AzureVirtualDesktop/refs/heads/main/02a-SessionHostPrep.ps1'
}