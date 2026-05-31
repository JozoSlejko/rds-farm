# Prerequisite resources (Key Vault + DSC storage account)

[← Back to main README](../README.md)

This guide describes the optional **`prereqs/`** Bicep template that provisions the two Azure resources the main RDS farm needs but doesn't create itself:

1. A **storage account** (with a `dsc` blob container) for the `Configuration.zip` artifact.
2. A **Key Vault** (RBAC mode, soft-delete + purge protection) for the TLS certificate bound to the four RDS roles.

It also creates the two resource groups that hold them and grants `Storage Blob Data Contributor` / `Key Vault Certificates Officer` to the principals you list, so the CI service principal can immediately upload artifacts and you can create the cert.

## When to use it

| Scenario | Use `prereqs/` template? |
| --- | --- |
| Fresh subscription, no Key Vault or artifacts storage account yet | **Yes** |
| Your security team manages Key Vaults centrally and you have an existing vault | **No** — set the existing vault name in [`main.bicepparam`](../main.bicepparam) |
| You already have a storage account holding other deployment artifacts | **No** — reuse it; just add the `dsc` container if missing |
| You want to deploy the farm without cert binding (`enableCertificateBinding = false`) | **Yes** with `deployKeyVault = false` — gives you only the storage account |

## What it deploys

| Resource | Defaults | Hardening |
| --- | --- | --- |
| `rds-artifacts-rg` resource group | name configurable | Tags `workload=RemoteDesktopServices`, `purpose=prereqs` |
| Storage account (`StorageV2`, `Standard_LRS`) | `accessTier=Hot`, blob container `dsc` | `allowSharedKeyAccess=false` (Entra-only), `allowBlobPublicAccess=false`, `minimumTlsVersion=TLS1_2`, `defaultToOAuthAuthentication=true`, 7-day blob soft delete |
| `rds-security-rg` resource group (optional) | created only when `deployKeyVault=true` | Same tags |
| Key Vault (`standard` SKU) | `enableRbacAuthorization=true`, `enableSoftDelete=true`, 90-day retention | `enablePurgeProtection=true` (configurable), public network enabled with `bypass=AzureServices` |
| Role assignments | `Storage Blob Data Contributor` on the SA + `Key Vault Certificates Officer` on the vault for each item in `adminPrincipals` | Each entry must declare its principal type to avoid Graph-propagation flakiness |

> [!WARNING]
> **`enablePurgeProtection = true` is irreversible.** Once on, you cannot turn it off, and a deleted vault cannot be permanently purged for 90 days. Set `keyVaultEnablePurgeProtection = false` in [`prereqs/main.bicepparam`](../prereqs/main.bicepparam) for short-lived lab vaults you want to be able to recreate immediately.

## How to deploy

### Option 1 — via the GitHub Actions pipeline (recommended)

The workflow exposes a `prereqs_action` choice:

- **`use-existing`** *(default)* — skip the prereqs job; the pipeline uses the existing `vars.ARTIFACTS_STORAGE_ACCOUNT` repo variable.
- **`what-if`** — run `az deployment sub what-if` against [`prereqs/main.bicep`](../prereqs/main.bicep) and stop (don't run the rest of the pipeline).
- **`deploy-new`** — run `az deployment sub create`, then carry the new storage account name forward into `upload-artifacts` automatically.

In **Actions → Deploy RDS Farm → Run workflow**:

| Combo | Result |
| --- | --- |
| `prereqs_action: deploy-new`, `action: what-if` | Create prereqs, then what-if the main farm (use this for first-run bootstrap) |
| `prereqs_action: deploy-new`, `action: deploy` | One-shot bootstrap: create prereqs and the farm in a single run |
| `prereqs_action: use-existing`, `action: deploy` | Normal recurring deploy (no prereq changes) |
| `prereqs_action: what-if`, any `action` | Validate the prereqs template only; downstream jobs are skipped |

After a successful `deploy-new` run, the job summary prints the new storage account name. **Update repo variable `ARTIFACTS_STORAGE_ACCOUNT`** so the default (`use-existing`) flow picks it up on the next push.

### Option 2 — manual `az deployment sub create`

```powershell
cd C:\Users\jozoslejko\OneDrive\Dev\rds-farm\prereqs

# Fill in your object IDs in main.bicepparam first (see below).
az deployment sub create `
  --name "prereqs-$(Get-Date -Format yyyyMMdd-HHmmss)" `
  --location westeurope `
  --template-file main.bicep `
  --parameters main.bicepparam
```

## Filling out `main.bicepparam`

Open [`prereqs/main.bicepparam`](../prereqs/main.bicepparam) and set:

- `storageAccountName` — globally unique, 3–24 lowercase alphanumeric chars.
- `keyVaultName` — globally unique, 3–24 chars. Skip if `deployKeyVault = false`.
- `adminPrincipals` — list of Entra principals that get admin data-plane access. **Always include at least your CI service principal** so the pipeline can upload artifacts.

To get the object IDs:

```powershell
# Your own user
az ad signed-in-user show --query id -o tsv

# A group
az ad group show -g 'RDS-Admins' --query id -o tsv

# The CI service principal (using its appId from .github/workflows config)
az ad sp show --id <appId-from-gh-secret-AZURE_CLIENT_ID> --query id -o tsv
```

> [!NOTE]
> The CI pipeline auto-injects the CI service principal's object ID at runtime (`az ad sp show --id ${{ secrets.AZURE_CLIENT_ID }}`) so you don't have to hard-code it in source control. Hard-coding your own user/group IDs in `main.bicepparam` is still useful for manual `az deployment sub create` runs.

## RBAC the deploying principal needs

To run `az deployment sub create` against this template, the deployer (you or the CI service principal) needs:

| Role | Scope | Why |
| --- | --- | --- |
| `Contributor` | Subscription **or** each pre-created resource group | Create the resource groups and the resources inside them. |
| `Role Based Access Control Administrator` | Subscription, or scoped to the two resource groups | Bicep modules create role assignments on the SA and KV — this requires `Microsoft.Authorization/roleAssignments/write`. |
| `Application.Read.All` *(Microsoft Graph)* | Tenant | Only required for the CI run, so the `az ad sp show` step can resolve the service principal object ID. Already implicit if the SP is a member of itself; otherwise grant `User.Read` + `Application.Read.All`. |

You can pre-create the two resource groups out of band and grant the deployer only `Contributor` + `Role Based Access Control Administrator` on those — Bicep `resource ... = { name: <existingRgName> }` is idempotent at subscription scope and will leave existing RGs alone.

## After the prereqs deploy

1. **Update the repo variable.** Set `ARTIFACTS_STORAGE_ACCOUNT` to the newly-created account name so subsequent CI runs default to it.
2. **Create or import the TLS cert.** Follow [Key Vault prep → Step 2](./key-vault-cert.md#step-2-create-the-certificate) — Step 1 (RBAC mode + self-grant Certificates Officer) is already handled by this template.
3. **Update `main.bicepparam`.** Set `keyVaultName`, `keyVaultResourceGroup`, and `keyVaultCertSecretUri` (the value the prereqs job prints in its summary).
4. **Run the main farm deploy.** Either trigger the workflow with `prereqs_action: use-existing, action: deploy`, or `az deployment group create` manually per [Deployment](./deployment.md).
