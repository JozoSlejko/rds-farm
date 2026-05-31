@description('Globally unique Key Vault name (3-24 chars).')
@minLength(3)
@maxLength(24)
param keyVaultName string

@description('Admin principals that get Key Vault Certificates Officer on the vault. Each item must be { id: <Entra object ID>, type: User | Group | ServicePrincipal }.')
param adminPrincipals array

@description('Enable purge protection (90-day mandatory soft-delete window, irreversible). Recommended true for production; set false for short-lived lab vaults.')
param enablePurgeProtection bool = true

@description('Soft-delete retention in days (7-90). Cannot be reduced once the vault is created.')
@minValue(7)
@maxValue(90)
param softDeleteRetentionInDays int = 90

param location string
param tags object

// Built-in role: Key Vault Certificates Officer
var certsOfficerRoleId = 'a4417e6f-fecd-4de8-b567-7b0420556985'

resource kv 'Microsoft.KeyVault/vaults@2024-04-01-preview' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true            // required by the main farm template's kv-role.bicep
    enableSoftDelete: true
    softDeleteRetentionInDays: softDeleteRetentionInDays
    enablePurgeProtection: enablePurgeProtection ? true : null     // 'false' isn't accepted; must be omitted to keep disabled
    enabledForDeployment: false
    enabledForDiskEncryption: false
    enabledForTemplateDeployment: false
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

resource adminRoleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for p in adminPrincipals: {
  scope: kv
  name: guid(kv.id, p.id, certsOfficerRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', certsOfficerRoleId)
    principalId: p.id
    principalType: p.type
  }
}]

output keyVaultName string = kv.name
output keyVaultUri string = kv.properties.vaultUri
output keyVaultResourceId string = kv.id
