targetScope = 'subscription'

@description('Azure region for the prereq resource groups and resources.')
param location string = deployment().location

@description('Resource group that will hold the DSC artifacts storage account.')
param storageResourceGroupName string = 'rds-artifacts-rg'

@description('Resource group that will hold the TLS-cert Key Vault. Ignored when deployKeyVault = false.')
param keyVaultResourceGroupName string = 'rds-security-rg'

@description('Globally unique storage account name (3-24 chars, lowercase alphanumeric).')
@minLength(3)
@maxLength(24)
param storageAccountName string

@description('Globally unique Key Vault name (3-24 chars). Required when deployKeyVault = true.')
@maxLength(24)
param keyVaultName string = ''

@description('Blob container that will hold Configuration.zip and any other DSC artifacts.')
param artifactsContainerName string = 'dsc'

@description('Admin principals that get full data-plane access on the prereq resources. Always include the CI service principal so the deploy pipeline can upload artifacts and (later) manage certs. Each item: { id: <Entra object ID>, type: User | Group | ServicePrincipal }.')
param adminPrincipals array

@description('Set to false to skip Key Vault (e.g. when enableCertificateBinding = false in the main farm).')
param deployKeyVault bool = true

@description('Enable purge protection on the Key Vault (irreversible; vault cannot be permanently deleted for 90 days). Recommended true for production.')
param keyVaultEnablePurgeProtection bool = true

@description('Resource ID of the subnet where the Private Endpoints for the SA (always) and KV (when deployKeyVault=true) will be placed. Subnet must already exist with privateEndpointNetworkPolicies=Disabled. Example: /subscriptions/<sub>/resourceGroups/rg-j-rdsvnet-01/providers/Microsoft.Network/virtualNetworks/j-rdsvnet-01/subnets/pe')
param peSubnetId string

@description('Resource IDs of all VNets that should resolve the privatelink.* zones for the SA and KV. At minimum include the spoke VNet that owns peSubnetId. Add the hub VNet when uploads / cert management happen from a hub jump box. Each item: full VNet resource ID.')
param dnsZoneVnetLinks array

@description('Reuse a pre-existing privatelink.vaultcore.azure.net zone (e.g. one centrally managed by the platform team) instead of creating a new one in keyVaultResourceGroupName. The PE\'s zone group still writes its A record into the existing zone; we just add any missing VNet links via a cross-RG sub-module. Use when a hub VNet (or any other VNet in dnsZoneVnetLinks) is already linked to the central zone — Azure does not allow a VNet to be linked to two zones with the same name.')
param useExistingKvZone bool = false

@description('Required when useExistingKvZone = true. Full resource ID of the existing privatelink.vaultcore.azure.net zone. Example: /subscriptions/<sub>/resourceGroups/rg-j-dns-01/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net')
param existingKvZoneResourceId string = ''

@description('VNets to link to the existing central KV zone. Subset of dnsZoneVnetLinks — DO NOT include any VNet that is already linked centrally (a VNet can only have one link per zone). Typically just the spoke. Ignored when useExistingKvZone = false.')
param existingKvZoneAdditionalVnetLinks array = []

@description('Tags applied to both the resource groups and the resources inside.')
param tags object = {
  workload: 'RemoteDesktopServices'
  purpose: 'prereqs'
}

resource artifactsRg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: storageResourceGroupName
  location: location
  tags: tags
}

resource securityRg 'Microsoft.Resources/resourceGroups@2024-03-01' = if (deployKeyVault) {
  name: keyVaultResourceGroupName
  location: location
  tags: tags
}

module storage 'modules/storage.bicep' = {
  scope: artifactsRg
  params: {
    storageAccountName: storageAccountName
    artifactsContainerName: artifactsContainerName
    adminPrincipals: adminPrincipals
    location: location
    tags: tags
  }
}

module keyVault 'modules/keyvault.bicep' = if (deployKeyVault) {
  scope: securityRg
  params: {
    keyVaultName: keyVaultName
    adminPrincipals: adminPrincipals
    enablePurgeProtection: keyVaultEnablePurgeProtection
    location: location
    tags: tags
  }
}

// ---------------------------------------------------------------------------
// Private Endpoints + Private DNS zones
//
// Both KV and SA run with publicNetworkAccess=Disabled (enforced by Azure
// Policy on this subscription). Reachability for the farm VMs depends on:
//   1. A Private Endpoint in a subnet that the VMs can route to (the spoke
//      'pe' subnet, peered to the VM subnet 'rds').
//   2. A Private DNS zone (privatelink.blob.core.windows.net for SA,
//      privatelink.vaultcore.azure.net for KV) linked to every VNet whose
//      VMs / users need to resolve the FQDN to the PE IP.
//   3. The custom DNS server in the VNet (the AD DC at 172.16.0.4) MUST
//      have a conditional forwarder for each privatelink.* zone pointing
//      at 168.63.129.16. Without it, the DC resolves to the public CNAME
//      chain and gets 'service not reachable' from the PNA=Disabled
//      endpoint. See README / deployment.md for the one-time DC setup.
// ---------------------------------------------------------------------------

// SA: blob private DNS zone, co-located with the storage account.
module saDnsZone 'modules/private-dns-zone.bicep' = {
  scope: artifactsRg
  name: 'sa-blob-pl-zone'
  params: {
    zoneName: 'privatelink.blob.${environment().suffixes.storage}'
    vnetIdsToLink: dnsZoneVnetLinks
    tags: tags
  }
}

module saPrivateEndpoint 'modules/private-endpoint.bicep' = {
  scope: artifactsRg
  name: 'sa-blob-pe'
  params: {
    peName: '${storageAccountName}-blob-pe'
    targetResourceId: storage.outputs.storageAccountId
    subnetId: peSubnetId
    groupId: 'blob'
    privateDnsZoneId: saDnsZone.outputs.zoneId
    location: location
    tags: tags
  }
}

// KV: vault private DNS zone.
//
// Two modes:
//   useExistingKvZone = false → create the zone in securityRg and link every
//                               VNet in dnsZoneVnetLinks.
//   useExistingKvZone = true  → DO NOT create our own zone. Just add any
//                               missing VNet links to the existing zone
//                               (typically a central one in rg-j-dns-01
//                               that already has the hub linked). The PE's
//                               zone group writes its A record there.
module kvDnsZone 'modules/private-dns-zone.bicep' = if (deployKeyVault && !useExistingKvZone) {
  scope: securityRg
  name: 'kv-vault-pl-zone'
  params: {
    zoneName: 'privatelink.vaultcore.azure.net'
    vnetIdsToLink: dnsZoneVnetLinks
    tags: tags
  }
}

// Cross-RG link sub-module: targets whichever RG owns the existing zone
// (parsed from the resource ID — index 4 of /subscriptions/.../resourceGroups/<rg>/...).
var existingKvZoneRgName = useExistingKvZone && !empty(existingKvZoneResourceId)
  ? split(existingKvZoneResourceId, '/')[4]
  : ''

module kvDnsZoneExistingLinks 'modules/private-dns-zone-link.bicep' = if (deployKeyVault && useExistingKvZone && !empty(existingKvZoneAdditionalVnetLinks)) {
  // resourceGroup() at subscription scope needs the RG name; the RG must
  // already exist (we don't manage it from this template).
  scope: resourceGroup(existingKvZoneRgName)
  name: 'kv-vault-pl-zone-links'
  params: {
    existingZoneResourceId: existingKvZoneResourceId
    vnetIdsToLink: existingKvZoneAdditionalVnetLinks
    tags: tags
  }
}

module kvPrivateEndpoint 'modules/private-endpoint.bicep' = if (deployKeyVault) {
  scope: securityRg
  name: 'kv-vault-pe'
  params: {
    peName: '${keyVaultName}-kv-pe'
    targetResourceId: keyVault!.outputs.keyVaultResourceId
    subnetId: peSubnetId
    groupId: 'vault'
    // Either our own zone or the existing one — exactly one is defined per
    // the conditional above.
    privateDnsZoneId: useExistingKvZone ? existingKvZoneResourceId : kvDnsZone!.outputs.zoneId
    location: location
    tags: tags
  }
}

@description('Storage account name. Use as the value of repo variable ARTIFACTS_STORAGE_ACCOUNT.')
output storageAccountName string = storage.outputs.storageAccountName

@description('Blob container URL. Plug into main.bicepparam → artifactsLocation.')
output artifactsLocation string = storage.outputs.artifactsLocation

output storageResourceGroupName string = artifactsRg.name
output artifactsContainerName string = artifactsContainerName

@description('Key Vault name. Plug into main.bicepparam → keyVaultName. Empty when deployKeyVault = false.')
output keyVaultName string = deployKeyVault ? keyVault!.outputs.keyVaultName : ''
output keyVaultResourceGroupName string = deployKeyVault ? securityRg!.name : ''
output keyVaultUri string = deployKeyVault ? keyVault!.outputs.keyVaultUri : ''
