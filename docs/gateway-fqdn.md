# Choosing your gateway FQDN

[← Back to main README](../README.md)

You have **two options** for the public hostname that RD clients will type into Remote Desktop / RD Web. Pick one **before** generating the TLS certificate, because the cert's Subject/SAN must match exactly.

## Option 1 — Use the Azure-managed LB hostname (lab/dev only)

The Bicep template creates a Standard Public IP with a DNS label, giving you a free, Azure-managed FQDN:

```text
<gatewayDnsLabelPrefix>.<region>.cloudapp.azure.com
# e.g. contoso-rds.westeurope.cloudapp.azure.com
```

This is the value emitted as the `gatewayFqdn` output. To use it, leave `publicGatewayFqdn` empty in `main.bicepparam` and set `certificateSubject` to `'CN=<that hostname>'`. **No DNS records to create.**

> [!WARNING]
> **A public CA will not issue a certificate for `*.cloudapp.azure.com` because you don't own that domain — Microsoft does.** Every public CA enforces Domain Control Validation (HTTP-01, DNS-01 or CAB Forum email), which you cannot pass for someone else's domain. That means with the LB hostname your only practical option is a **self-signed** cert (or one issued by an internal/private CA), and every client will get the *"the identity of this computer cannot be verified"* warning unless you manually push the cert into their Trusted Root store via GPO/Intune.
>
> Use Option 1 only for short-lived labs, internal demos, or pipelines where you can pre-trust the cert. **For anything user-facing, use Option 2.**

Other trade-offs: the hostname exposes that it's running in Azure (`*.cloudapp.azure.com`), and you can't move the farm to a different region/PIP without all your users having to learn a new URL.

## Option 2 — Use a vanity CNAME under your own domain (recommended for production)

You expose a friendly name like `rds.contoso.com` that you control. Users always connect to `rds.contoso.com`, while the underlying Azure LB FQDN can change.

### Step A. Pick the hostname

It **must be a subdomain**, not the zone apex (`contoso.com` itself). DNS standards forbid a CNAME at the apex; if you really need `contoso.com`, use an ALIAS/ANAME record (supported by Azure DNS, Cloudflare, Route 53) instead of a CNAME — see the gotchas below.

Common choices:

- `rds.contoso.com`
- `remote.contoso.com`
- `desktop.contoso.com`

### Step B. Create the CNAME after the first deploy (you need `gatewayFqdn`)

The Bicep deploy outputs `gatewayFqdn` — this is the target of your CNAME. **Deploy once first** to get it, then create the DNS record:

```powershell
# 1) Grab the LB FQDN from deploy outputs
$target = az deployment group show -g rds-farm-rg -n main `
  --query properties.outputs.gatewayFqdn.value -o tsv
# e.g. contoso-rds.westeurope.cloudapp.azure.com

# 2a) If your zone is in Azure DNS:
az network dns record-set cname set-record `
  --resource-group dns-rg `
  --zone-name contoso.com `
  --record-set-name rds `
  --cname $target `
  --ttl 300

# 2b) If your zone is elsewhere (Cloudflare, GoDaddy, Route 53, etc.),
#     create a CNAME record manually:
#     Name:  rds
#     Type:  CNAME
#     Value: <gatewayFqdn from step 1>
#     TTL:   300  (5 min — keeps you nimble during cutover/rollback)
```

### Step C. Generate the cert with the vanity FQDN as Subject

The cert Subject/SAN **must match what RDP clients type** — which is your vanity FQDN, e.g. `rds.contoso.com`.

```text
Subject: CN=rds.contoso.com
SANs:    rds.contoso.com
```

> [!IMPORTANT]
> **Do not** ask the CA to also include the LB FQDN (`*.cloudapp.azure.com`) in the SAN list — the CA will refuse because Domain Control Validation will fail for a domain you don't own. The CNAME-then-vanity-only model is the correct architecture: the LB hostname is just a DNS lookup target, and TLS validates against the SNI hostname the client sent, which is the vanity name.

A **wildcard cert** like `CN=*.contoso.com` works too and is convenient if you serve multiple RDS farms or other services from the same domain. Just make sure `certificateSubject` in `main.bicepparam` matches its actual subject.

The Option A flow in [Key Vault prep → Step 2a](./key-vault-cert.md#step-2a-option-a--generate-a-csr-in-key-vault-sign-with-a-public-ca-recommended-for-production) shows the exact `az keyvault certificate create` policy.

### Step D. Update your bicepparam

Two template parameters relate to the vanity hostname:

```bicep
// The public hostname clients type. Wired into RD Gateway's GatewayExternalFqdn
// so the embedded RDP file, SNI handshake, and broker reconnects all use this name.
param publicGatewayFqdn = 'rds.contoso.com'

// Subject used by the broker DSC to locate the cert in LocalMachine\My.
// Must match the cert's actual Subject (or a substring of it).
param certificateSubject = 'CN=rds.contoso.com'
```

Leave `gatewayDnsLabelPrefix` as-is — the LB FQDN is still the **physical target** of the CNAME, but it never appears to users or in any TLS handshake.

The `rdWebUrl` output will automatically use `publicGatewayFqdn` when you set it, so the deploy log shows the right URL to share with users.

## Verification

```powershell
$fqdn = 'rds.contoso.com'

# 1) CNAME resolves to the LB FQDN, which resolves to the Public IP
Resolve-DnsName $fqdn -Type CNAME
Resolve-DnsName $fqdn   # final answer should be the Standard Public IP from your RG

# 2) TLS handshake presents the cert with matching Subject/SAN
$req = [Net.HttpWebRequest]::Create("https://$fqdn/RDWeb/")
try { $req.GetResponse() | Out-Null } catch { }
$cert = [Security.Cryptography.X509Certificates.X509Certificate2]::new($req.ServicePoint.Certificate)
$cert | Format-List Subject, DnsNameList, NotAfter
```

## Common gotchas

| Symptom | Cause |
| --- | --- |
| `rds.contoso.com` doesn't resolve | CNAME not yet propagated (give it the TTL you set), or you put the FQDN in the `Name` field instead of just the short name (`rds`, not `rds.contoso.com`). |
| Client gets *"name in the certificate is invalid…"* | Cert Subject/SANs don't include the vanity FQDN, or you forgot to set `publicGatewayFqdn` so the RDP file still embeds the LB hostname. |
| Can't create CNAME — DNS provider refuses | You're trying to CNAME the zone apex (`contoso.com`). Use a subdomain instead, or an ALIAS/ANAME record on providers that support it. |
| Public CA rejects the CSR with *"domain not authorized"* for `*.cloudapp.azure.com` | Expected — you can't get a public CA cert for a Microsoft-owned domain. Drop the LB FQDN from the SAN list; only include hostnames in domains you control. |
| You moved regions and the vanity name now points at the wrong LB | Re-deploy in the new region, then `az network dns record-set cname set-record` with the new target. With TTL 300 you're back in 5 minutes. |
