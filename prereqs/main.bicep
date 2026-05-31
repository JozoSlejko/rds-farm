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
