# CI/CD with GitHub Actions

[← Back to main README](../README.md)

A ready-to-use workflow is provided at [`.github/workflows/deploy.yml`](../.github/workflows/deploy.yml). It uses **OIDC federated credentials** (no client secrets stored in GitHub) and runs:

| Trigger | Jobs |
| --- | --- |
| Pull request to `main` | `lint` → `config-tests` → `package-dsc` → `upload-artifacts` → `pre-deploy-checks` → `what-if` |
| Push to `main` | `lint` → `config-tests` → `package-dsc` → `upload-artifacts` → `pre-deploy-checks` → `deploy` → `post-deploy-tests` |
| Manual (`workflow_dispatch`) | choose `action` (what-if / deploy) **and** `prereqs_action` (use-existing / what-if / deploy-new). The `prereqs` job runs only when `prereqs_action != use-existing` — i.e. only on manual runs. |

The pipeline:

1. **`lint`** — compiles `main.bicep`, `main.bicepparam`, `prereqs/main.bicep`, and `prereqs/main.bicepparam`.
2. **`config-tests`** (no Azure) — runs [`actionlint`](https://github.com/rhysd/actionlint), [`markdownlint-cli2`](https://github.com/DavidAnson/markdownlint-cli2), [`tests/Test-DscConfiguration.ps1`](../tests/Test-DscConfiguration.ps1) (PSScriptAnalyzer + parse + Configuration discovery), and [`tests/Test-BicepParamValues.ps1`](../tests/Test-BicepParamValues.ps1) (no public-internet CIDRs, valid AD DNS IP, valid KV secret URI, hostnames ≤ 15 chars, etc.).
3. **`prereqs`** *(manual `workflow_dispatch` only)* — runs `az deployment sub what-if`/`create` against [`prereqs/main.bicep`](../prereqs/main.bicep) when `prereqs_action != use-existing` — provisions a fresh Key Vault + DSC storage account. **Skipped on PR and push events.** See [Prerequisite resources](./prereqs.md).
4. **`package-dsc`** — zips `dsc/Configuration.ps1` → `Configuration.zip`.
5. **`upload-artifacts`** — uploads the zip to your artifacts storage account using **`--auth-mode login`** (no account keys). Uses the storage account from the prereqs job if it just ran, otherwise the `ARTIFACTS_STORAGE_ACCOUNT` repo variable. Generates a **user-delegation SAS** (2-hour expiry) and masks it from logs.
6. **`pre-deploy-checks`** (Azure read-only) — verifies the existing VNet/subnet exist and have enough free IPs for the requested `sessionHostCount`, that `AzureBastionSubnet` is present when `deployBastion=true`, that the Key Vault is RBAC-enabled and the cert is exportable + not about to expire (when `enableCertificateBinding=true`), that `Configuration.zip` is reachable via the SAS, and finally runs `az deployment group validate` (this catches RBAC/policy errors that `what-if` masks as `ResourceNotFound`).
7. **`what-if`** (PRs / manual `what-if`) **or** **`deploy`** (push to `main` / manual `deploy`).
8. **`post-deploy-tests`** (after `deploy` succeeds) — runs [`tests/Test-PostDeployHealth.ps1`](../tests/Test-PostDeployHealth.ps1): every VM extension `provisioningState=Succeeded`, per-VM Resource Health, LB backend pool health, DNS resolution, RD Web URL HTTPS 200 (soft-warn — the runner IP may not be in `allowedClientSourceAddressPrefixes`).
9. Posts the gateway FQDN, RD Web URL, and test result to the GitHub Actions job summary.

See [Testing & verification → §5](./testing.md#5-continuous-testing-in-ci) for the full test matrix.

## One-time setup

### 1. Run the bootstrap script

[`scripts/Initialize-CiPrerequisites.ps1`](../scripts/Initialize-CiPrerequisites.ps1) is an idempotent script that creates the Entra app + federated credentials, assigns RBAC, and configures GitHub secrets / variables / environments. Run it once as an Owner-rights user from your laptop:

```powershell
# Prereqs on YOUR laptop:
#   az login --tenant <your-tenant-id>     # signs you in as an Owner-rights user
#   gh auth login --scopes repo            # GitHub CLI with repo scope

cd C:\Users\jozoslejko\OneDrive\Dev\rds-farm
.\scripts\Initialize-CiPrerequisites.ps1 -GitHubRepo '<org>/<repo>' -RequireProductionApproval
```

What the script does (each step is safe to re-run):

| # | Action | Manual equivalent |
| --- | --- | --- |
| 1 | Creates (or reuses) Entra app `gh-rds-farm-deploy` + service principal | `az ad app create` / `az ad sp create` |
| 2 | Creates the 4 federated credentials (`gh-main`, `gh-pr`, `gh-env-production`, `gh-env-preview`) | `az ad app federated-credential create` |
| 3 | Grants the SP the roles in the [RBAC table](#sp-rbac) below | `az role assignment create` |
| 4 | Sets the 5 repo secrets (passwords prompted silently via `Read-Host -AsSecureString`) | `gh secret set` |
| 5 | Sets `ARTIFACTS_STORAGE_ACCOUNT` if `-ArtifactsStorageAccount <name>` is passed | `gh variable set` |
| 6 | Creates the `preview` and `production` GitHub environments | `gh api .../environments` |

> **Why a service principal and not your own user?** GitHub Actions can't log in interactively as a human (no browser, no MFA). OIDC federated credentials only attach to app registrations. You run the bootstrap script *as yourself* (your Owner user signs in via `az login`), and the script creates a separate SP that the workflow uses thereafter. Two identities, two purposes.

#### SP RBAC

The bootstrap script assigns these roles. The first row is granted automatically; the rest are listed so you know what the SP can do (and what to scope down if your security policy doesn't allow sub-scope `Contributor`).

| Scope | Role | Why | Granted by script? |
| --- | --- | --- | --- |
| Subscription | `Contributor` + `Role Based Access Control Administrator` | Required for `prereqs_action: deploy-new` — the prereqs template is sub-scope and creates RGs + role assignments. Also implicitly satisfies all narrower scopes below. | **Yes** |
| Target resource group (`rds-farm-rg`) | `Contributor` | Deploy VMs, LB, NSG, etc. | Inherited from sub |
| Existing VNet RG | `Network Contributor` | Read existing VNet/subnet, attach NSG. | Inherited from sub |
| Existing Key Vault (if cert binding) | `Key Vault Reader` + `Role Based Access Control Administrator` | [`modules/kv-role.bicep`](../modules/kv-role.bicep) creates a role assignment, which needs `Microsoft.Authorization/roleAssignments/write`. | Inherited from sub |
| Artifacts storage account | `Storage Blob Data Contributor` | Upload `Configuration.zip` and mint a user-delegation SAS. | Inherited from sub |

> If your tenant won't allow sub-scope `Contributor` for a CI principal, comment out **Step 3** in [`scripts/Initialize-CiPrerequisites.ps1`](../scripts/Initialize-CiPrerequisites.ps1), have a human run the prereqs deploy from their laptop ([Option 2 in `prereqs.md`](./prereqs.md#option-2--manual-az-deployment-sub-create)), and then grant the four narrower scopes above by hand. The workflow's `prereqs_action: deploy-new` choice will no longer work — leave it at `use-existing` forever.

#### Verifying the bootstrap

After running `Initialize-CiPrerequisites.ps1`, validate the result end-to-end with [`tests/Test-CiPrerequisites.ps1`](../tests/Test-CiPrerequisites.ps1) — a read-only check that the Entra app, all 4 federated credentials, sub-scope RBAC, 5 repo secrets, the `ARTIFACTS_STORAGE_ACCOUNT` variable, and both GitHub environments are in place:

```powershell
./tests/Test-CiPrerequisites.ps1 -GitHubRepo '<org>/<repo>'
# Exits 1 on any FAIL; prints PASS/WARN/FAIL per check.
```

Run it again after any rotation or rename to confirm nothing drifted.

### 2. (Only if reusing an existing storage account) ensure the `dsc` container exists

The [`prereqs/`](../prereqs/main.bicep) template creates the container for you. Skip this step unless you set `-ArtifactsStorageAccount <existing>` and that account doesn't already have a `dsc` container:

```powershell
az storage container create `
  --account-name $env:ARTIFACTS_STORAGE_ACCOUNT `
  --name dsc `
  --auth-mode login
```

### 3. Push and run

```powershell
git add .
git commit -m "ci: add GitHub Actions deployment for RDS farm"
git push origin main
```

For the very first run (no prereq resources yet) trigger the workflow manually:

**Actions → Deploy RDS Farm → Run workflow** with `prereqs_action: deploy-new` and `action: what-if`. After it succeeds, copy the storage account name from the job summary and set the repo variable so subsequent runs default to `use-existing`:

```powershell
gh variable set ARTIFACTS_STORAGE_ACCOUNT --repo '<org>/<repo>' --body '<sa-name>'
```

Thereafter, opening a PR runs `what-if` and posts the plan; merging to `main` triggers `deploy` (gated by the `production` environment approval).

## Notes on the SAS approach

- The workflow uses `az storage blob generate-sas --auth-mode login --as-user`, which produces a **user-delegation SAS** signed with the service principal's Entra ID token. No storage account keys are ever required.
- SAS lifetime is 2 hours — enough for the DSC extension to download `Configuration.zip` during provisioning, but short enough that a leaked log line won't be exploitable for long. The SAS is also masked with `::add-mask::`.
- Bicep parameters set via `--parameters key=value` override values from `main.bicepparam`. The pipeline uses this to inject `artifactsLocation` so the file can stay environment-neutral in source control.
