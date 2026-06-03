@description('Private DNS zone name (e.g. privatelink.blob.core.windows.net).')
param zoneName string

@description('Resource IDs of all VNets that should resolve this zone. Each VNet gets one virtualNetworkLink with autoregistration off (we never want the PE\'s NIC to grab an A record automatically — DNS zone groups on the PE handle that, and they own the lifecycle of the A record).')
param vnetIdsToLink array

@description('Tags applied to the zone and the VNet links.')
param tags object

resource zone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: zoneName
  // Private DNS zones are always global; the location field literally
  // accepts only 'global'. The data path resolution still happens
  // regionally via 168.63.129.16.
  location: 'global'
  tags: tags
}

resource links 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [for vnetId in vnetIdsToLink: {
  parent: zone
  // uniqueString(vnetId) gives a deterministic 13-char hash so the name is
  // stable across redeploys and unique per VNet.
  name: 'link-${uniqueString(vnetId)}'
  location: 'global'
  tags: tags
  properties: {
    // false: VMs in the VNet do NOT auto-register their A records here.
    // We only want the PE's zone group to write records.
    registrationEnabled: false
    virtualNetwork: {
      id: vnetId
    }
  }
}]

output zoneId string = zone.id
output zoneName string = zone.name
