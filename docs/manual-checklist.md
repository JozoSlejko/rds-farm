# Manual setup checklist

[← Back to main README](../README.md)

Work top to bottom to take a fresh environment from nothing to a working RD Web
sign-in: each box is one action, ordered by when it runs.

> [!IMPORTANT]
> This is the printable / tickable companion to the [Deployment guide in the README](../README.md#deployment-guide). It is grouped into **Prerequisites → Tier 0 → Tier 1 → Tier 2** so you can see when each item runs and who owns it.
>
> Tier 0 is **one script** — [`scripts/Initialize-RdsFarm.ps1`](../scripts/Initialize-RdsFarm.ps1) — so its sub-steps are listed under it for awareness, not as separate manual actions you have to run.

| Legend | Meaning |
| --- | --- |
| **Prerequisites** | Lives outside Azure (AD, networking, DNS). No script can create these for you. |
| **Tier 0** | One-time bootstrap, from an **in-VNet host** (jumpbox / DC). The cert step imports into the private-endpoint-only Key Vault, so it needs VNet line-of-sight. |
| **Tier 1** | Runs every time you change code. Same **in-VNet host** — the GitHub-hosted pipeline can't reach the private-endpoint-only KV/SA. |
| **Tier 2** | Ad-hoc post-deploy operations, from the same **in-VNet host**. |

---

## Prerequisites — outside this repo's scope

- [ ] **AD DS reachable from the target subnet.** A DC with DNS, LDAP, Kerberos, and SMB reachable from the subnet you'll deploy into.
- [ ] **Domain-join service account exists in AD.** Pre-created with delegated rights to create / join machine objects in the target OU (or in the default `Computers` container if you don't pass `-DomainJoinOuPath`). The password is supplied **once** to Tier 0 (read as `SecureString`, stored only as GitHub repo secret `DOMAIN_JOIN_PASSWORD`).
- [ ] **Target OU decided** *(optional)*. If your AD policy disallows the default `Computers` container, decide which OU the new VMs should land in and grant the service account **Create Computer Objects** there. Pass the OU DN as `-DomainJoinOuPath 'OU=RDS,OU=Servers,DC=contoso,DC=local'`.
- [ ] **AD security group for RDS access exists.** Members of this group can sign in via RD Web + RD Gateway. Use `Domain Users` for a quick lab or a dedicated group like `RDS-Users` for production.
- [ ] **Target VNet + subnet exist** in Azure. Subnet must route to the DC. Optionally an `AzureBastionSubnet` (/26) if you want `deployBastion = true`.
- [ ] **Allowed client source CIDRs decided.** Your office/VPN egress IPs only. **Never use `0.0.0.0/0`.**
- [ ] **Public hostname strategy decided.** Vanity CNAME like `rds.contoso.com` (production — requires a public-CA cert) or the free `*.cloudapp.azure.com` hostname (lab only, paired with a self-signed cert). See [Gateway FQDN and TLS certificate](./fqdn-and-cert.md).
- [ ] **Cert mode decided.** `Csr` (Tier 0 generates a CSR, you submit to your CA, re-run with the signed cert), `ImportPfx` (you already have a `.pfx`), `SelfSigned` (lab only), or `LetsEncrypt` (free DV cert via DNS-01 for App Proxy mode — implies `-UseAppProxy`). See [Gateway FQDN and TLS certificate](./fqdn-and-cert.md#decision-3--the-certificate-mode) and [App Proxy](./app-proxy.md).

### Tooling on the in-VNet host (Tier 0)

- [ ] **PowerShell 7+** installed.
- [ ] **Azure CLI signed in:** `az login` (use `--tenant <id>` if needed). You must be Owner on the target subscription.
- [ ] **GitHub CLI signed in:** `gh auth login --scopes repo`. You must have Admin on the GitHub repo.
- [ ] **`az bicep` installed:** `az bicep install` (the orchestrator checks this).
- [ ] **Application Developer** (or higher) role in the Entra tenant so the script can create the pipeline's app registration.

---

## Tier 0 — Bootstrap (one command)

- [ ] **Run [`scripts/Initialize-RdsFarm.ps1`](../scripts/Initialize-RdsFarm.ps1).** Pass values via parameters, or leave them off and the script prompts. Required inputs: `GitHubRepo`, `AdDomainName`, `AdDnsServerIp`, `ExistingVnetName`, `ExistingVnetResourceGroup`, `ExistingRdsSubnetName`, `AllowedClientSourceAddressPrefixes`, `PublicGatewayFqdn`, `ArtifactsStorageAccount`, `KeyVaultName`, `CertMode`. See `Get-Help ./scripts/Initialize-RdsFarm.ps1 -Full` for the rest.

What the orchestrator does for you (each item below is FYI — you don't run them separately):

- [x] Pre-flight (`az` + `gh` auth, `az bicep` present, subscription set).
- [x] Calls [`scripts/Initialize-CiPrerequisites.ps1`](../scripts/Initialize-CiPrerequisites.ps1) — Entra app + 4 federated credentials + RBAC + 5 GitHub repo secrets (`DOMAIN_JOIN_PASSWORD` / `LOCAL_ADMIN_PASSWORD` prompted as `SecureString`) + `preview` / `production` environments. Auto-runs [`tests/Test-CiPrerequisites.ps1`](../tests/Test-CiPrerequisites.ps1).
- [x] Deploys [`prereqs/tier0.bicep`](../prereqs/tier0.bicep) at subscription scope — `rds-artifacts-rg` + `rds-security-rg`, artifacts storage account, Key Vault. `adminPrincipals` pre-populated with `[you, CI service principal]`.
- [x] Calls [`scripts/New-RdsCertificate.ps1`](../scripts/New-RdsCertificate.ps1) in the chosen mode, enforces `exportable: true`, and patches the cert-related params in `main.bicepparam` via [`scripts/Set-BicepParamCertUri.ps1`](../scripts/Set-BicepParamCertUri.ps1).
- [x] **(App Proxy)** With `-CertMode LetsEncrypt`, instead creates the Azure DNS challenge zone, prints the registrar NS/CNAME to add, issues a Let's Encrypt cert via DNS-01, and publishes the Entra App Proxy app ([`New-LetsEncryptRdsCertificate.ps1`](../scripts/New-LetsEncryptRdsCertificate.ps1) + [`Configure-AppProxy.ps1`](../scripts/Configure-AppProxy.ps1)). Needs Cloud Application Administrator. See [App Proxy](./app-proxy.md).
- [x] Patches the rest of `main.bicepparam` (VNet, AD, gateway, allowed CIDRs, artifactsLocation). Validates the file with `az bicep build-params` and restores from `.bak` on failure.
- [x] Sets the `ARTIFACTS_STORAGE_ACCOUNT` GitHub repo variable to the SA the prereqs deployment produced.

After it finishes:

- [ ] **Commit + push `main.bicepparam`.** This is the only file the orchestrator modifies in the repo.

> [!NOTE]
> **Csr mode is two-pass.** First run generates a CSR; halts before patching the bicepparam with an incomplete URI. Submit the CSR to your CA, then re-run `Initialize-RdsFarm.ps1` (or `New-RdsCertificate.ps1 -MergeSignedCert <signed.cer> -OutputBicepParam main.bicepparam` followed by another `Initialize-RdsFarm.ps1` run) to finish.

---

## Tier 1 — Deploy

### Pipeline (blocked today — needs an in-VNet runner)

The GitHub Actions workflow runs the same `main.bicep` / `main.bicepparam` flow, but a GitHub-hosted runner is outside the VNet and can't reach the private-endpoint-only KV/SA during pre-deploy checks, so it fails. It becomes usable once a **self-hosted runner inside the VNet** is configured. Until then, use the laptop / jumpbox path below.

> Changes to [`prereqs/tier0.bicep`](../prereqs/tier0.bicep) (admin principals, SA network ACL, etc.) are **not** redeployed by this workflow. Re-run [`scripts/Initialize-RdsFarm.ps1`](../scripts/Initialize-RdsFarm.ps1) from a laptop to apply them.

Full reference: [CI/CD with GitHub Actions](./ci-cd.md).

### Laptop / jumpbox deploy (the working path today)

Run from a machine with line-of-sight to the VNet (laptop on VPN, or a jumpbox in a peered network). The artifacts SA and Key Vault are private-endpoint-only, so the deployer must be able to reach them.

- [ ] **Pre-flight:** `./tests/Test-PreDeployReadiness.ps1` (exits 1 on any FAIL).
- [ ] **Preview:** `./scripts/Invoke-ManualDeploy.ps1 -Action what-if -StorageAccount <sa>`
- [ ] **Apply:** `./scripts/Invoke-ManualDeploy.ps1 -Action deploy  -StorageAccount <sa>`
- [ ] **Smoke test** runs automatically after a successful deploy (add `-SkipPostDeployTest` to skip, or `-AddClientIpToNsg` for a green RD Web result from a non-allow-listed host). Re-run on demand: `./tests/Test-PostDeployHealth.ps1 -ResourceGroupName rds-farm-rg`.

The wrapper packages DSC (`Configuration.zip` + `Bootstrap.ps1`), uploads it via `--auth-mode login`, prompts for `DOMAIN_JOIN_PASSWORD` / `LOCAL_ADMIN_PASSWORD` if missing, and runs `what-if` + `create`. The DSC extension reads the blobs back at apply-time with the VMs' user-assigned managed identity (no SAS — tenant policy forbids it). Equivalent broken-down `az` commands: [Manual deploy](./manual-deploy.md).

---

## Tier 2 — Post-deploy (ad-hoc)

- [ ] **Create the public CNAME** *(vanity-FQDN deployments only)*. Point `<your-fqdn>` → `gatewayFqdn` output (TTL 300). Azure DNS shortcut: [`scripts/Set-GatewayCname.ps1`](../scripts/Set-GatewayCname.ps1) (use `-Verify` to probe `https://<fqdn>/RDWeb/`). Other DNS providers: do it by hand per [Manual deploy → Step 7a](./manual-deploy.md#7a-public-dns-cname-vanity-fqdn-only).
- [ ] **Activate RDS license server on the broker.** *RD Licensing Manager → Activate Server* and install your real RDS CALs. The deployment runs in the 120-day per-user grace period until you do this.
- [ ] **Add the broker computer to AD `Terminal Server License Servers` group.** Requires Domain Admin; outside the rights granted to the domain-join service account. Without it the broker can't hand out CALs after grace expires.
- [ ] **Run smoke tests.** Sections 2–4 of [Testing & verification](./testing.md#2-post-deployment-azure-side-smoke-tests).
- [ ] **(Optional) Tear-down.** [`scripts/Remove-RdsFarm.ps1`](../scripts/Remove-RdsFarm.ps1) deletes the farm RG (and optionally the artifacts / security RGs created by `prereqs/`). Interactive `'yes'` prompt unless `-Force`.

---

## See also

- [README → Deployment guide](../README.md#deployment-guide) — prose walkthrough
- [README → Parameters reference](../README.md#parameters-reference-mainbicepparam) — per-parameter `Source` (file / env var / CI override)
- [Gateway FQDN and TLS certificate](./fqdn-and-cert.md) — the hostname + cert decisions Tier 0 acts on
- [Manual deploy](./manual-deploy.md) — by-hand procedures when the orchestrator isn't an option
- [Troubleshooting](./troubleshooting.md) — issues grouped by tier
