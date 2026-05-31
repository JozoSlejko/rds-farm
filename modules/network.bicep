@description('Existing VNet name.')
param vnetName string

@description('Existing RDS subnet name.')
param rdsSubnetName string

@description('CIDRs allowed to reach RD Gateway from the internet.')
param allowedClientSourceAddressPrefixes array

param namePrefix string
param location string
param tags object

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: vnetName
}

resource rdsSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: vnet
  name: rdsSubnetName
}

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: '${namePrefix}-rds-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-HTTPS-from-AllowedClients'
        properties: {
          priority: 100
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourceAddressPrefixes: allowedClientSourceAddressPrefixes
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'Allow-UDP3391-from-AllowedClients'
        properties: {
          priority: 110
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Udp'
          sourceAddressPrefixes: allowedClientSourceAddressPrefixes
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3391'
        }
      }
      {
        name: 'Allow-AzureLoadBalancer-Probes'
        properties: {
          priority: 200
          access: 'Allow'
          direction: 'Inbound'
          protocol: '*'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'Deny-Internet-Inbound'
        properties: {
          priority: 4096
          access: 'Deny'
          direction: 'Inbound'
          protocol: '*'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

output rdsSubnetId string = rdsSubnet.id
output nsgId string = nsg.id
