# Gateway hostname and TLS certificate

[← Back to main README](../README.md)

This page helps you make two choices **before your first Tier 0 run** — the public hostname your users connect to, and the TLS certificate that hostname presents — and shows what Tier 0 then does with them. It covers **both** publishing topologies this farm supports: a public **Standard Load Balancer**, and the **Microsoft Entra application proxy**.

> [!IMPORTANT]
> **Tier 0 owns this.** [`scripts/Initialize-RdsFarm.ps1`](../scripts/Initialize-RdsFarm.ps1) takes your hostname (`-PublicGatewayFqdn`), your topology (`-UseAppProxy`), and your cert mode (`-CertMode Csr | ImportPfx | SelfSigned | LetsEncrypt`), creates the Key Vault, issues / imports the certificate, and writes the matching FQDN + cert URI + subject into [`main.bicepparam`](../main.bicepparam) — before any farm deploy runs. **Never hand-edit `main.bicepparam`;** to change a value, re-run Tier 0 (it's idempotent).
>
> This page explains the **decisions** and what Tier 0 does with them. The by-hand procedure for each step (the rare CI-down / no-orchestrator path) lives in [Manual deploy](./manual-deploy.md); the full application-proxy design and publish steps live in [Application proxy](./app-proxy.md). Cross-references are linked inline below.

---

## Prerequisites

You don't need all of these — only the ones your chosen topology and cert mode call for. Each says how to get or verify it.

- **An in-VNet host to run Tier 0 from** (a jumpbox, the DC, or a VM via Bastion). Key Vault and the artifacts storage account are private-endpoint-only, so cert import and the deploy need line-of-sight. Verify with `az keyvault secret list --vault-name <kv>` — it should succeed, not time out.
- **A public DNS zone you can edit** for your hostname's parent domain (e.g. `contoso.com`), at your registrar or in Azure DNS. You'll add a CNAME after the first deploy (and, for `LetsEncrypt`, a one-time challenge CNAME). Verify you can create a throwaway `TXT` record.
- **A certificate source that matches your cert mode** — a CA that accepts a CSR (`Csr`), an existing exportable `.pfx` with its private key (`ImportPfx`), or nothing extra (`SelfSigned`, `LetsEncrypt`).
- **For application proxy / `LetsEncrypt` only:** an Azure DNS public zone `acme.<parent>` delegated from your registrar (an `NS` record), an identity that can write `TXT` records in it, and **Microsoft Entra ID P1** plus rights to publish the app. Full list: [Application proxy](./app-proxy.md).

---

## The golden rule — one hostname, one matching certificate

Whatever the topology, users connect to **one hostname** (e.g. `rds.contoso.com`), and the TLS handshake on that hostname must present a certificate whose Subject / SAN matches it. So:

- You pick the hostname **first**.
- The certificate is issued **for that hostname**.
- Tier 0 wires both into `main.bicepparam` in the same pass.

If the two ever drift, every RDP client gets *"The remote computer could not be authenticated due to problems with its security certificate"* and refuses to connect.

---

## Decision 1 — publishing topology

How the farm is exposed to the internet decides the rest: the public edge, the DNS records you create, and which cert modes are viable. Choose with the `-UseAppProxy` switch at Tier 0 (the `LetsEncrypt` cert mode implies it).

| | **Load balancer** (default) | **Application proxy** (`-UseAppProxy`) |
| --- | --- | --- |
| Public edge | Standard Public IP + Load Balancer | Entra cloud edge + an outbound-only connector VM in the VNet |
| Inbound from internet | `TCP 443` + `UDP 3391`, IP allow-listed | **None** — nothing listens on the internet |
| Pre-authentication | RDS handles it | **Entra ID** (Conditional Access + MFA) before RDS |
| Public hostname | `*.cloudapp.azure.com` (lab) or a vanity CNAME you own | Always a vanity name **you own** (internal == external) |
| Certificate | self-signed (lab) or any public-CA cert | must be **publicly trusted** (`LetsEncrypt`, `Csr`, or `ImportPfx`) |
| Cert stored | Key Vault only | Key Vault **and** the Entra app registration |

> [!NOTE]
> **Application proxy carries HTTPS only — `UDP 3391` does not traverse it,** so you lose the optional UDP transport that helps on lossy links. Everything else (RDP-over-HTTPS through the gateway, the HTML5 web client) works. Full design, constraints, and publish steps: [Application proxy](./app-proxy.md).

---

## Decision 2 — the public hostname

`-PublicGatewayFqdn` is the single hostname users type, e.g. `rds.contoso.com`. The certificate Tier 0 issues encodes this name, so pick it before running Tier 0.

- **Application proxy** always uses a **vanity subdomain you own**. The `*.cloudapp.azure.com` option below does *not* apply: Entra requires a publicly trusted certificate for a domain you control, and the HTML5 web client requires the internal and external names to match (split-horizon DNS resolves the same name to the gateway's private IP inside the VNet). Pass `-PublicGatewayFqdn rds.contoso.com` and skip to Decision 3.
- **Load balancer** gives you two options — pick one before running Tier 0, because the cert encodes your choice:

### Option A — Azure-managed LB hostname (lab / dev only)

The Bicep template creates a Standard Public IP with a DNS label, giving you a free, Azure-managed FQDN:

```text
<gatewayDnsLabelPrefix>.<region>.cloudapp.azure.com
# e.g. contoso-rds.westeurope.cloudapp.azure.com
```

This is the value emitted as the `gatewayFqdn` output. To use it, **don't** pass `-PublicGatewayFqdn` to Tier 0 — pass `-GatewayDnsLabelPrefix contoso-rds` instead, and use `-CertMode SelfSigned`.

> [!WARNING]
> **A public CA will not issue a certificate for `*.cloudapp.azure.com` because you don't own that domain — Microsoft does.** Every public CA enforces Domain Control Validation (HTTP-01, DNS-01, or CAB Forum email), which you cannot pass for someone else's domain. That means with the LB hostname your only practical option is a **self-signed** cert (or one issued by an internal/private CA), and every client gets the *"the identity of this computer cannot be verified"* warning unless you manually push the cert into their Trusted Root store via GPO / Intune.
>
> Use Option A only for short-lived labs, internal demos, or pipelines where you can pre-trust the cert. **For anything user-facing, use Option B.**

Other trade-offs: the hostname exposes that it's running in Azure (`*.cloudapp.azure.com`), and you can't move the farm to a different region / PIP without all your users having to learn a new URL.

### Option B — Vanity CNAME under your own domain (recommended for production)

You expose a friendly name like `rds.contoso.com` that you control. Users always connect to `rds.contoso.com`, while the underlying Azure LB FQDN can change.

It **must be a subdomain**, not the zone apex (`contoso.com` itself). DNS standards forbid a CNAME at the apex; if you really need `contoso.com`, use an ALIAS / ANAME record (supported by Azure DNS, Cloudflare, Route 53) instead of a CNAME.

Common choices:

- `rds.contoso.com`
- `remote.contoso.com`
- `desktop.contoso.com`

Pass it to Tier 0 as `-PublicGatewayFqdn rds.contoso.com`. The orchestrator will:

1. Issue / import a cert with `CN=rds.contoso.com` and `SAN: rds.contoso.com`.
2. Set `publicGatewayFqdn = 'rds.contoso.com'` and `certificateSubject = 'CN=rds.contoso.com'` in `main.bicepparam`.
3. Leave `gatewayDnsLabelPrefix` as a sanitized derivative (the underlying LB hostname still exists — it's the **physical target** of your future CNAME — but it never appears to users or in any TLS handshake).

The CNAME itself is created **after the first successful deploy** because it needs the `gatewayFqdn` output as its target. That's a **Tier 2** step — see [After the first deploy (Tier 2)](#after-the-first-deploy-tier-2) below.

---

## Decision 3 — the certificate mode

The deployment binds **one** certificate to all four RDS roles (`RDGateway`, `RDWebAccess`, `RDPublishing`, `RDRedirector`). Under **application proxy** that same certificate is *also* uploaded to the Entra app registration, because App Proxy can't read Key Vault. The cert must meet **all** of these:

| Requirement | Why | What Tier 0 enforces |
| --- | --- | --- |
| **Subject CN or SAN** matches `publicGatewayFqdn` | RDP client validates the hostname against the cert. Any mismatch → connection rejected. | `New-RdsCertificate.ps1` builds the KV cert policy with `subject = "CN=$Fqdn"` and `subjectAlternativeNames.dnsNames = @($Fqdn)`. |
| **Issued by a publicly trusted CA** *(production)* | The cert is presented to remote users on machines that don't trust your private CA. | `-CertMode Csr`: Tier 0 generates a CSR you submit to your CA. `-CertMode ImportPfx`: you supply a PFX already issued by a trusted CA. **`-CertMode SelfSigned` is rejected for any non-`*.cloudapp.azure.com` hostname in CI** (see Tier 2 readiness checks). |
| **Key type RSA 2048+** (or ECC P-256) | Required by Schannel / RD Gateway. RSA 4096 is fine, RSA 1024 is not. | KV policy: `keyType = 'RSA'`, `keySize = 2048`. |
| **Enhanced Key Usage = Server Authentication** (OID `1.3.6.1.5.5.7.3.1`) | RDS rejects certs without it (error `0x80092004` in EventLog). | KV policy: `ekus = ('1.3.6.1.5.5.7.3.1')`. |
| **`exportable: true`** in the KV cert policy | The broker DSC step exports a temporary PFX to call `Set-RDCertificate -ImportPath`. A non-exportable cert pulled by the KV VM extension cannot be re-exported, even by `LocalSystem`. **This is the most common gotcha.** | KV policy: `keyProperties.exportable = true`. |
| **Includes the private key** | `Set-RDCertificate` needs the private key to install on the other RDS servers. | KV-generated certs always include it; `ImportPfx` mode requires a `.pfx` with private key (not a `.cer`). |
| **Valid for at least 90 days** | RDS doesn't auto-rotate; you want headroom before re-deploying. | KV default is 12 months; CI's `pre-deploy-checks` job fails the run if the cert expires within 30 days. |

Pick the mode that fits your topology and what you already have:

| Mode | Use when | Publicly trusted? | Topology |
| --- | --- | --- | --- |
| `Csr` | Production, you have a CA that signs CSRs | Yes | Either |
| `ImportPfx` | You already hold a `.pfx` with its private key | Depends on issuer | Either |
| `SelfSigned` | Throwaway lab, you can pre-trust the cert | No | Load balancer only |
| `LetsEncrypt` | You want a free, auto-issued public cert | Yes (Let's Encrypt DV) | Application proxy (implies `-UseAppProxy`) |

### Mode A — `Csr` (recommended for a corporate CA)

Tier 0 generates a CSR inside Key Vault. The private key **never leaves the vault**. You submit the CSR to your CA, then re-run Tier 0 with the signed cert. Works with any public CA that accepts a CSR.

This mode is **two-pass**:

1. **First run** — Tier 0 builds the KV cert policy, runs `az keyvault certificate create` (which produces a pending cert + CSR), exports the CSR to `<repo>/<CertName>.csr`, and **halts before patching `main.bicepparam`** with an incomplete cert URI.
2. **You** — submit the CSR to your CA, download the signed cert as `<CertName>.cer`.
3. **Second run** — re-invoke Tier 0 (or call [`scripts/New-RdsCertificate.ps1`](../scripts/New-RdsCertificate.ps1) directly with `-MergeSignedCert <signed.cer>`). The orchestrator calls `az keyvault certificate pending merge`, then patches the cert URI + subject + `enableCertificateBinding = true` into `main.bicepparam`.

### Mode B — `ImportPfx` (you already have a cert)

You have a `.pfx` with the private key, issued by your enterprise CA or a public CA. Pass `-CertMode ImportPfx -PfxPath C:\certs\rds.pfx`. Tier 0 prompts for the PFX password as a `SecureString`, runs `az keyvault certificate import`, and patches the bicepparam in one pass.

> [!WARNING]
> If your `.pfx` was generated with the private key flagged non-exportable (e.g. created on a Windows machine with `-KeyExportPolicy NonExportable`), Key Vault stores it but the broker DSC step fails to re-export. Re-issue the cert with exportable key material before importing.

### Mode C — `SelfSigned` (lab only)

Tier 0 builds a KV cert policy with `issuer = 'Self'` and `subject = "CN=$Fqdn"`, runs `az keyvault certificate create`, and patches the bicepparam in one pass. Clients see a trust warning and must click through it (or you push the cert into the Trusted Root store via GPO / Intune). Rejected for any non-`*.cloudapp.azure.com` hostname in CI, and never valid for application proxy.

### Mode D — `LetsEncrypt` (free public cert, for application proxy)

Tier 0 issues a free **Let's Encrypt** domain-validated (DV) certificate using a **DNS-01** challenge — it proves you control the domain by writing a `TXT` record, so nothing needs to be reachable from the internet. This mode **implies `-UseAppProxy`** and is the recommended path for the application-proxy topology.

Because many registrars have a gated or absent DNS API, the challenge is indirected through an Azure DNS zone you control:

1. **One-time setup** — delegate a small zone `acme.<parent>` (e.g. `acme.contoso.com`) to Azure DNS with an `NS` record at your registrar, and add a static CNAME `_acme-challenge.<fqdn>` → `<label>.acme.<parent>` (e.g. `_acme-challenge.rds.contoso.com` → `rds.acme.contoso.com`). This CNAME never changes; the first Tier 0 run prints these exact records and the derived names.
2. **Issue** — [`scripts/New-LetsEncryptRdsCertificate.ps1`](../scripts/New-LetsEncryptRdsCertificate.ps1) (called by Tier 0) requests the cert via Posh-ACME, writing the dynamic `TXT` to the `acme.<parent>` zone, then **imports the full-chain PFX into Key Vault** (so the KV VM extension + DSC bind it on the RDS roles) and **stages the PFX** for the App Proxy upload.
3. **Publish** — [`scripts/Configure-AppProxy.ps1`](../scripts/Configure-AppProxy.ps1) uploads that staged PFX to the Entra app registration. See [Application proxy](./app-proxy.md) for the publish walk-through.

> [!TIP]
> Use `-Staging` on your first issue to validate the delegation against Let's Encrypt's staging environment without burning production rate limits, then re-run for the real cert.

---

## What Tier 0 writes into `main.bicepparam`

After a successful Tier 0 run (with `-CertMode` other than `Csr`'s first pass), the cert-related params look like this:

```bicep
param enableCertificateBinding = true
param keyVaultName             = 'contoso-rds-kv01'
param keyVaultResourceGroup    = 'rds-security-rg'
param keyVaultCertSecretUri    = 'https://contoso-rds-kv01.vault.azure.net/secrets/rds-tls'
param publicGatewayFqdn        = 'rds.contoso.com'   // vanity FQDN users type
param certificateSubject       = 'CN=rds.contoso.com' // matches the cert's actual Subject
```

The orchestrator backs up the file to `main.bicepparam.bak` first and re-validates with `az bicep build-params`, restoring the backup on any compile failure. You don't hand-edit this. If you ever need to override one of these, re-run Tier 0 with the changed value — re-runs are idempotent.

---

## After the first deploy (Tier 2)

These DNS steps run **once** after the first successful deploy, when the targets exist. Which one applies depends on your topology.

### Application proxy — split-horizon DNS

Two records, because the same name resolves differently inside and outside the VNet:

- **External** (public) — a CNAME `rds.contoso.com` → `<app>.msappproxy.net`. The exact target appears in the Entra portal under the published app → **Application Proxy**; [`scripts/Configure-AppProxy.ps1`](../scripts/Configure-AppProxy.ps1) prints it too. Create it at your registrar / public DNS.
- **Internal** (your AD DNS) — an `A` record `rds.contoso.com` → the gateway's **private** IP, so VNet clients and the connector reach RDS directly. This is what "split-horizon" means: one name, two answers.

Full walk-through: [Application proxy](./app-proxy.md).

### Load balancer, vanity FQDN — create the public CNAME

The Bicep deploy outputs `gatewayFqdn` — this is the target of your CNAME. **Deploy once first** to get it, then create the DNS record.

**Azure DNS shortcut:**

```powershell
# Auto-discover everything from the contoso.com zone + main deployment in rds-farm-rg
./scripts/Set-GatewayCname.ps1 -ZoneName contoso.com -RecordName rds -Verify
```

The script reads `gatewayFqdn` from the deployment outputs, auto-discovers the zone's resource group, upserts the CNAME idempotently, and (with `-Verify`) probes `https://<fqdn>/RDWeb/`.

**Other DNS providers** (Cloudflare, GoDaddy, Route 53, …) — create the CNAME by hand. The verbose `az network dns record-set cname` recipe lives in [Manual deploy → Step 7: post-deployment steps](./manual-deploy.md#7-post-deployment-steps-still-required) for completeness.

### Azure-managed FQDN — nothing to do

The DNS label is registered as part of the deploy. Clients hit `<gatewayDnsLabelPrefix>.<region>.cloudapp.azure.com` directly.

---

## Certificate renewal

How the OS cert store gets the new cert depends on the mode; in **all** cases RDS only re-binds during a DSC apply.

### Csr / ImportPfx / SelfSigned (Key Vault → DSC)

The **Key Vault VM extension** keeps the OS cert store on every RDS VM in sync with the latest version of `keyVaultCertSecretUri` (poll interval: 1 h by default). However, `Set-RDCertificate` is **only re-run during DSC apply**, so RDS keeps pointing at the old cert thumbprint until you trigger a DSC apply. Two options:

1. **Re-run the deploy** (`scripts/Invoke-ManualDeploy.ps1 -Action deploy`) from a laptop/jumpbox with VNet line-of-sight. The DSC `BindRDSCertificates.TestScript` matches the cert by **subject** (not trust level, so self-signed certs work too), so after a renewal the new thumbprint is bound on the next DSC apply. **This is the standard renewal path.**
2. **Scheduled task on the broker** that runs `Set-RDCertificate` weekly (only if you'd rather not re-run a deploy for each renewal).

### LetsEncrypt (90-day DV cert)

Let's Encrypt certs last 90 days, so renew on a schedule:

1. **Re-run** [`scripts/New-LetsEncryptRdsCertificate.ps1`](../scripts/New-LetsEncryptRdsCertificate.ps1) (no new arguments needed — it hydrates from `main.bicepparam`). Posh-ACME renews via the same static challenge CNAME and **re-imports** the new PFX into Key Vault only when the thumbprint changed.
2. **Re-upload to App Proxy** with [`scripts/Configure-AppProxy.ps1`](../scripts/Configure-AppProxy.ps1) (pipe the cert script's output object in for `-PfxPath` / `-PfxPassword`), because the Entra app registration holds its own copy.
3. **Trigger a DSC apply** (re-run the deploy) so RDS binds the new thumbprint internally, exactly as above.

[`tests/Test-PreDeployReadiness.ps1`](../tests/Test-PreDeployReadiness.ps1) runs `az keyvault certificate show` and warns if the active cert expires within 30 days — run it before each deploy to get warned in plenty of time.

---

## Verification (any deploy path)

```powershell
$fqdn = 'rds.contoso.com'  # or your *.cloudapp.azure.com hostname

# 1) DNS resolves end-to-end
Resolve-DnsName $fqdn -Type CNAME    # LB vanity: alias is *.cloudapp.azure.com; App Proxy: *.msappproxy.net
Resolve-DnsName $fqdn                 # final answer: the LB Public IP, or the App Proxy edge

# 2) TLS handshake presents the cert with matching Subject / SAN
$req = [Net.HttpWebRequest]::Create("https://$fqdn/RDWeb/")
try { $req.GetResponse() | Out-Null } catch { }
$cert = [Security.Cryptography.X509Certificates.X509Certificate2]::new($req.ServicePoint.Certificate)
$cert | Format-List Subject, DnsNameList, NotAfter
```

`Subject` and `DnsNameList` should contain `$fqdn`; `NotAfter` should be ≥ 90 days out.

---

## Common gotchas

| Symptom | Cause |
| --- | --- |
| `rds.contoso.com` doesn't resolve | CNAME not yet propagated (give it the TTL you set), or you put the FQDN in the `Name` field instead of just the short name (`rds`, not `rds.contoso.com`). |
| Client gets *"name in the certificate is invalid…"* | Cert Subject / SANs don't include `publicGatewayFqdn`, or `publicGatewayFqdn` wasn't set so the RDP file still embeds the LB hostname. |
| Public CA rejects the CSR with *"domain not authorized"* for `*.cloudapp.azure.com` | Expected — you can't get a public CA cert for a Microsoft-owned domain. Drop the LB FQDN from the SAN list; only include hostnames in domains you control. |
| Broker DSC step fails: *"key not exportable"* | The cert was imported or generated without `exportable: true`. Re-create with `New-RdsCertificate.ps1` (which sets it correctly) or re-issue the PFX. |
| You moved regions and the vanity name now points at the wrong LB | Re-deploy in the new region, then re-run `Set-GatewayCname.ps1`. With TTL 300 you're back in 5 minutes. |
| Can't create CNAME — DNS provider refuses | You're trying to CNAME the zone apex (`contoso.com`). Use a subdomain instead, or an ALIAS / ANAME record on providers that support it. |
| App Proxy: HTML5 web client fails but the native client works | Internal and external FQDN don't match. Both must be `rds.contoso.com`; add the internal split-horizon `A` record (see Tier 2 above). |
| App Proxy: published app shows a certificate error | The uploaded PFX is self-signed, expired, or missing its private key. Use a `LetsEncrypt` / public-CA PFX **with** key, and re-run `Configure-AppProxy.ps1`. |
| `LetsEncrypt`: ACME validation times out | The `acme.<parent>` zone isn't delegated yet (`NS` not propagated), the static `_acme-challenge` CNAME is missing/wrong, or the running identity can't write `TXT` there. Re-check the three one-time records the first run printed. |

---

## Doing it by hand (no orchestrator)

If you can't run Tier 0 at all (rare — broken `gh` CLI, no Entra rights, etc.) and need the cert in Key Vault manually before deploying from a laptop/jumpbox:

- **Manual cert creation in Key Vault** — verbose `az keyvault certificate` recipes for the Key Vault modes (`Csr` / `ImportPfx` / `SelfSigned`): [Manual deploy → Step 3: TLS certificate in Key Vault](./manual-deploy.md#3-create-the-tls-certificate-in-key-vault-only-if-tier-0-did-not).
- **Let's Encrypt + application proxy by hand** — issue the cert and publish the app yourself: [Application proxy](./app-proxy.md).
- **Manual bicepparam editing** of the cert / FQDN block: [Manual deploy → Step 4: edit main.bicepparam](./manual-deploy.md#4-edit-mainbicepparam).
- **Manual CNAME creation** (post-deploy): [Manual deploy → Step 7: post-deployment steps](./manual-deploy.md#7-post-deployment-steps-still-required).
