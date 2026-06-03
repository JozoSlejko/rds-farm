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
