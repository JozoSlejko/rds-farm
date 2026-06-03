using 'main.bicep'

// Region for the artifacts SA + Key Vault RGs. Tier 0
// (scripts/Initialize-RdsFarm.ps1) overwrites this with your chosen
// -Location before invoking `az deployment group create`.
param location = 'westeurope'

// Resource groups that this template will create (or update if they exist).
param storageResourceGroupName  = 'rds-artifacts-rg'
param keyVaultResourceGroupName = 'rds-security-rg'

// Storage (DSC artifacts) — must be globally unique, 3-24 chars, lowercase alphanumeric.
param storageAccountName     = 'contosordsart01'
param artifactsContainerName = 'dsc'

// Key Vault — must be globally unique, 3-24 chars.
// Set deployKeyVault = false (and leave keyVaultName empty) if your main farm
// runs with enableCertificateBinding = false.
param deployKeyVault                  = true
param keyVaultName                    = 'contoso-rds-kv01'
param keyVaultEnablePurgeProtection   = true   // IRREVERSIBLE once true; set false for short-lived lab vaults

// ---------------------------------------------------------------------------
// Private Endpoint placement
// ---------------------------------------------------------------------------
// Both KV and SA run with publicNetworkAccess=Disabled (enforced by Azure
// Policy on this subscription). The farm VMs reach them via Private
// Endpoints placed in a dedicated 'pe' subnet of the spoke VNet.
//
// Pre-create the subnet ONCE (we don't manage VNets / subnets from here):
//
//   az network vnet subnet create -g <vnetRg> --vnet-name <vnet> -n pe `
//       --address-prefixes 172.16.1.32/28 `
//       --private-endpoint-network-policies Disabled
//
// Then plug its resource ID below.
param peSubnetId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/<spokeRg>/providers/Microsoft.Network/virtualNetworks/<spokeVnet>/subnets/pe'

// Every VNet that needs to resolve the privatelink.* zones for KV and SA.
// At minimum the spoke that owns 'pe'. Add the hub when artifacts are
// uploaded or certificates are managed from a hub jump box.
//
// This list is applied verbatim to the BLOB zone (we create that one
// ourselves and nothing else is linked to it). For the VAULT zone the
// useExistingKvZone block below takes precedence — see its comments.
//
// Remember: the DC at adDnsServerIp also needs conditional forwarders for
// privatelink.blob.<storage suffix> and privatelink.vaultcore.azure.net
// pointing at 168.63.129.16, or VNet DNS resolution will short-circuit to
// the public CNAME and fail (PNA is disabled on the targets).
param dnsZoneVnetLinks = [
  '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/<spokeRg>/providers/Microsoft.Network/virtualNetworks/<spokeVnet>'
  '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/<hubRg>/providers/Microsoft.Network/virtualNetworks/<hubVnet>'
]

// ---------------------------------------------------------------------------
// Existing central KV zone (optional)
// ---------------------------------------------------------------------------
// Azure does NOT allow a VNet to be linked to two privatelink.vaultcore.azure.net
// zones (or any two zones with the same name). If your hub VNet is already
// linked to a centrally-managed `privatelink.vaultcore.azure.net` zone (e.g. in
// rg-j-dns-01), set useExistingKvZone = true and point existingKvZoneResourceId
// at that zone. The template will:
//   * skip creating its own vault zone in keyVaultResourceGroupName
//   * write the KV PE's A record into the existing zone via the PE's zone group
//   * add VNet links for any VNets in existingKvZoneAdditionalVnetLinks
//     (give it the SPOKE only — the hub is already linked centrally)
//
// If you don't have this scenario, leave useExistingKvZone = false and the
// template will create its own zone in keyVaultResourceGroupName.
param useExistingKvZone = false
param existingKvZoneResourceId = ''   // e.g. '/subscriptions/<sub>/resourceGroups/rg-j-dns-01/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net'
param existingKvZoneAdditionalVnetLinks = []   // e.g. just the spoke VNet ID

// Principals that get admin data-plane access (Storage Blob Data Contributor on the SA,
// Key Vault Certificates Officer on the vault). Include:
//   - the CI service principal so the deploy pipeline can upload artifacts
//   - your own user (or your team's group) so you can manage certs / artifacts
param adminPrincipals = [
  // {
  //   id:   '11111111-1111-1111-1111-111111111111'   // your Entra user object ID (az ad signed-in-user show --query id -o tsv)
  //   type: 'User'
  // }
  // {
  //   id:   '22222222-2222-2222-2222-222222222222'   // the CI service principal's object ID (az ad sp show --id <appId> --query id -o tsv)
  //   type: 'ServicePrincipal'
  // }
]
