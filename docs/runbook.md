# Deploy from scratch — runbook

[← Back to main README](../README.md)

A single linear walkthrough: from an empty subscription to a working RD Web sign-in.
Follow it top to bottom. Each step links to the reference doc with the full detail and
options; this page is the happy path.

> [!IMPORTANT]
> **Deploy from inside the VNet.** The artifacts storage account and Key Vault are
> private-endpoint-only (public network access disabled). A GitHub-hosted pipeline
> runner sits outside the VNet and can't reach them, so the **GitHub Actions pipeline
> can't deploy today** — it needs a self-hosted runner inside the VNet. Until that
> exists, run Tier 0 and the deploy from a machine with VNet line-of-sight: a laptop
> on VPN, or a jumpbox in a peered network.

| Phase | What | Where |
| --- | --- | --- |
| [0. Prerequisites](#0-prerequisites-outside-this-repo) | AD, network, DNS, decisions | Outside Azure |
| [1. Laptop tooling](#1-laptop--jumpbox-tooling) | `az`, `gh`, `pwsh`, `bicep` | Your machine |
| [2. Tier 0 — bootstrap](#2-tier-0--bootstrap-one-command) | CI wiring, prereq RGs/KV/SA, cert, bicepparam | One script |
| [3. Tier 1 — deploy](#3-tier-1--deploy-laptopjumpbox) | Package DSC → what-if → create | Laptop/jumpbox in-VNet |
| [4. Verify](#4-verify) | Smoke tests | Laptop/jumpbox |
| [5. Tier 2 — post-deploy](#5-tier-2--post-deploy) | CNAME, CALs, AD group | Ad-hoc |

---

## 0. Prerequisites (outside this repo)

These live in AD, networking, or DNS — no script can create them. Tier 0 prompts you for
the values that name them.

- [ ] **AD DS reachable** from the target subnet (DNS, LDAP, Kerberos, SMB to a DC).
- [ ] **Domain-join service account** exists, with delegated rights to create/join machine
      objects in the target OU (default sAMAccountName `svc-domainjoin`). You supply its
      password to Tier 0 once.
- [ ] **AD security group for RDS access** exists (e.g. `RDS-Users`, or `Domain Users` for a lab).
- [ ] **Target VNet + subnet** exist and route to the DC. The subnet should have its
      **governance NSG** attached — the farm writes its client allow-list (TCP 443 / UDP 3391)
      as rules on that NSG rather than attaching its own.
- [ ] **Allowed client source CIDRs** decided (office / VPN egress only — never `0.0.0.0/0`).
- [ ] **Public hostname + cert mode** decided — vanity CNAME (`rds.contoso.com`, public-CA cert)
      or the free `*.cloudapp.azure.com` LB hostname (lab, self-signed). See
      [Gateway FQDN and TLS certificate](./fqdn-and-cert.md).

Full prerequisite detail: [Manual setup checklist → Prerequisites](./manual-checklist.md#prerequisites--outside-this-repos-scope).

---

## 1. Laptop / jumpbox tooling

On a machine with VNet line-of-sight:

- [ ] **PowerShell 7+**
- [ ] **Azure CLI** signed in (`az login`), Owner on the target subscription.
- [ ] **GitHub CLI** signed in (`gh auth login --scopes repo`), Admin on the repo. *(Tier 0
      wires up the workflow even though it can't run yet — so it's ready when a self-hosted
      runner is added.)*
- [ ] **`az bicep`** (`az bicep install`).
- [ ] **Application Developer** (or higher) in the Entra tenant (Tier 0 creates an app registration).

---

## 2. Tier 0 — bootstrap (one command)

[`scripts/Initialize-RdsFarm.ps1`](../scripts/Initialize-RdsFarm.ps1) does it all in one pass:
CI wiring (Entra app + federated creds + repo secrets), prereq RGs + Key Vault + storage
account ([`prereqs/tier0.bicep`](../prereqs/tier0.bicep)), the TLS cert in Key Vault, and a
fully populated [`main.bicepparam`](../main.bicepparam) (including auto-discovering the subnet's
governance NSG name).

```powershell
./scripts/Initialize-RdsFarm.ps1 `
    -GitHubRepo 'contoso/rds-farm' `
    -AdDomainName contoso.local -AdDnsServerIp 10.10.0.4 `
    -RdsAccessGroup 'RDS-Users' `
    -ExistingVnetName corp-vnet `
    -ExistingVnetResourceGroup network-rg `
    -ExistingRdsSubnetName snet-rds `
    -AllowedClientSourceAddressPrefixes '203.0.113.0/24','198.51.100.10/32' `
    -PublicGatewayFqdn rds.contoso.com `
    -ArtifactsStorageAccount contosordsart01 `
    -KeyVaultName contoso-rds-kv01 `
    -CertMode Csr
```

- Omit any required value and the script prompts (defaults shown in brackets). Add `-Interactive`
  to be prompted for every optional value too.
- Lab shortcut: `./scripts/Initialize-RdsFarm.ps1 -GitHubRepo 'me/rds-farm' -CertMode SelfSigned`.
- **`Csr` mode is two-pass:** the first run emits a CSR and stops; submit it to your CA, then
  re-run Tier 0 (or `New-RdsCertificate.ps1 -MergeSignedCert <signed.cer>`) to finish.

After it finishes, commit the config:

```powershell
git add main.bicepparam
git commit -m 'Initialize farm config'
```

Verify Tier 0 (read-only): `./tests/Test-RdsFarmInit.ps1 -GitHubRepo <owner>/<repo>`.
Detail: [Manual setup checklist → Tier 0](./manual-checklist.md#tier-0--bootstrap-one-command).

---

## 3. Tier 1 — deploy (laptop/jumpbox)

From the in-VNet machine, [`scripts/Invoke-ManualDeploy.ps1`](../scripts/Invoke-ManualDeploy.ps1)
packages DSC ([`scripts/Publish-DscArtifact.ps1`](../scripts/Publish-DscArtifact.ps1) uploads
`Configuration.zip` + `Bootstrap.ps1` via managed identity), runs the readiness gate, then
`az deployment group what-if` and `create`. It prompts for `DOMAIN_JOIN_PASSWORD` /
`LOCAL_ADMIN_PASSWORD` if they're not already in your shell.

```powershell
# Preview
./scripts/Invoke-ManualDeploy.ps1 -Action what-if -StorageAccount contosordsart01

# Apply
./scripts/Invoke-ManualDeploy.ps1 -Action deploy  -StorageAccount contosordsart01
```

Typical wall-clock on `Standard_D4s_v5`: **25–40 min** (VM provisioning + domain-join reboot +
DSC role install + RDS deployment). On a successful `-Action deploy` the wrapper then runs the
post-deploy smoke test automatically ([step 4](#4-verify)) — add `-SkipPostDeployTest` to skip it,
or `-AddClientIpToNsg` to also get a green RD Web result from a non-allow-listed host. What the
deploy does to the VMs, step by step (Bicep + DSC, 12 steps), and the by-hand `az` equivalents:
[Manual deploy](./manual-deploy.md).

> If the readiness check warns that Key Vault / the storage account is unreachable from this
> host, you're running from **outside** the VNet — move to a laptop on VPN or an in-VNet jumpbox.
> Uploading the DSC artifact needs data-plane write to the private-endpoint-only storage account.

---

## 4. Verify

`Invoke-ManualDeploy.ps1 -Action deploy` runs this automatically on success. To run it on demand
(or after `-SkipPostDeployTest`):

```powershell
./tests/Test-PostDeployHealth.ps1 -ResourceGroupName rds-farm-rg
```

Confirms every VM extension provisioned, per-VM Resource Health, LB backend health, DNS
resolution, and RD Web reachability. To get a green RD Web result from a host that isn't in the
allow-list, add `-AddClientIpToNsg` (temporarily opens the subnet NSG to this machine's IP, then
removes it). Full staged checks (pre-deploy → in-VM RDS roles → end-to-end client RDP):
[Testing & verification](./testing.md).

---

## 5. Tier 2 — post-deploy

- [ ] **Public CNAME** *(vanity FQDN only)* — point `<your-fqdn>` → the `gatewayFqdn` deploy
      output (TTL 300). Azure DNS shortcut: [`scripts/Set-GatewayCname.ps1`](../scripts/Set-GatewayCname.ps1)
      (`-Verify` probes `https://<fqdn>/RDWeb/`). Other providers: create the CNAME by hand per
      [Manual deploy → 7a](./manual-deploy.md#7a-public-dns-cname-vanity-fqdn-only).
- [ ] **Activate the RDS license server** on the broker (*RD Licensing Manager → Activate Server*)
      and install your CALs. The deployment runs in a 120-day per-user grace period until you do.
- [ ] **Add the broker computer to the AD `Terminal Server License Servers` group** (Domain Admin —
      outside the domain-join account's rights). Without it the broker can't hand out CALs after grace.
- [ ] **(Optional) Tear-down:** [`scripts/Remove-RdsFarm.ps1`](../scripts/Remove-RdsFarm.ps1)
      deletes the farm RG (and optionally the prereq RGs). Interactive `'yes'` unless `-Force`.

---

## Where to go deeper

| Topic | Doc |
| --- | --- |
| Tickable checklist version of this runbook | [Manual setup checklist](./manual-checklist.md) |
| Hostname + cert decisions (vanity vs LB FQDN, Csr/ImportPfx/SelfSigned) | [Gateway FQDN and TLS certificate](./fqdn-and-cert.md) |
| Prereq Key Vault + storage account internals | [Prerequisite resources](./prereq-resources.md) |
| What the deploy does to the VMs + by-hand `az` recipes | [Manual deploy](./manual-deploy.md) |
| Staged smoke tests | [Testing & verification](./testing.md) |
| Failures grouped by tier | [Troubleshooting](./troubleshooting.md) |
| Pipeline wiring (for when a self-hosted in-VNet runner exists) | [CI/CD with GitHub Actions](./ci-cd.md) |
