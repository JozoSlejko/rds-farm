# Prerequisite resources (Key Vault + DSC storage account)

[← Back to main README](../README.md)

> [!NOTE]
> **Where this fits in the tier model.** Running `prereqs/` is **Tier 0** (one-time provisioning) and is always done from a laptop — the CI pipeline never deploys this template:
>
> - **Via the orchestrator (recommended):** [`scripts/Initialize-RdsFarm.ps1`](../scripts/Initialize-RdsFarm.ps1) deploys this template for you with `adminPrincipals` pre-populated. You don't edit `prereqs/tier0.bicepparam` at all.
> - **From your laptop directly:** [Option 2](#option-2--manual-az-deployment-sub-create) below — useful for debugging or when you can't use the orchestrator.
>
> After this is done once, every subsequent farm deploy is **Tier 1** (pipeline or laptop via [`scripts/Invoke-ManualDeploy.ps1`](../scripts/Invoke-ManualDeploy.ps1)) and reads the resources it just created. See [README → Deployment guide](../README.md#deployment-guide).
>
> **Why isn't this in CI?** Sub-scope deployments need broader RBAC (sub-scope `Contributor` + `RBAC Administrator`) than a CI principal should normally hold. Keeping prereqs as a laptop-only operation lets the CI service principal stay narrowly scoped.

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
> **`enablePurgeProtection = true` is irreversible.** Once on, you cannot turn it off, and a deleted vault cannot be permanently purged for 90 days. Set `keyVaultEnablePurgeProtection = false` in [`prereqs/tier0.bicepparam`](../prereqs/tier0.bicepparam) for short-lived lab vaults you want to be able to recreate immediately.

## How to deploy

### Option 1 — via the orchestrator (recommended)

[`scripts/Initialize-RdsFarm.ps1`](../scripts/Initialize-RdsFarm.ps1) wraps the `az deployment sub create` call shown below, fills in `adminPrincipals` from `az ad signed-in-user show` + the SP it just created, and writes the resulting SA name to the `ARTIFACTS_STORAGE_ACCOUNT` repo variable via `gh variable set`. Use this whenever you can.

After it finishes, the pipeline reads the storage account from the repo variable and the Key Vault from `main.bicepparam` — no other wiring required.

### Option 2 — manual `az deployment sub create`

```powershell
cd C:\Users\jozoslejko\OneDrive\Dev\rds-farm\prereqs

# Fill in your object IDs in tier0.bicepparam first (see below).
az deployment sub create `
  --name "prereqs-$(Get-Date -Format yyyyMMdd-HHmmss)" `
  --location westeurope `
  --template-file tier0.bicep `
  --parameters tier0.bicepparam
```

## Filling out `tier0.bicepparam`

Open [`prereqs/tier0.bicepparam`](../prereqs/tier0.bicepparam) and set:

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
> The CI pipeline auto-injects the CI service principal's object ID at runtime (`az ad sp show --id ${{ secrets.AZURE_CLIENT_ID }}`) so you don't have to hard-code it in source control. Hard-coding your own user/group IDs in `tier0.bicepparam` is still useful for manual `az deployment sub create` runs.

## RBAC the deploying principal needs

To run `az deployment sub create` against this template, the deployer (you or the CI service principal) needs:

| Role | Scope | Why |
| --- | --- | --- |
| `Contributor` | Subscription **or** each pre-created resource group | Create the resource groups and the resources inside them. |
| `Role Based Access Control Administrator` | Subscription, or scoped to the two resource groups | Bicep modules create role assignments on the SA and KV — this requires `Microsoft.Authorization/roleAssignments/write`. |
| `Application.Read.All` *(Microsoft Graph)* | Tenant | Only required for the CI run, so the `az ad sp show` step can resolve the service principal object ID. Already implicit if the SP is a member of itself; otherwise grant `User.Read` + `Application.Read.All`. |

You can pre-create the two resource groups out of band and grant the deployer only `Contributor` + `Role Based Access Control Administrator` on those — Bicep `resource ... = { name: <existingRgName> }` is idempotent at subscription scope and will leave existing RGs alone.

## After the prereqs deploy

1. **Update the repo variable.** Set `ARTIFACTS_STORAGE_ACCOUNT` to the newly-created account name so subsequent CI runs default to it:

   ```powershell
   gh variable set ARTIFACTS_STORAGE_ACCOUNT --repo '<org>/<repo>' --body '<new-sa-name>'
   ```

2. **Create or import the TLS cert.** Follow [Manual deploy → Step 3](./manual-deploy.md#3-create-the-tls-certificate-in-key-vault-only-if-tier-0-did-not) — Step 3a (RBAC mode + self-grant Certificates Officer) is already handled by this template.
3. **Update `main.bicepparam`.** Set `keyVaultName`, `keyVaultResourceGroup`, and `keyVaultCertSecretUri` (the value the orchestrator prints in its summary).
4. **Run the main farm deploy.** Either trigger the workflow with `action: deploy`, or `az deployment group create` manually per [Manual deploy (escape hatch)](./manual-deploy.md).
