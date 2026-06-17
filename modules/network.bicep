@description('Existing VNet name.')
param vnetName string

@description('Existing RDS subnet name.')
param rdsSubnetName string

@description('CIDRs allowed to reach RD Gateway from the internet.')
param allowedClientSourceAddressPrefixes array

@description('Name of the governance NSG already associated with the RDS subnet (landing-zone / Azure Policy managed), co-located in this module\'s resource group. The farm writes its client allow-list as named rules on this NSG instead of attaching its own NIC NSG. Leave empty to skip writing rules (the farm then applies no inbound allow-list of its own).')
param subnetNsgName string = ''

@description('Write the internet-facing client allow-list (TCP 443 / UDP 3391) on the subnet NSG. Set false when publishing through Entra application proxy - the connector dials outbound, so no internet inbound rules are needed.')
param writeInternetInboundRules bool = true

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: vnetName
}

resource rdsSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: vnet
  name: rdsSubnetName
}

// The RDS subnet is governed by a landing-zone NSG (attached by Azure Policy /
// platform automation). The farm deliberately does NOT attach its own NIC-level
// NSG: a NIC NSG can only further restrict what the subnet NSG already allows,
// so a second flat NSG would be redundant. Instead the farm writes its client
// allow-list as two named rules on the subnet's governance NSG. Only these two
// named rules are managed here; all other governance rules are left untouched.
//
// The NSG name comes in as a parameter (Bicep can't read the subnet's NSG at
// deployment start) - Tier 0 discovers it from the live subnet and writes it to
// the bicepparam. When empty, rule creation is skipped and the farm applies no
// inbound allow-list of its own.
var writeRules = !empty(subnetNsgName) && writeInternetInboundRules

resource subnetNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' existing = if (writeRules) {
  name: subnetNsgName
}

resource allowHttps 'Microsoft.Network/networkSecurityGroups/securityRules@2024-05-01' = if (writeRules) {
  parent: subnetNsg
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

resource allowUdp3391 'Microsoft.Network/networkSecurityGroups/securityRules@2024-05-01' = if (writeRules) {
  parent: subnetNsg
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

output rdsSubnetId string = rdsSubnet.id
