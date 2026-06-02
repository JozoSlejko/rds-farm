@description('Name of the existing storage account hosting the DSC artifacts.')
param storageAccountName string

@description('Principal ID of the user-assigned managed identity that needs read access to the blob.')
param principalId string

// Built-in role: Storage Blob Data Reader
var blobDataReaderRoleId = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'

resource sa 'Microsoft.Storage/storageAccounts@2024-01-01' existing = {
  name: storageAccountName
}

resource roleAssign 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: sa
  name: guid(sa.id, principalId, blobDataReaderRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', blobDataReaderRoleId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
