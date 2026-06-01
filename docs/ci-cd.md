# CI/CD with GitHub Actions

[← Back to main README](../README.md)

> [!NOTE]
> **Where this fits in the tier model.** Everything on this page is either **Tier 0** (the one-time bootstrap — normally driven by [`scripts/Initialize-RdsFarm.ps1`](../scripts/Initialize-RdsFarm.ps1)) or **Tier 1** (the pipeline itself — runs in GitHub Actions on every push/PR). See [README → Deployment guide](../README.md#deployment-guide).
>
> **What `main.bicepparam` values does the pipeline auto-supply?** Four: `domainJoinPassword`, `localAdminPassword`, `artifactsLocationSasToken` (all via `readEnvironmentVariable(...)`), and `artifactsLocation` (via `--parameters` override from the `upload-artifacts` job output). See [README → Parameters reference](../README.md#parameters-reference-mainbicepparam) for the full per-parameter source.

A ready-to-use workflow is provided at [`.github/workflows/deploy.yml`](../.github/workflows/deploy.yml). It uses **OIDC federated credentials** (no client secrets stored in GitHub) and runs:

| Trigger | Jobs |
| --- | --- |
| Pull request to `main` | `lint` → `config-tests` → `package-dsc` → `upload-artifacts` → `pre-deploy-checks` → `what-if` |
| Push to `main` | `lint` → `config-tests` → `package-dsc` → `upload-artifacts` → `pre-deploy-checks` → `deploy` → `post-deploy-tests` |
| Manual (`workflow_dispatch`) | choose `action` (what-if / deploy) **and** `prereqs_action` (use-existing / what-if / deploy-new). The `prereqs` job runs only when `prereqs_action != use-existing` — i.e. only on manual runs. |

The pipeline:

1. **`lint`** — compiles `main.bicep`, `main.bicepparam`, `prereqs/main.bicep`, and `prereqs/main.bicepparam`.
2. **`config-tests`** (no Azure) — runs [`actionlint`](https://github.com/rhysd/actionlint), [`markdownlint-cli2`](https://github.com/DavidAnson/markdownlint-cli2), [`tests/Test-DscConfiguration.ps1`](../tests/Test-DscConfiguration.ps1) (PSScriptAnalyzer + parse + Configuration discovery), and [`tests/Test-BicepParamValues.ps1`](../tests/Test-BicepParamValues.ps1) (no public-internet CIDRs, valid AD DNS IP, valid KV secret URI, hostnames ≤ 15 chars, etc.).
3. **`prereqs`** *(manual `workflow_dispatch` only)* — runs `az deployment sub what-if`/`create` against [`prereqs/main.bicep`](../prereqs/main.bicep) when `prereqs_action != use-existing` — provisions a fresh Key Vault + DSC storage account. **Skipped on PR and push events.** See [Prerequisite resources](./prereq-resources.md).
4. **`package-dsc`** — zips `dsc/Configuration.ps1` → `Configuration.zip`.
5. **`upload-artifacts`** — runs [`scripts/Publish-DscArtifact.ps1`](../scripts/Publish-DscArtifact.ps1) which uploads the zip to your artifacts storage account using **`--auth-mode login`** (no account keys) and mints a **user-delegation SAS** (2-hour expiry). Uses the storage account from the prereqs job if it just ran, otherwise the `ARTIFACTS_STORAGE_ACCOUNT` repo variable. The script's outputs (`artifacts_location` URL and `sas`) are piped to `$GITHUB_OUTPUT` with `::add-mask::` on the SAS so it never appears in logs. Subsequent jobs read both via `needs.upload-artifacts.outputs.*`.
6. **`pre-deploy-checks`** (Azure read-only) — verifies the existing VNet/subnet exist and have enough free IPs for the requested `sessionHostCount`, that `AzureBastionSubnet` is present when `deployBastion=true`, that the Key Vault is RBAC-enabled and the cert is exportable + not about to expire (when `enableCertificateBinding=true`), that `Configuration.zip` is reachable via the SAS, and finally runs `az deployment group validate` (this catches RBAC/policy errors that `what-if` masks as `ResourceNotFound`).
7. **`what-if`** (PRs / manual `what-if`) **or** **`deploy`** (push to `main` / manual `deploy`). On PRs, the what-if output is written to `whatif.txt`, appended to the run's job summary, and posted as a collapsible PR comment by `github-actions[bot]`. Re-runs on the same PR upsert the comment (the prior one is deleted, the new one is posted) so the conversation isn't spammed. Output longer than ~60 KB is truncated in the comment but kept in full in the job summary to stay under GitHub's 65 KB comment cap.
8. **`post-deploy-tests`** (after `deploy` succeeds) — runs [`tests/Test-PostDeployHealth.ps1`](../tests/Test-PostDeployHealth.ps1): every VM extension `provisioningState=Succeeded`, per-VM Resource Health, LB backend pool health, DNS resolution, RD Web URL HTTPS 200 (soft-warn — the runner IP may not be in `allowedClientSourceAddressPrefixes`, which is expected for production allow-lists and does not fail the job).
9. Posts the gateway FQDN, RD Web URL, and test result to the GitHub Actions job summary.

See [Testing & verification → §5](./testing.md#5-continuous-testing-in-ci) for the full test matrix.

## SP RBAC

The pipeline's service principal (created by Tier 0) holds these roles. The first row is what the bootstrap actually grants; the rest are listed so you know what the SP can do (and what to scope down if your security policy doesn't allow sub-scope `Contributor`).

| Scope | Role | Why | Granted by Tier 0? |
| --- | --- | --- | --- |
| Subscription | `Contributor` + `Role Based Access Control Administrator` | Required for `prereqs_action: deploy-new` — the prereqs template is sub-scope and creates RGs + role assignments. Also implicitly satisfies all narrower scopes below. | **Yes** |
| Target resource group (`rds-farm-rg`) | `Contributor` | Deploy VMs, LB, NSG, etc. | Inherited from sub |
| Existing VNet RG | `Network Contributor` | Read existing VNet/subnet, attach NSG. | Inherited from sub |
| Existing Key Vault (if cert binding) | `Key Vault Reader` + `Role Based Access Control Administrator` | [`modules/kv-role.bicep`](../modules/kv-role.bicep) creates a role assignment, which needs `Microsoft.Authorization/roleAssignments/write`. | Inherited from sub |
| Artifacts storage account | `Storage Blob Data Contributor` | Upload `Configuration.zip` and mint a user-delegation SAS. | Inherited from sub |

> If your tenant won't allow sub-scope `Contributor` for a CI principal, comment out **Step 3** in [`scripts/Initialize-CiPrerequisites.ps1`](../scripts/Initialize-CiPrerequisites.ps1), have a human run the prereqs deploy from their laptop ([Option 2 in `prereq-resources.md`](./prereq-resources.md#option-2--manual-az-deployment-sub-create)), and then grant the four narrower scopes above by hand. The workflow's `prereqs_action: deploy-new` choice will no longer work — leave it at `use-existing` forever.

**Why a service principal and not your own user?** GitHub Actions can't log in interactively as a human (no browser, no MFA). OIDC federated credentials only attach to app registrations. Tier 0 runs *as you* (your Owner user signs in via `az login`) and creates a separate SP that the workflow uses thereafter. Two identities, two purposes.

## Notes on the SAS approach

- The workflow uses `az storage blob generate-sas --auth-mode login --as-user`, which produces a **user-delegation SAS** signed with the service principal's Entra ID token. No storage account keys are ever required.
- SAS lifetime is 2 hours — enough for the DSC extension to download `Configuration.zip` during provisioning, but short enough that a leaked log line won't be exploitable for long. The SAS is also masked with `::add-mask::`.
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
.\scripts\Initialize-CiPrerequisites.ps1 -GitHubRepo '<org>/<repo>' -RequireProductionApproval
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
