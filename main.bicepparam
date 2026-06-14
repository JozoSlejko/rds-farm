using 'main.bicep'

// =============================================================================
//  TEMPLATE VALUES BELOW - DO NOT PUSH UNEDITED
//
//  The values below (existingVnetName, adDomainName, publicGatewayFqdn, etc.)
//  are placeholders. Tier 0 (`scripts/Initialize-RdsFarm.ps1`) overwrites them
//  with your real values, then `git push` runs the pipeline. If you push this
//  file unedited, the pipeline's `pre-deploy-checks` job will reject it.
//
//  See:
//    - README -> Deployment guide       (start here if new)
//    - docs/fqdn-and-cert.md          (hostname + cert decisions Tier 0 acts on)
// =============================================================================

param existingVnetName = 'j-rdsvnet-01'
param existingVnetResourceGroup = 'rg-j-rdsvnet-01'
param existingRdsSubnetName = 'rds'
// Governance NSG already attached to the RDS subnet (landing-zone / Azure Policy
// managed). The farm writes its client allow-list (TCP 443 / UDP 3391) as named
// rules here instead of attaching its own NIC NSG. Tier 0 discovers and sets it.
// Leave empty to skip writing rules.
param subnetNsgName = 'j-rdsvnet-01-rds-nsg-italynorth'
param adDomainName = 'slejco.com'
param adDnsServerIp = '172.16.0.4'
param domainJoinUserName = 'svc-domainjoin'
param domainJoinPassword = readEnvironmentVariable('DOMAIN_JOIN_PASSWORD')

// Optional OU to drop the VM AD computer objects into, e.g.
//   'OU=RDS,OU=Servers,DC=contoso,DC=local'
// Leave empty to use the default Computers container. The domain-join service
// account must have "Create Computer Objects" delegated on the target OU.
param domainJoinOuPath = 'OU=RDS,DC=slejco,DC=com'

param localAdminUserName = 'rdsadmin'
param localAdminPassword = readEnvironmentVariable('LOCAL_ADMIN_PASSWORD')
param sessionHostCount = 2
param vmSize = 'Standard_D4s_v5'
param windowsSku = '2022-datacenter-azure-edition'
param allowedClientSourceAddressPrefixes = [
  '188.129.82.205'
]
param gatewayDnsLabelPrefix = 'rds-j-slejco'
param deployBastion = true

// DSC artifacts
// The VMs' user-assigned managed identity is granted Storage Blob Data Reader
// on this account so the DSC extension can OAuth-download Configuration.zip
// (the SA has allowSharedKeyAccess=false; SAS is blocked by tenant policy).
param artifactsLocation = 'https://rdsjslejcosa01.blob.core.windows.net/dsc/'
param artifactsStorageAccountName = 'rdsjslejcosa01'
param artifactsStorageAccountResourceGroup = 'rds-artifacts-rg'
param sessionHostNamingPrefix = 'rds-sh-'
param collectionName = 'DesktopCollection'

// AD group whose members can sign in via RD Web + RD Gateway.
// Use 'Domain Users' for a quick test, or a dedicated group like 'RDS-Users'.
param rdsAccessGroup = 'Domain Users'

// Certificate binding (Key Vault → RDS roles)
param enableCertificateBinding = true
param keyVaultName = 'rdsjslejcokv01'
param keyVaultResourceGroup = 'rds-security-rg'
param keyVaultCertSecretUri = 'https://rdsjslejcokv01.vault.azure.net/secrets/rds-tls'

// Public hostname clients will type. MUST match the cert Subject/SAN.
// - Leave empty to use the Azure-managed LB FQDN — only works with a self-signed
//   cert because public CAs won't issue for `cloudapp.azure.com` (you don't own it).
// - For production: set to a vanity hostname you own, and create a CNAME from it
//   to `gatewayFqdn` (the LB FQDN output) after the first deploy.
// Lab: matches the Azure LB FQDN and the self-signed cert Subject/SAN below.
param publicGatewayFqdn = 'rds-j-slejco.italynorth.cloudapp.azure.com'
param certificateSubject = 'CN=rds-j-slejco.italynorth.cloudapp.azure.com'
