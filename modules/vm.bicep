param vmName string
param location string
param vmSize string
param windowsSku string
param subnetId string
param nsgId string
param backendPoolId string = ''
param adDnsServerIp string
param localAdminUserName string

@secure()
param localAdminPassword string

param domainJoinUserName string

@secure()
param domainJoinPassword string

param adDomainName string

@description('Optional. Distinguished Name of the OU to join the VM into (e.g. "OU=RDS,OU=Servers,DC=contoso,DC=local"). Leave empty to use the default Computers container.')
param domainJoinOuPath string = ''

param zone string
param tags object

@description('Resource ID of a user-assigned managed identity. Leave empty to use no MSI.')
param userAssignedIdentityId string = ''

@description('Client ID of the user-assigned managed identity (required when installCertFromKeyVault = true).')
param userAssignedIdentityClientId string = ''

@description('When true, deploy the Azure Key Vault VM extension to pull a cert into LocalMachine\\My.')
param installCertFromKeyVault bool = false

@description('Full KV secret URI for the cert, e.g. https://myvault.vault.azure.net/secrets/rdscert')
param keyVaultCertSecretUri string = ''

var inBackendPool = !empty(backendPoolId)
var hasIdentity = !empty(userAssignedIdentityId)

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: '${vmName}-nic'
  location: location
  tags: tags
  properties: {
    networkSecurityGroup: {
      id: nsgId
    }
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: subnetId
          }
          loadBalancerBackendAddressPools: inBackendPool ? [
            {
              id: backendPoolId
            }
          ] : []
        }
      }
    ]
    dnsSettings: {
      dnsServers: [
        adDnsServerIp
      ]
    }
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  tags: tags
  zones: [zone]
  identity: hasIdentity ? {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userAssignedIdentityId}': {}
    }
  } : null
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmName
      adminUsername: localAdminUserName
      adminPassword: localAdminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: true
        provisionVMAgent: true
        patchSettings: {
          patchMode: 'AutomaticByPlatform'
          assessmentMode: 'AutomaticByPlatform'
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: windowsSku
        version: 'latest'
      }
      // Disk SKU updates must be done on Microsoft.Compute/disks directly;
      // sending osDisk.managedDisk.storageAccountType in VM PUT can fail on redeploy.
      osDisk: {
        name: '${vmName}-osdisk'
        caching: 'ReadWrite'
        createOption: 'FromImage'
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

resource domainJoin 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: vm
  name: 'joindomain'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'JsonADDomainExtension'
    typeHandlerVersion: '1.3'
    autoUpgradeMinorVersion: true
    settings: union(
      {
        Name: adDomainName
        User: '${adDomainName}\\${domainJoinUserName}'
        Restart: 'true'
        Options: '3'
      },
      empty(domainJoinOuPath) ? {} : { OUPath: domainJoinOuPath }
    )
    protectedSettings: {
      Password: domainJoinPassword
    }
  }
}

resource akvExtension 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = if (installCertFromKeyVault) {
  parent: vm
  name: 'KeyVaultForWindows'
  location: location
  dependsOn: [
    domainJoin
  ]
  properties: {
    publisher: 'Microsoft.Azure.KeyVault'
    type: 'KeyVaultForWindows'
    typeHandlerVersion: '3.0'
    autoUpgradeMinorVersion: true
    settings: {
      secretsManagementSettings: {
        pollingIntervalInS: '3600'
        certificateStoreName: 'MY'
        certificateStoreLocation: 'LocalMachine'
        requireInitialSync: true
        observedCertificates: [
          keyVaultCertSecretUri
        ]
      }
      authenticationSettings: {
        msiEndpoint: 'http://169.254.169.254/metadata/identity'
        msiClientId: userAssignedIdentityClientId
      }
    }
  }
}

output vmName string = vm.name
output vmId string = vm.id
output nicId string = nic.id
