param namePrefix string
param location string
param keyVaultName string
param keyVaultResourceGroup string
param tags object

resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${namePrefix}-cert-uami'
  location: location
  tags: tags
}

module kvRole 'kv-role.bicep' = {
  scope: resourceGroup(keyVaultResourceGroup)
  params: {
    keyVaultName: keyVaultName
    principalId: uami.properties.principalId
  }
}

output identityId string = uami.id
output identityClientId string = uami.properties.clientId
output identityPrincipalId string = uami.properties.principalId
