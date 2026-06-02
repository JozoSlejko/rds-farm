param vmName string
param location string

@description('e.g. Configuration.ps1\\Gateway')
param configurationFunction string

param configurationProperties object

@secure()
param protectedItems object = {}

@description('Base blob URL (no SAS) containing Configuration.zip, e.g. https://<sa>.blob.core.windows.net/dsc/. The extension downloads <artifactsLocation>Configuration.zip using the VM\'s user-assigned managed identity (Storage Blob Data Reader on the SA).')
param artifactsLocation string

@description('Client ID of the user-assigned managed identity attached to the VM. The DSC extension uses it to OAuth-download Configuration.zip from the storage account (the SA disallows shared-key access).')
param userAssignedIdentityClientId string

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' existing = {
  name: vmName
}

resource dsc 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: vm
  name: 'Microsoft.Powershell.DSC'
  location: location
  properties: {
    publisher: 'Microsoft.Powershell'
    type: 'DSC'
    typeHandlerVersion: '2.83'
    autoUpgradeMinorVersion: true
    settings: {
      wmfVersion: 'latest'
      configuration: {
        url: uri(artifactsLocation, 'Configuration.zip')
        script: 'Configuration.ps1'
        function: last(split(configurationFunction, '\\'))
      }
      configurationArguments: configurationProperties
    }
    protectedSettings: {
      // Use the VM's user-assigned MI to authenticate to blob storage.
      // Requires Storage Blob Data Reader on the SA — granted by modules/sa-role.bicep.
      managedIdentity: {
        clientId: userAssignedIdentityClientId
      }
      configurationArguments: protectedItems
    }
  }
}
