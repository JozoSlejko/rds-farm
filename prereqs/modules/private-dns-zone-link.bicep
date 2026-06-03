@description('Resource ID of an existing Private DNS zone (in any RG / sub the deployer has rights to). Example: /subscriptions/<sub>/resourceGroups/rg-j-dns-01/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net')
param existingZoneResourceId string

@description('Resource IDs of VNets to link to that zone. Each VNet gets one virtualNetworkLink with autoregistration disabled. Skip any VNet that is already linked centrally (a VNet can only be linked once per zone).')
param vnetIdsToLink array

@description('Tags applied to the link resources.')
param tags object = {}

// Pull the zone name out of the resource ID so we can build the child link
// without requiring an `existing` reference (which would force us to deploy
// this module into the zone's RG and need a separate scope wrapper).
var zoneName = last(split(existingZoneResourceId, '/'))

// `existing` reference into the zone (lives in this module's targetScope —
// see the module invocation in main.bicep for the cross-RG scope wrapping).
resource zone 'Microsoft.Network/privateDnsZones@2024-06-01' existing = {
  name: zoneName
}

resource links 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [for vnetId in vnetIdsToLink: {
  parent: zone
  // Deterministic 13-char hash so the link name is stable per (zone, VNet)
  // and our deploy is idempotent. Matches the pattern in private-dns-zone.bicep.
  name: 'link-${uniqueString(vnetId)}'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnetId
    }
  }
}]

@description('Names of the VNet links created. One per input VNet.')
output linkNames array = [for (vnetId, i) in vnetIdsToLink: links[i].name]
