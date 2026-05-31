param vmName string
param location string

@description('e.g. Configuration.ps1\\Gateway')
param configurationFunction string

param configurationProperties object

@secure()
param protectedItems object = {}

param artifactsLocation string

@secure()
param artifactsLocationSasToken string = ''

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
        url: uri(artifactsLocation, 'Configuration.zip${artifactsLocationSasToken}')
        script: 'Configuration.ps1'
        function: last(split(configurationFunction, '\\'))
      }
      configurationArguments: configurationProperties
    }
    protectedSettings: {
      configurationUrlSasToken: artifactsLocationSasToken
      configurationArguments: protectedItems
    }
  }
}
