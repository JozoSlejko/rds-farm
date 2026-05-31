@description('Globally unique storage account name (3-24 chars, lowercase alphanumeric).')
@minLength(3)
@maxLength(24)
param storageAccountName string

@description('Blob container that will hold Configuration.zip and any other DSC artifacts.')
param artifactsContainerName string = 'dsc'

@description('Admin principals that get Storage Blob Data Contributor on the account. Each item must be { id: <Entra object ID>, type: User | Group | ServicePrincipal }.')
param adminPrincipals array

param location string
param tags object

// Built-in role: Storage Blob Data Contributor
var blobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

resource sa 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false              // pipeline uses --auth-mode login; no shared keys ever issued
    defaultToOAuthAuthentication: true
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2024-01-01' = {
  parent: sa
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 7
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

resource artifactsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = {
  parent: blobService
  name: artifactsContainerName
  properties: {
    publicAccess: 'None'
  }
}

resource adminRoleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for p in adminPrincipals: {
  scope: sa
  name: guid(sa.id, p.id, blobDataContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', blobDataContributorRoleId)
    principalId: p.id
    principalType: p.type
  }
}]

output storageAccountName string = sa.name
output storageAccountId string = sa.id
output artifactsLocation string = '${sa.properties.primaryEndpoints.blob}${artifactsContainerName}/'
