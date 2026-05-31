# CI/CD with GitHub Actions

[← Back to main README](../README.md)

A ready-to-use workflow is provided at [`.github/workflows/deploy.yml`](../.github/workflows/deploy.yml). It uses **OIDC federated credentials** (no client secrets stored in GitHub) and runs:

| Trigger | Jobs |
| --- | --- |
| Pull request to `main` | `lint` → `package-dsc` → `upload-artifacts` → `what-if` |
| Push to `main` | `lint` → `package-dsc` → `upload-artifacts` → `deploy` |
| Manual (`workflow_dispatch`) | choose `action` (what-if / deploy) **and** `prereqs_action` (use-existing / what-if / deploy-new) |

The pipeline:

1. Compiles `main.bicep`, `main.bicepparam`, `prereqs/main.bicep`, and `prereqs/main.bicepparam` for linting.
2. *(Optional)* Runs `az deployment sub what-if`/`create` against [`prereqs/main.bicep`](../prereqs/main.bicep) when `prereqs_action != use-existing` — provisions a fresh Key Vault + DSC storage account. See [Prerequisite resources](./prereqs.md).
3. Zips `dsc/Configuration.ps1` → `Configuration.zip`.
4. Uploads the zip to your artifacts storage account using **`--auth-mode login`** (no account keys). Uses the storage account from the prereqs job if it just ran, otherwise the `ARTIFACTS_STORAGE_ACCOUNT` repo variable.
5. Generates a **user-delegation SAS** (2-hour expiry) and masks it from logs.
6. Runs `az deployment group what-if` (PRs) or `create` (main).
7. Posts the gateway FQDN and RD Web URL to the GitHub Actions job summary.

## One-time setup

### 1. Create an Entra app + federated credentials

```powershell
# Create the app and service principal
$app = az ad app create --display-name 'gh-rds-farm-deploy' | ConvertFrom-Json
$sp  = az ad sp create --id $app.appId                      | ConvertFrom-Json

# Federated credential for the main branch
az ad app federated-credential create --id $app.appId --parameters '{
  \"name\": \"gh-main\",
  \"issuer\": \"https://token.actions.githubusercontent.com\",
  \"subject\": \"repo:<org>/<repo>:ref:refs/heads/main\",
  \"audiences\": [\"api://AzureADTokenExchange\"]
}'

# Federated credential for PRs (any PR in the repo)
az ad app federated-credential create --id $app.appId --parameters '{
  \"name\": \"gh-pr\",
  \"issuer\": \"https://token.actions.githubusercontent.com\",
  \"subject\": \"repo:<org>/<repo>:pull_request\",
  \"audiences\": [\"api://AzureADTokenExchange\"]
}'

# Federated credential for the two GitHub environments used in the workflow
az ad app federated-credential create --id $app.appId --parameters '{
  \"name\": \"gh-env-production\",
  \"issuer\": \"https://token.actions.githubusercontent.com\",
  \"subject\": \"repo:<org>/<repo>:environment:production\",
  \"audiences\": [\"api://AzureADTokenExchange\"]
}'
az ad app federated-credential create --id $app.appId --parameters '{
  \"name\": \"gh-env-preview\",
  \"issuer\": \"https://token.actions.githubusercontent.com\",
  \"subject\": \"repo:<org>/<repo>:environment:preview\",
  \"audiences\": [\"api://AzureADTokenExchange\"]
}'
```

### 2. Grant Azure RBAC to the service principal

The principal needs to:

| Scope | Role | Why |
| --- | --- | --- |
| Target resource group (`rds-farm-rg`) | `Contributor` | Deploy VMs, LB, NSG, etc. |
| Existing VNet RG | `Network Contributor` | Read existing VNet/subnet, attach NSG. |
| Existing Key Vault (if cert binding) | `Key Vault Reader` + `Role Based Access Control Administrator` | The Bicep `kv-role.bicep` creates a role assignment, which needs `Microsoft.Authorization/roleAssignments/write`. |
| Artifacts storage account | `Storage Blob Data Contributor` | Upload `Configuration.zip` and mint a user-delegation SAS. |
| Subscription (only if you'll run `prereqs_action: deploy-new` from CI) | `Contributor` + `Role Based Access Control Administrator` | The prereqs template is subscription-scope; it creates the two prereq RGs and assigns admin roles on the new SA/KV. See [Prerequisite resources → RBAC the deploying principal needs](./prereqs.md#rbac-the-deploying-principal-needs). |

```powershell
$subId = az account show --query id -o tsv
$rgRds = '/subscriptions/' + $subId + '/resourceGroups/rds-farm-rg'
$rgNet = '/subscriptions/' + $subId + '/resourceGroups/network-rg'
$rgArt = '/subscriptions/' + $subId + '/resourceGroups/rds-artifacts-rg'

az role assignment create --assignee $sp.id --role 'Contributor'                         --scope $rgRds
az role assignment create --assignee $sp.id --role 'Network Contributor'                 --scope $rgNet
az role assignment create --assignee $sp.id --role 'Storage Blob Data Contributor'       --scope $rgArt
# Only if enableCertificateBinding = true
az role assignment create --assignee $sp.id --role 'Role Based Access Control Administrator' --scope '/subscriptions/<sub>/resourceGroups/security-rg/providers/Microsoft.KeyVault/vaults/contoso-rds-kv'
```

### 3. Configure GitHub secrets, variables, environments

In **Repo → Settings → Secrets and variables → Actions**:

#### Repository secrets

| Name | Value |
| --- | --- |
| `AZURE_CLIENT_ID` | `$app.appId` from step 1 |
| `AZURE_TENANT_ID` | Your Entra tenant ID |
| `AZURE_SUBSCRIPTION_ID` | Target subscription ID |
| `DOMAIN_JOIN_PASSWORD` | Service-account password used during VM domain join |
| `LOCAL_ADMIN_PASSWORD` | Local administrator password for the VMs |

#### Repository variables

| Name | Value |
| --- | --- |
| `ARTIFACTS_STORAGE_ACCOUNT` | Name of the storage account that holds `Configuration.zip` |

#### Environments

In **Repo → Settings → Environments → New environment**:

Create two: `preview` and `production`. On `production` add a required-reviewers protection rule so deploys only run after approval.

### 4. Set the artifacts storage account name in `env`

The workflow reads `${{ vars.ARTIFACTS_STORAGE_ACCOUNT }}`. Make sure the container `dsc` exists:

```powershell
az storage container create \
  --account-name $env:ARTIFACTS_STORAGE_ACCOUNT \
  --name dsc \
  --auth-mode login
```

### 5. Push and run

```powershell
git add .
git commit -m "ci: add GitHub Actions deployment for RDS farm"
git push origin main
```

Open a PR to see the `what-if` job comment its plan; merge to trigger the `deploy` job (gated by the `production` environment approval).

## Notes on the SAS approach

- The workflow uses `az storage blob generate-sas --auth-mode login --as-user`, which produces a **user-delegation SAS** signed with the service principal's Entra ID token. No storage account keys are ever required.
- SAS lifetime is 2 hours — enough for the DSC extension to download `Configuration.zip` during provisioning, but short enough that a leaked log line won't be exploitable for long. The SAS is also masked with `::add-mask::`.
- Bicep parameters set via `--parameters key=value` override values from `main.bicepparam`. The pipeline uses this to inject `artifactsLocation` so the file can stay environment-neutral in source control.
