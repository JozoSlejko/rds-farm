param namePrefix string
param location string
param tags object

@description('Name of the artifacts storage account. The UAMI is granted Storage Blob Data Reader on it so the DSC extension can pull Configuration.zip with managed-identity auth (no SAS).')
param artifactsStorageAccountName string

@description('Resource group of the artifacts storage account.')
param artifactsStorageAccountResourceGroup string

@description('When true, also grant the UAMI Key Vault Secrets User on the cert vault (so the Key Vault VM extension can pull the cert).')
param enableKeyVaultRole bool = false

@description('Required when enableKeyVaultRole = true.')
param keyVaultName string = ''

@description('Required when enableKeyVaultRole = true.')
param keyVaultResourceGroup string = ''

resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${namePrefix}-vm-uami'
  location: location
  tags: tags
}

// Always: Storage Blob Data Reader on the artifacts SA, so the DSC extension's
// managedIdentity setting can OAuth-download Configuration.zip. Required when
// the SA has allowSharedKeyAccess=false (which our prereqs template enforces).
module saRole 'sa-role.bicep' = {
  scope: resourceGroup(artifactsStorageAccountResourceGroup)
  params: {
    storageAccountName: artifactsStorageAccountName
    principalId: uami.properties.principalId
  }
}

// Conditional: Key Vault Secrets User on the cert vault.
module kvRole 'kv-role.bicep' = if (enableKeyVaultRole) {
  scope: resourceGroup(keyVaultResourceGroup)
  params: {
    keyVaultName: keyVaultName
    principalId: uami.properties.principalId
  }
}

output identityId string = uami.id
output identityClientId string = uami.properties.clientId
output identityPrincipalId string = uami.properties.principalId
