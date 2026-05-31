using 'main.bicep'

param existingVnetName = 'corp-vnet'
param existingVnetResourceGroup = 'network-rg'
param existingRdsSubnetName = 'snet-rds'
param adDomainName = 'contoso.local'
param adDnsServerIp = '10.10.0.4'
param domainJoinUserName = 'svc-domainjoin'
param domainJoinPassword = readEnvironmentVariable('DOMAIN_JOIN_PASSWORD')
param localAdminUserName = 'rdsadmin'
param localAdminPassword = readEnvironmentVariable('LOCAL_ADMIN_PASSWORD')
param sessionHostCount = 2
param vmSize = 'Standard_D4s_v5'
param windowsSku = '2022-datacenter-azure-edition'
param allowedClientSourceAddressPrefixes = [
  '203.0.113.0/24'
  '198.51.100.10/32'
]
param gatewayDnsLabelPrefix = 'contoso-rds'
param deployBastion = true

// DSC artifacts
param artifactsLocation = 'https://contosoartifactssa.blob.core.windows.net/dsc/'
param artifactsLocationSasToken = readEnvironmentVariable('ARTIFACTS_SAS', '')
param sessionHostNamingPrefix = 'rds-sh-'
param collectionName = 'DesktopCollection'

// AD group whose members can sign in via RD Web + RD Gateway.
// Use 'Domain Users' for a quick test, or a dedicated group like 'RDS-Users'.
param rdsAccessGroup = 'Domain Users'

// Certificate binding (Key Vault → RDS roles)
param enableCertificateBinding = true
param keyVaultName = 'contoso-rds-kv'
param keyVaultResourceGroup = 'security-rg'
param keyVaultCertSecretUri = 'https://contoso-rds-kv.vault.azure.net/secrets/rds-tls'

// Public hostname clients will type. MUST match the cert Subject/SAN.
// - Leave empty to use the Azure-managed LB FQDN — only works with a self-signed
//   cert because public CAs won't issue for `cloudapp.azure.com` (you don't own it).
// - For production: set to a vanity hostname you own, and create a CNAME from it
//   to `gatewayFqdn` (the LB FQDN output) after the first deploy.
param publicGatewayFqdn = 'rds.contoso.com'
param certificateSubject = 'CN=rds.contoso.com'
