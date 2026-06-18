# CI/CD with GitHub Actions

[← Back to main README](../README.md)

> [!WARNING]
> **This pipeline can't deploy today.** The artifacts storage account and Key Vault are
> private-endpoint-only (public network access disabled). A GitHub-hosted runner sits
> outside the VNet, so `pre-deploy-checks`, `deploy`, and `post-deploy-tests` can't reach
> those resources and the run fails. **Deploy from a laptop/jumpbox with VNet line-of-sight
> instead** ([Deploy from scratch — runbook](./runbook.md)). This page describes the workflow
> for when a **self-hosted runner inside the VNet** is configured — at which point it becomes
> usable as written.

<!-- -->

> [!NOTE]
> **Where this fits in the tier model.** Everything on this page is either **Tier 0** (the one-time bootstrap — normally driven by [`scripts/Initialize-RdsFarm.ps1`](../scripts/Initialize-RdsFarm.ps1)) or **Tier 1** (the pipeline itself — runs in GitHub Actions on every push/PR). See [README → Deployment guide](../README.md#deployment-guide).
>
> **What `main.bicepparam` values does the pipeline auto-supply?** Three: `domainJoinPassword` and `localAdminPassword` (via `readEnvironmentVariable(...)`) and `artifactsLocation` (via `--parameters` override from the `upload-artifacts` job output). See [README → Parameters reference](../README.md#parameters-reference-mainbicepparam) for the full per-parameter source.

A ready-to-use workflow is provided at [`.github/workflows/deploy.yml`](../.github/workflows/deploy.yml). It uses **OIDC federated credentials** (no client secrets stored in GitHub) and is **manual-trigger only** — it does not run on push or pull request:

| Trigger | Jobs |
| --- | --- |
| `workflow_dispatch` → `action: what-if` | `lint` → `config-tests` → `package-dsc` → `upload-artifacts` → `pre-deploy-checks` → `what-if` |
| `workflow_dispatch` → `action: deploy` | `lint` → `config-tests` → `package-dsc` → `upload-artifacts` → `pre-deploy-checks` → `deploy` → `post-deploy-tests` |

Run it from **Actions → Deploy RDS Farm → Run workflow** in the GitHub UI.

> The pipeline does not provision the artifacts storage account or Key Vault — those are Tier 0 prerequisites set up by [`scripts/Initialize-RdsFarm.ps1`](../scripts/Initialize-RdsFarm.ps1). When you need to change `prereqs/tier0.bicep` (add an admin principal, tighten the SA's network ACL, etc.), re-run that script from your laptop.

The pipeline:

1. **`lint`** — compiles `main.bicep`, `main.bicepparam`, `prereqs/tier0.bicep`, and `prereqs/tier0.bicepparam` (the latter two are linted here even though the pipeline never deploys them, so Tier 0 doesn't ship broken Bicep).
2. **`config-tests`** (no Azure) — runs [`actionlint`](https://github.com/rhysd/actionlint), [`markdownlint-cli2`](https://github.com/DavidAnson/markdownlint-cli2), [`tests/Test-DscConfiguration.ps1`](../tests/Test-DscConfiguration.ps1) (PSScriptAnalyzer + parse + Configuration discovery), and [`tests/Test-BicepParamValues.ps1`](../tests/Test-BicepParamValues.ps1) (no public-internet CIDRs, valid AD DNS IP, valid KV secret URI, hostnames ≤ 15 chars, etc.).
3. **`package-dsc`** — zips `dsc/Configuration.ps1` → `Configuration.zip`.
4. **`upload-artifacts`** — runs [`scripts/Publish-DscArtifact.ps1`](../scripts/Publish-DscArtifact.ps1) which uploads the zip to the storage account named by the `ARTIFACTS_STORAGE_ACCOUNT` repo variable (set by Tier 0) using **`--auth-mode login`** (no account keys, no SAS — tenant policy forbids both). Outputs `artifacts_location` + `artifacts_storage_account` for downstream jobs via `needs.upload-artifacts.outputs.*`.
5. **`pre-deploy-checks`** (Azure read-only) — verifies the Tier 0 artifacts SA exists, the existing VNet/subnet exist and have enough free IPs for the requested `sessionHostCount`, that `AzureBastionSubnet` is present when `deployBastion=true`, that the Key Vault is RBAC-enabled and the cert is exportable + not about to expire (when `enableCertificateBinding=true`), that `Configuration.zip` exists in the artifacts container (checked with `az storage blob exists --auth-mode login`, no SAS), and finally runs `az deployment group validate` (this catches RBAC/policy errors that `what-if` masks as `ResourceNotFound`).
6. **`what-if`** (when `action: what-if`) **or** **`deploy`** (when `action: deploy`). The what-if output is written to `whatif.txt` and appended to the run's job summary so the resource diff is one click away from the Actions tab.
7. **`post-deploy-tests`** (after `deploy` succeeds) — runs [`tests/Test-PostDeployHealth.ps1`](../tests/Test-PostDeployHealth.ps1): every VM extension `provisioningState=Succeeded`, per-VM Resource Health, LB backend pool health, DNS resolution, RD Web URL HTTPS 200 (soft-warn — the runner IP may not be in `allowedClientSourceAddressPrefixes`, which is expected for production allow-lists and does not fail the job).
8. Posts the gateway FQDN, RD Web URL, and test result to the GitHub Actions job summary.

See [Testing & verification → §5](./testing.md#5-continuous-testing-in-ci) for the full test matrix.

## SP RBAC

The pipeline's service principal (created by Tier 0) holds these roles. The first row is what the bootstrap actually grants; the rest are listed so you know what the SP can do (and what to scope down if your security policy doesn't allow sub-scope `Contributor`).

| Scope | Role | Why | Granted by Tier 0? |
| --- | --- | --- | --- |
| Subscription | `Contributor` + `Role Based Access Control Administrator` | `Contributor` is required to create the farm RG and read across the existing VNet RG; `RBAC Admin` is required because [`modules/sa-role.bicep`](../modules/sa-role.bicep) and [`modules/kv-role.bicep`](../modules/kv-role.bicep) create role assignments in the artifacts and Key Vault RGs at deploy time. Also implicitly satisfies all narrower scopes below. | **Yes** |
| Target resource group (`rds-farm-rg`) | `Contributor` | Deploy VMs, LB, etc. | Inherited from sub |
| Existing VNet RG | `Network Contributor` | Read existing VNet/subnet, write the client allow-list rules to the subnet's governance NSG. | Inherited from sub |
| Existing Key Vault (if cert binding) | `Key Vault Reader` + `Role Based Access Control Administrator` | [`modules/kv-role.bicep`](../modules/kv-role.bicep) creates a role assignment, which needs `Microsoft.Authorization/roleAssignments/write`. | Inherited from sub |
| Artifacts storage account | `Storage Blob Data Contributor` | Upload `Configuration.zip` from CI (the `--auth-mode login` flag uses the SP's Entra token, no account keys, no SAS). The VMs themselves use a separate UAMI with `Storage Blob Data Reader` (granted by [`modules/sa-role.bicep`](../modules/sa-role.bicep)) to read the blob back at apply-time. | Inherited from sub |

> If your tenant won't allow sub-scope `Contributor` for a CI principal, hand-grant the four narrower scopes above instead. The pipeline never deploys the prereqs template itself — that's always done from a laptop via [`scripts/Initialize-RdsFarm.ps1`](../scripts/Initialize-RdsFarm.ps1) — so you don't need sub-scope `Contributor` purely for CI's sake.

**Why a service principal and not your own user?** GitHub Actions can't log in interactively as a human (no browser, no MFA). OIDC federated credentials only attach to app registrations. Tier 0 runs *as you* (your Owner user signs in via `az login`) and creates a separate SP that the workflow uses thereafter. Two identities, two purposes.

## Notes on blob authentication

- The artifacts storage account is provisioned with `allowSharedKeyAccess: false` and `defaultToOAuthAuthentication: true` (see [`prereqs/modules/storage.bicep`](../prereqs/modules/storage.bicep)). The tenant Azure Policy in use here also forbids any SAS, including user-delegation SAS — so all blob I/O must use OAuth.
- **CI uploads** use `az storage blob upload --auth-mode login`: the GitHub Actions OIDC token logs in the workflow's service principal, which holds `Storage Blob Data Contributor` on the SA.
- **VMs download** `Configuration.zip` via the DSC extension's `protectedSettings.managedIdentity = { clientId }` (DSC v2.83+). The Bicep grants the VMs' user-assigned managed identity `Storage Blob Data Reader` on the SA via [`modules/sa-role.bicep`](../modules/sa-role.bicep). No SAS or shared key ever leaves the storage account.
- Bicep parameters set via `--parameters key=value` override values from `main.bicepparam`. The pipeline uses this to inject `artifactsLocation` so the file can stay environment-neutral in source control.

## Standalone CI bootstrap (advanced)

> [!IMPORTANT]
> Run [`scripts/Initialize-RdsFarm.ps1`](../scripts/Initialize-RdsFarm.ps1) for the normal Tier 0 flow — it calls the script below in the right order with the rest of Tier 0 (prereqs Bicep, TLS cert, bicepparam patch). Reach for `Initialize-CiPrerequisites.ps1` standalone only when you want to wire CI **without** provisioning Azure prereqs (e.g. you already have the Key Vault and storage SA), or when you're re-running just the CI bootstrap after a tenant change.

[`scripts/Initialize-CiPrerequisites.ps1`](../scripts/Initialize-CiPrerequisites.ps1) is idempotent. Run it once as an Owner-rights user from your laptop:

```powershell
# Prereqs on YOUR laptop:
#   az login --tenant <your-tenant-id>     # signs you in as an Owner-rights user
#   gh auth login --scopes repo            # GitHub CLI with repo scope

cd C:\Users\jozoslejko\OneDrive\Dev\rds-farm
.\scripts\Initialize-CiPrerequisites.ps1 -GitHubRepo '<org>/<repo>' -GhRequireProductionApproval
```

What the script does (each step is safe to re-run):

| # | Action | Manual equivalent |
| --- | --- | --- |
| 1 | Creates (or reuses) Entra app `gh-rds-farm-deploy` + service principal | `az ad app create` / `az ad sp create` |
| 2 | Creates the 4 federated credentials (`gh-main`, `gh-pr`, `gh-env-production`, `gh-env-preview`) | `az ad app federated-credential create` |
| 3 | Grants the SP the roles in the [SP RBAC](#sp-rbac) table above | `az role assignment create` |
| 4 | Sets the 5 repo secrets (passwords prompted silently via `Read-Host -AsSecureString`) | `gh secret set` |
| 5 | Sets `ARTIFACTS_STORAGE_ACCOUNT` if `-ArtifactsStorageAccount <name>` is passed | `gh variable set` |
| 6 | Creates the `preview` and `production` GitHub environments | `gh api .../environments` |
| 7 | **Self-check** — invokes [`tests/Test-CiPrerequisites.ps1`](../tests/Test-CiPrerequisites.ps1) at the end to confirm steps 1–6 all stuck (gracefully degrades if the test file is missing). | `./tests/Test-CiPrerequisites.ps1 -GitHubRepo <org>/<repo>` |

Validate any time with the read-only check:

```powershell
./tests/Test-CiPrerequisites.ps1 -GitHubRepo '<org>/<repo>'
# Exits 1 on any FAIL; prints PASS/WARN/FAIL per check.
```
