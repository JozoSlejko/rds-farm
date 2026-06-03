@description('Name of the Private Endpoint resource.')
param peName string

@description('Resource ID of the target resource (storage account, key vault, ...).')
param targetResourceId string

@description('Resource ID of the subnet where the PE NIC will be created. Subnet must already exist and have privateEndpointNetworkPolicies set to Disabled.')
param subnetId string

@description('Sub-resource group ID exposed by the target. Common values: vault (Key Vault), blob | file | table | queue | dfs | web (Storage Account), sqlServer (Azure SQL), sites (App Service).')
param groupId string

@description('Resource ID of the Private DNS zone where the PE should auto-register its A record.')
param privateDnsZoneId string

param location string
param tags object

resource pe 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: peName
  location: location
  tags: tags
  properties: {
    subnet: {
      id: subnetId
    }
    privateLinkServiceConnections: [
      {
        // Naming this 'default' instead of '${peName}-conn' would also work,
        // but a name derived from the PE keeps it greppable when you have
        // many PEs in one subnet.
        name: '${peName}-conn'
        properties: {
          privateLinkServiceId: targetResourceId
          groupIds: [
            groupId
          ]
        }
      }
    ]
  }
}

// PrivateDnsZoneGroup writes the A record (and PTR) for the PE's NIC into
// the supplied Private DNS zone. Without this, the zone link exists but the
// zone stays empty until you manually add records.
resource zoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: pe
  // Name must be 'default' for many ARM tooling integrations to find it.
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: groupId
        properties: {
          privateDnsZoneId: privateDnsZoneId
        }
      }
    ]
  }
}

output privateEndpointId string = pe.id
output privateEndpointName string = pe.name
