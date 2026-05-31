param namePrefix string
param location string
param vnetName string
param vnetResourceGroup string
param bastionSubnetName string
param tags object

resource bastionVnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  scope: resourceGroup(vnetResourceGroup)
  name: vnetName
}

resource bastionSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: bastionVnet
  name: bastionSubnetName
}

resource bastionPip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: '${namePrefix}-bastion-pip'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource bastion 'Microsoft.Network/bastionHosts@2024-05-01' = {
  name: '${namePrefix}-bastion'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    ipConfigurations: [
      {
        name: 'bastionIpConfig'
        properties: {
          subnet: {
            id: bastionSubnet.id
          }
          publicIPAddress: {
            id: bastionPip.id
          }
        }
      }
    ]
  }
}

output bastionName string = bastion.name
