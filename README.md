# RDS Farm on Azure (Bicep + DSC)

Modernized Bicep deployment for a Microsoft Remote Desktop Services (RDS) farm joined to an **existing** Active Directory domain.

This template replaces the legacy [`Azure/RDS-Templates`](https://github.com/Azure/RDS-Templates) and [`azure-quickstart-templates/.../rds-deployment-existing-ad`](https://github.com/Azure/azure-quickstart-templates/tree/master/application-workloads/rds/rds-deployment-existing-ad) samples, which use retired Basic-SKU networking and (in the quickstart case) directly expose Gateway and Broker VMs to the internet.

## What it deploys

| Component | Count | Network exposure |
| --- | --- | --- |
| Public IP (Standard, zone-redundant) | 1 | Internet → LB only |
| Standard Load Balancer | 1 | TCP 443, UDP 3391 → Gateway pool |
| RD Gateway / RD Web Access VM | 1 | Private IP, joined to LB backend |
| RD Connection Broker / RD Licensing VM | 1 | Private only |
| RD Session Host VMs | `sessionHostCount` (default 2) | Private only |
| Network Security Group | 1 | Allow-list source CIDRs |
| Azure Bastion (Standard) | 1 (optional) | Admin access only |
| User-assigned Managed Identity (cert flow) | 1 (optional) | KV Secrets User |

All VMs use **Trusted Launch**, **Premium SSD managed disks**, **AutomaticByPlatform patching**, and **availability zones**. RDS roles are installed and configured by **PowerShell DSC** (`dsc/Configuration.ps1`). TLS certificates can optionally be pulled from **Azure Key Vault** via the Key Vault VM extension and bound to all four RDS roles automatically.

## What's automated end-to-end

From a clean pipeline run, the following is done **without any manual step on the VMs** before the test user can sign in to RD Web:

| # | Step | Where it runs | How |
| --- | --- | --- | --- |
| 1 | Provision NSG, LB, Public IP, NICs, VMs (Trusted Launch) | ARM control plane | Bicep |
| 2 | Set NIC DNS → your existing DC IP (`adDnsServerIp`) | VM NIC | Bicep (`dnsSettings.dnsServers`) |
| 3 | **Domain-join every VM** to your existing Azure-hosted DC | VM | `JsonADDomainExtension` v1.3 (`Options: 3`) |
| 4 | Install RDS roles (`RDS-Gateway`, `RDS-Web-Access`, `RPC-over-HTTP-Proxy`, `RDS-Connection-Broker`, `RDS-Licensing`, `RDS-RD-Server`, RSAT) | VM | DSC `WindowsFeature` resources |
| 5 | `New-RDSessionDeployment` (broker + web access + session hosts) | Broker | DSC `Script CreateRDSDeployment` |
| 6 | `Add-RDServer -Role RDS-GATEWAY -GatewayExternalFqdn <LB FQDN>` | Broker | same script |
| 7 | `Add-RDServer -Role RDS-LICENSING` + `Set-RDLicenseConfiguration -Mode PerUser` (120-day grace) | Broker | same script |
| 8 | `Set-RDDeploymentGatewayConfiguration` — force traffic through gateway, cache RD Web creds | Broker | same script |
| 9 | `New-RDSessionCollection` (default `DesktopCollection`) | Broker | same script |
| 10 | `Set-RDSessionCollectionConfiguration -UserGroup <netbios>\<rdsAccessGroup>` | Broker | same script |
| 11 | **Create default RD CAP + RAP scoped to `rdsAccessGroup`** so the gateway actually accepts sessions | Gateway | DSC `Script ConfigureRDGatewayPolicies` (uses `RDS:\GatewayServer` PSDrive) |
| 12 | Optional: pull TLS cert from Key Vault → `Set-RDCertificate` for all 4 roles | Broker | KV VM extension + DSC `Script BindRDSCertificates` |

After step 12 returns success, opening `https://<gatewayFqdn>/RDWeb/` from a client in an allow-listed CIDR and signing in as any member of `rdsAccessGroup` returns the `DesktopCollection` desktop. No further VM-side configuration is required.

### Still manual (by design or constraint)

| Item | Why it's not in the template |
| --- | --- |
| **Create the test user / AD group in your DC** | This template never writes to AD; the customer's DC is the source of truth. Either use the default `Domain Users` (`rdsAccessGroup`) or pre-create a group like `RDS-Users` and add your test user. |
| Adding the broker computer object to AD group `Terminal Server License Servers` | Requires Domain Admin; outside the rights granted to the domain-join service account. Without it the deployment runs in the **120-day grace period** (fine for a test user); after that you need real RDS CALs and the AD group membership. |
| Public DNS CNAME from your vanity hostname → `<gatewayFqdn>` | Customer-owned DNS zone. See [Choosing your gateway FQDN](#choosing-your-gateway-fqdn) for the full walkthrough. |
| Buying/issuing the TLS cert | Provided via Key Vault; the template only binds it. |

## Architecture

```text
                  Internet (allow-listed CIDRs only)
                            │
                            ▼
              Standard Public IP (zonal)
                            │
                            ▼
              Standard Load Balancer
              (TCP 443, UDP 3391)
                            │
        ┌───────────────────┴───────────────────┐
        ▼                                       ▼
   RD Gateway VM                       (back-end pool)
   + RD Web Access
        │
        │ private
        ▼
   RD Connection Broker VM ──── RD Session Host VMs
   + RD Licensing                (1..n, spread across zones)
        │
        ▼
   Existing AD DS (in customer VNet)
```

## Repository layout

```text
rds-farm/
├── README.md                   # this file
├── main.bicep                  # entry point
├── main.bicepparam             # environment values
├── dsc/
│   └── Configuration.ps1       # SessionHost / Gateway / RDSDeployment configs
└── modules/
    ├── network.bicep           # NSG + existing subnet lookup
    ├── loadbalancer.bicep      # Standard PIP + LB
    ├── bastion.bicep           # optional Azure Bastion (Standard)
    ├── vm.bicep                # VM + NIC + domain-join + (optional) KV ext
    ├── dsc.bicep               # DSC extension wrapper
    ├── identity.bicep          # user-assigned MSI for cert flow
    └── kv-role.bicep           # role assignment on existing Key Vault
```

## Prerequisites

| Item | Notes |
| --- | --- |
| Existing VNet + subnet | Subnet must be able to reach your DCs (DNS, LDAP, Kerberos, SMB). |
| Existing AD DS | On-prem or Azure-hosted DCs reachable from the subnet. |
| Domain-join service account | Member of an OU with delegated rights to join machines. |
| `AzureBastionSubnet` | Required only if `deployBastion = true`. Minimum /26. |
| Azure CLI ≥ 2.60 + Bicep ≥ 0.27 | `az bicep upgrade` if needed. |
| Storage account for DSC artifacts | Blob container (e.g., `dsc`) that holds `Configuration.zip`. |
| RDS CALs | Not provisioned by this template. The deployment uses the 120-day Per-User grace period; install real CALs on the broker post-deploy. |
| TLS certificate (optional) | In Key Vault with **`exportable: true`** in the policy. |
| **Test AD user/group** | Must exist in your AD. By default any `Domain Users` member can sign in; override with `rdsAccessGroup` (e.g. `RDS-Users`). |

## Parameters reference

All parameters are defined in [`main.bicep`](main.bicep). The most relevant ones:

| Parameter | Required | Description |
| --- | --- | --- |
| `existingVnetName`, `existingVnetResourceGroup`, `existingRdsSubnetName` | yes | Target VNet/subnet (can be in another RG). |
| `adDomainName` | yes | FQDN of the existing AD domain, e.g. `contoso.local`. |
| `adDnsServerIp` | yes | Private IP of an AD DNS server reachable from the subnet. |
| `domainJoinUserName`, `domainJoinPassword` | yes | Credentials for domain join (and the RDS deployment Script). |
| `localAdminUserName`, `localAdminPassword` | yes | Local admin on every VM. |
| `sessionHostCount` | no (default 2) | 1–20 RDSH VMs, spread across `availabilityZones`. |
| `vmSize` | no (`Standard_D4s_v5`) | Used for every RDS VM. |
| `windowsSku` | no (`2022-datacenter-azure-edition`) | Azure Edition recommended (hotpatch capable). |
| `allowedClientSourceAddressPrefixes` | yes | CIDRs allowed to reach 443/UDP 3391. **Do not use `0.0.0.0/0`.** |
| `gatewayDnsLabelPrefix` | yes | Becomes `<prefix>.<region>.cloudapp.azure.com`. |
| `deployBastion` | no (true) | Set false if you already have Bastion in a hub VNet. |
| `availabilityZones` | no (`['1','2','3']`) | Reduce if the region has fewer zones. |
| `artifactsLocation` | yes | Base URL of the blob container that holds `Configuration.zip`. Must end with `/`. |
| `artifactsLocationSasToken` | when artifacts container is private | SAS token including the leading `?`. |
| `sessionHostNamingPrefix` | no (`rds-sh-`) | Must match what the broker DSC uses to compute FQDNs. |
| `collectionName` | no | RDS session collection name. |
| `rdsAccessGroup` | no (`Domain Users`) | sAMAccountName of the AD security group whose members can sign in to the collection and through the RD Gateway (used for both `Set-RDSessionCollectionConfiguration -UserGroup` and the RD CAP/RAP). |
| `enableCertificateBinding` | no (false) | Enables the KV → cert binding flow below. |
| `keyVaultName`, `keyVaultResourceGroup` | only if cert binding | Existing vault. |
| `keyVaultCertSecretUri` | only if cert binding | `https://<vault>.vault.azure.net/secrets/<cert>`. |
| `publicGatewayFqdn` | only if cert binding (recommended) | Public hostname clients type. Wired into RD Gateway's `GatewayExternalFqdn` and the `rdWebUrl` output. Leave empty to use the LB FQDN (lab/dev only — see [Choosing your gateway FQDN](#choosing-your-gateway-fqdn)). |
| `certificateSubject` | only if cert binding | Subject substring to locate the cert (e.g. `CN=rdsgw.contoso.com`). |

## Choosing your gateway FQDN

You have **two options** for the public hostname that RD clients will type into Remote Desktop / RD Web. Pick one **before** generating the TLS certificate, because the cert's Subject/SAN must match exactly.

### Option 1 — Use the Azure-managed LB hostname (lab/dev only)

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

### Option 2 — Use a vanity CNAME under your own domain (recommended for production)

You expose a friendly name like `rds.contoso.com` that you control. Users always connect to `rds.contoso.com`, while the underlying Azure LB FQDN can change.

#### Step A. Pick the hostname

It **must be a subdomain**, not the zone apex (`contoso.com` itself). DNS standards forbid a CNAME at the apex; if you really need `contoso.com`, use an ALIAS/ANAME record (supported by Azure DNS, Cloudflare, Route 53) instead of a CNAME — see the gotchas below.

Common choices:

- `rds.contoso.com`
- `remote.contoso.com`
- `desktop.contoso.com`

#### Step B. Create the CNAME after the first deploy (you need `gatewayFqdn`)

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

#### Step C. Generate the cert with the vanity FQDN as Subject

The cert Subject/SAN **must match what RDP clients type** — which is your vanity FQDN, e.g. `rds.contoso.com`.

```text
Subject: CN=rds.contoso.com
SANs:    rds.contoso.com
```

> [!IMPORTANT]
> **Do not** ask the CA to also include the LB FQDN (`*.cloudapp.azure.com`) in the SAN list — the CA will refuse because Domain Control Validation will fail for a domain you don't own. The CNAME-then-vanity-only model is the correct architecture: the LB hostname is just a DNS lookup target, and TLS validates against the SNI hostname the client sent, which is the vanity name.

A **wildcard cert** like `CN=*.contoso.com` works too and is convenient if you serve multiple RDS farms or other services from the same domain. Just make sure `certificateSubject` in `main.bicepparam` matches its actual subject.

The Option A flow in **Key Vault prep → Step 2a** (below) already shows this.

#### Step D. Update your bicepparam

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

### Verification

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

### Common gotchas

| Symptom | Cause |
| --- | --- |
| `rds.contoso.com` doesn't resolve | CNAME not yet propagated (give it the TTL you set), or you put the FQDN in the `Name` field instead of just the short name (`rds`, not `rds.contoso.com`). |
| Client gets *"name in the certificate is invalid…"* | Cert Subject/SANs don't include the vanity FQDN, or you forgot to set `publicGatewayFqdn` so the RDP file still embeds the LB hostname. |
| Can't create CNAME — DNS provider refuses | You're trying to CNAME the zone apex (`contoso.com`). Use a subdomain instead, or an ALIAS/ANAME record on providers that support it. |
| Public CA rejects the CSR with *"domain not authorized"* for `*.cloudapp.azure.com` | Expected — you can't get a public CA cert for a Microsoft-owned domain. Drop the LB FQDN from the SAN list; only include hostnames in domains you control. |
| You moved regions and the vanity name now points at the wrong LB | Re-deploy in the new region, then `az network dns record-set cname set-record` with the new target. With TTL 300 you're back in 5 minutes. |

## Key Vault prep (only if `enableCertificateBinding = true`)

### What kind of certificate do I need?

RDS uses the **same** TLS cert for all four roles (`RDGateway`, `RDWebAccess`, `RDPublishing`, `RDRedirector`), so you need **one** certificate that meets all of these:

| Requirement | Why | What to set |
| --- | --- | --- |
| Issued by a **publicly trusted CA** | The cert is presented to remote users connecting from outside your network; their machines won't trust a private/internal CA. | Buy from DigiCert/Sectigo/GoDaddy, get a free one from Let's Encrypt, or use any CA your organization already has integrated with Key Vault. **Self-signed certs only work for lab testing** (see [Option 1](#option-1--use-the-azure-managed-lb-hostname-labdev-only) above). Public CAs **will not issue** a cert for `*.cloudapp.azure.com` — use a hostname in a domain you own (see [Option 2](#option-2--use-a-vanity-cname-under-your-own-domain-recommended-for-production)). |
| **Subject CN or SAN** matches the public FQDN of your gateway | RDP client validates the hostname against the cert. Any mismatch → "*The remote computer could not be authenticated due to problems with its security certificate*". | Set this to whatever you put in `publicGatewayFqdn` — e.g. `rds.contoso.com`, or `*.contoso.com` for a wildcard. Match `certificateSubject` to the cert's actual Subject string. |
| **Key type RSA 2048+** (or ECC P-256) | Required by Schannel / RD Gateway. RSA 4096 is fine, RSA 1024 is not. | `key_props.key_type = 'RSA'`, `key_size = 2048`. |
| **Enhanced Key Usage = Server Authentication** (OID `1.3.6.1.5.5.7.3.1`) | RDS rejects certs without it (you'd see error 0x80092004 in the EventLog). | Default for any TLS cert; explicit in JSON: `"ekus": ["1.3.6.1.5.5.7.3.1"]`. |
| **`exportable: true`** in the KV cert policy | The broker DSC step exports a temporary PFX to call `Set-RDCertificate -ImportPath`. A non-exportable cert pulled by the KV VM extension cannot be re-exported, even by `LocalSystem`. | `key_props.exportable = true`. **This is the most common gotcha.** |
| **Includes the private key** | `Set-RDCertificate` needs the private key to install on the other RDS servers. | KV-generated certs always include it; if you import a `.pfx`, use the form with the private key (not `.cer`). |
| **Valid for at least 90 days** | RDS doesn't auto-rotate; you want headroom before re-running the deployment. | KV default is 12 months. |

> [!IMPORTANT]
> A **wildcard cert (`CN=*.contoso.com`)** also works and is convenient if you serve multiple RDS farms from the same domain — just make sure `certificateSubject` in `main.bicepparam` matches its subject (e.g. `CN=*.contoso.com`).

### Step 1. Make sure the vault uses RBAC, not access policies

The `kv-role.bicep` module assigns the built-in role `Key Vault Secrets User` (`4633458b-17de-408a-b874-0445c86b69e6`) to the user-assigned identity. This **only works on RBAC-mode vaults**.

```powershell
# Verify
az keyvault show -n contoso-rds-kv --query "properties.enableRbacAuthorization" -o tsv
# Expected: true

# If false, switch (warning: this disables all existing access policies)
az keyvault update -n contoso-rds-kv --enable-rbac-authorization true
```

You'll also need **Key Vault Certificates Officer** (or higher) on your own user to create/import the cert below:

```powershell
$me = az ad signed-in-user show --query id -o tsv
az role assignment create `
  --assignee $me `
  --role 'Key Vault Certificates Officer' `
  --scope (az keyvault show -n contoso-rds-kv --query id -o tsv)
```

### Step 2a. Option A — Generate a CSR in Key Vault, sign with a public CA (recommended for production)

This keeps the private key inside Key Vault and you never see it. Works with any public CA that accepts a CSR.

```powershell
$vault    = 'contoso-rds-kv'
$certName = 'rds-tls'
$fqdn     = 'rds.contoso.com'   # your vanity gateway FQDN (matches publicGatewayFqdn)

# 1) Build an exportable policy with the right subject/SAN/EKU
$policy = az keyvault certificate get-default-policy | ConvertFrom-Json
$policy.key_props.exportable        = $true
$policy.key_props.key_type          = 'RSA'
$policy.key_props.key_size          = 2048
$policy.key_props.reuse_key         = $false
$policy.x509_props.subject          = "CN=$fqdn"
$policy.x509_props.sans             = @{ dns_names = @($fqdn); emails = @(); upns = @() }
$policy.x509_props.ekus             = @('1.3.6.1.5.5.7.3.1')                # Server Authentication
$policy.x509_props.validity_in_months = 12
$policy.issuer_parameters.name      = 'Unknown'                            # 'Unknown' = manual CSR; replace with 'DigiCert' / 'GlobalSign' if you have a KV-integrated CA account

$policy | ConvertTo-Json -Depth 10 | Out-File policy.json -Encoding utf8

# 2) Start the cert operation (this creates a pending cert + CSR)
az keyvault certificate create --vault-name $vault --name $certName --policy `@policy.json

# 3) Export the CSR and send it to your CA
$csr = az keyvault certificate pending show --vault-name $vault --name $certName --query csr -o tsv
@"
-----BEGIN CERTIFICATE REQUEST-----
$csr
-----END CERTIFICATE REQUEST-----
"@ | Out-File rds.csr -Encoding ascii

# ... submit rds.csr to your CA, download the issued cert as rds.cer ...

# 4) Merge the signed cert back into Key Vault (private key never leaves the vault)
az keyvault certificate pending merge --vault-name $vault --name $certName --file rds.cer
```

### Step 2b. Option B — Import an existing PFX (you already bought/issued the cert)

Use this if your security team already has a `.pfx` from your enterprise CA or a public CA.

```powershell
$vault    = 'contoso-rds-kv'
$certName = 'rds-tls'
$pfxPath  = 'C:\certs\rds-contoso-com.pfx'
$pfxPwd   = Read-Host 'PFX password' -AsSecureString
$pfxPwdPlain = [System.Net.NetworkCredential]::new('', $pfxPwd).Password

az keyvault certificate import `
  --vault-name $vault `
  --name       $certName `
  --file       $pfxPath `
  --password   $pfxPwdPlain

$pfxPwdPlain = $null   # remove plaintext from memory ASAP

# Confirm it's exportable (CLI shows it as part of the policy)
az keyvault certificate show-policy --vault-name $vault --name $certName `
  --query "key_props.exportable" -o tsv
# Must print: true
```

> [!WARNING]
> If your `.pfx` was generated with the private key flagged non-exportable (e.g. created on a Windows machine with `-KeyExportPolicy NonExportable`), Key Vault will store it but the broker DSC step will fail to re-export. Re-issue the cert with exportable key material before importing.

### Step 2c. Option C — Lab/test only: self-signed via Key Vault

Useful to verify the end-to-end binding flow before paying for a real cert. **Clients will see a trust warning** and must click through it.

```powershell
$vault    = 'contoso-rds-kv'
$certName = 'rds-tls-selfsigned'
$fqdn     = 'contoso-rds.westeurope.cloudapp.azure.com'   # match exactly what RD clients connect to

$policy = az keyvault certificate get-default-policy | ConvertFrom-Json
$policy.key_props.exportable           = $true
$policy.x509_props.subject             = "CN=$fqdn"
$policy.x509_props.sans                = @{ dns_names = @($fqdn); emails = @(); upns = @() }
$policy.issuer_parameters.name         = 'Self'
$policy.x509_props.validity_in_months  = 12
$policy | ConvertTo-Json -Depth 10 | Out-File policy.json -Encoding utf8

az keyvault certificate create --vault-name $vault --name $certName --policy `@policy.json
```

### Step 3. Get the secret URI and put it in `main.bicepparam`

The KV VM extension and `Set-RDCertificate` need the **secret** URI (not the certificate URI):

```powershell
$secretUri = az keyvault certificate show --vault-name $vault --name $certName `
  --query 'sid' -o tsv
# Returns: https://contoso-rds-kv.vault.azure.net/secrets/rds-tls/<version>

# Strip the version so KV always serves the current cert at deploy time
$secretUri = ($secretUri -split '/')[0..4] -join '/'
$secretUri
# https://contoso-rds-kv.vault.azure.net/secrets/rds-tls
```

Then in [`main.bicepparam`](main.bicepparam):

```bicep
param enableCertificateBinding = true
param keyVaultName             = 'contoso-rds-kv'
param keyVaultResourceGroup    = 'security-rg'
param keyVaultCertSecretUri    = 'https://contoso-rds-kv.vault.azure.net/secrets/rds-tls'
param publicGatewayFqdn        = 'rds.contoso.com'       // vanity FQDN users type (CNAME → gatewayFqdn)
param certificateSubject       = 'CN=rds.contoso.com'   // must be a substring of the cert's actual Subject
```

That's all you need. On deploy, the user-assigned MI gets `Key Vault Secrets User` on the vault (via `kv-role.bicep`), the **Key Vault VM extension** on every RDS VM polls `keyVaultCertSecretUri` every hour and installs the cert into `LocalMachine\My` with its private key intact, and the broker DSC's `BindRDSCertificates` finds it by `certificateSubject` and binds it to all four RDS roles.

### Certificate renewal

The Key Vault VM extension keeps the **OS cert store** in sync automatically (within the polling interval, default 1 h). However, `Set-RDCertificate` is **only re-run during DSC apply**, so RDS will keep pointing at the old cert thumbprint until you either:

- **Re-run the pipeline** (`workflow_dispatch → deploy`) — the DSC `BindRDSCertificates.TestScript` only matches `Level=Trusted` certs by subject, so after a renewal the new thumbprint gets bound on the next DSC apply, **or**
- **Add a scheduled task on the broker** that runs the same `Set-RDCertificate` block weekly.

## Deployment

### 1. Package and upload DSC artifacts

```powershell
cd C:\Users\jozoslejko\OneDrive\Dev\rds-farm\dsc
Compress-Archive -Path .\Configuration.ps1 -DestinationPath .\Configuration.zip -Force

# Upload to your artifacts storage account
$sa  = 'contosoartifactssa'
$ctx = New-AzStorageContext -StorageAccountName $sa -UseConnectedAccount
Set-AzStorageBlobContent `
  -File .\Configuration.zip `
  -Container 'dsc' -Blob 'Configuration.zip' `
  -Context $ctx -Force

# Generate a short-lived read-only SAS (2 hours)
$sas = New-AzStorageBlobSASToken `
  -Container 'dsc' -Blob 'Configuration.zip' `
  -Permission r -ExpiryTime (Get-Date).AddHours(2) `
  -Context $ctx
"?$sas"
```

### 2. Set secrets in your shell

```powershell
$env:DOMAIN_JOIN_PASSWORD = '<svc-domainjoin password>'
$env:LOCAL_ADMIN_PASSWORD = '<local admin password>'
$env:ARTIFACTS_SAS         = '?sv=...'   # paste the SAS from step 1, or '' if container is public
```

### 3. Edit `main.bicepparam`

Set at minimum:

- `existingVnetName`, `existingVnetResourceGroup`, `existingRdsSubnetName`
- `adDomainName`, `adDnsServerIp`
- `allowedClientSourceAddressPrefixes` (your office/VPN egress IPs only)
- `gatewayDnsLabelPrefix` (must be globally unique in the region)
- `artifactsLocation` (e.g. `https://contosoartifactssa.blob.core.windows.net/dsc/`)
- If using certs: `enableCertificateBinding`, `keyVaultName`, `keyVaultResourceGroup`, `keyVaultCertSecretUri`, `publicGatewayFqdn`, `certificateSubject`

### 4. Deploy

```powershell
cd C:\Users\jozoslejko\OneDrive\Dev\rds-farm

az group create -n rds-farm-rg -l westeurope

# Preview changes
az deployment group what-if -g rds-farm-rg --parameters main.bicepparam

# Apply
az deployment group create  -g rds-farm-rg --parameters main.bicepparam
```

Typical wall-clock time on `Standard_D4s_v5`: **25–40 minutes** (VM provisioning + domain join reboot + DSC role install + RDS deployment).

### 5. Verify

```powershell
$dep = az deployment group show -g rds-farm-rg -n main --query properties.outputs -o json | ConvertFrom-Json
$dep.rdWebUrl.value         # e.g. https://contoso-rds.westeurope.cloudapp.azure.com/RDWeb
$dep.gatewayFqdn.value
```

Open the `rdWebUrl` from a client in one of the allow-listed CIDRs. Sign in with a domain user; you should see the `DesktopCollection` resource.

## Post-deployment steps still required

1. **Public DNS.** If you're using a vanity hostname like `rds.contoso.com`, create the CNAME and verify per [Choosing your gateway FQDN → Option 2](#option-2--use-a-vanity-cname-under-your-own-domain-recommended-for-production). Make sure the cert Subject/SAN matches the FQDN your users actually type.
2. **RDS CALs.** Install on the broker (`RD Licensing Manager → Activate Server`), and ensure the broker computer object is a member of the `Terminal Server License Servers` group in AD.
3. **Cert renewal.** The Key Vault VM extension re-polls every `pollingIntervalInS` (1 h by default), but **`Set-RDCertificate` is only run during DSC apply**. For rotation, either:
   - Re-run the deployment when KV cert version changes, or
   - Add a scheduled task on the broker that runs the same `Set-RDCertificate` block.
4. **Published apps.** This template provisions a full desktop collection. For RemoteApp:

   ```powershell
   New-RDRemoteApp -Alias notepad -DisplayName 'Notepad' `
     -FilePath 'C:\Windows\System32\notepad.exe' `
     -CollectionName 'DesktopCollection' `
     -ConnectionBroker 'rds-cb-01.contoso.local'
   ```

## Testing & verification

A staged set of checks: **(1)** template sanity before you deploy, **(2)** Azure-side smoke tests right after `az deployment group create` returns, **(3)** RDS-role checks on the VMs themselves, and **(4)** end-to-end client connection. Run them in order — most "RD Web won't open" tickets are caught by checks 2 or 3.

### 1. Pre-deployment (no resources touched)

```powershell
# a) Template compiles
az bicep build --file main.bicep
az bicep build-params --file main.bicepparam

# b) DSC script parses (PowerShell 5.1 syntax, Windows runner or pwsh)
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
  '.\dsc\Configuration.ps1', [ref]$null, [ref]$errors) | Out-Null
if ($errors) { $errors; throw 'DSC parse errors' } else { 'DSC OK' }

# c) Dry-run the deployment (shows resource diffs without applying)
az deployment group what-if `
  -g rds-farm-rg `
  --template-file main.bicep `
  --parameters main.bicepparam `
  --parameters artifactsLocation="https://<storage>.blob.core.windows.net/dsc/"
```

What to look for in `what-if`:

- `+ Create` for every VM, NIC, LB, PIP, NSG you expect (no `Modify`/`Delete` on existing AD or VNet resources).
- The Key Vault role assignment shows as `+ Create` in the **vault's** resource group (cross-RG).
- No surprise `Modify` on `Microsoft.Compute/virtualMachines/extensions` for unrelated VMs.

### 2. Post-deployment Azure-side smoke tests

Run these immediately after `az deployment group create` returns success.

```powershell
$rg = 'rds-farm-rg'

# a) All VM extensions provisioned successfully
az vm extension list --ids $(az vm list -g $rg --query "[].id" -o tsv) `
  --query "[].{vm:name, ext:name, state:provisioningState}" -o table
# Every row must be 'Succeeded'. 'Creating' = still running, 'Failed' = look at instance view below.

# b) Detailed extension status for any failure
az vm get-instance-view -g $rg -n rds-gw-01 `
  --query "instanceView.extensions[].{name:name, status:statuses[1].displayStatus, msg:statuses[1].message}" -o yaml

# c) Load Balancer backend health (gateway must be 'Up')
$lbName = az network lb list -g $rg --query "[0].name" -o tsv
az network lb show -g $rg -n $lbName `
  --query "backendAddressPools[0].loadBalancerBackendAddresses[].{name:name, ip:ipAddress}" -o table
az rest --method get `
  --uri "https://management.azure.com$(az network lb show -g $rg -n $lbName --query id -o tsv)/backendHealth?api-version=2024-05-01"

# d) Key Vault role assignment exists (only if enableCertificateBinding = true)
$uami = az identity show -g $rg -n rds-kv-reader --query principalId -o tsv
az role assignment list --assignee $uami --all `
  --query "[?roleDefinitionName=='Key Vault Secrets User'].{scope:scope, role:roleDefinitionName}" -o table

# e) Resource Health for every VM
az vm list -g $rg --query "[].name" -o tsv | ForEach-Object {
  $h = az rest --method get --uri "https://management.azure.com$(az vm show -g $rg -n $_ --query id -o tsv)/providers/Microsoft.ResourceHealth/availabilityStatuses/current?api-version=2023-07-01" -o json | ConvertFrom-Json
  [pscustomobject]@{ VM = $_; Health = $h.properties.availabilityState }
}
```

### 3. Inside-the-VM RDS role checks

Open a Bastion session (or RDP via jumpbox) to the **broker** and run:

```powershell
# a) All RDS roles installed and registered with the deployment
Get-RDServer -ConnectionBroker rds-cb-01.contoso.local | Format-Table Server, Roles -AutoSize
# Expected roles: RDS-CONNECTION-BROKER, RDS-GATEWAY, RDS-WEB-ACCESS, RDS-LICENSING, RDS-RD-SERVER

# b) Session collection exists and has at least one session host
Get-RDSessionCollection -ConnectionBroker rds-cb-01.contoso.local
Get-RDSessionHost      -CollectionName DesktopCollection -ConnectionBroker rds-cb-01.contoso.local

# c) Licensing mode set (must NOT be 'NotConfigured')
Get-RDLicenseConfiguration -ConnectionBroker rds-cb-01.contoso.local

# d) All four certificate roles bound and trusted
Get-RDCertificate -ConnectionBroker rds-cb-01.contoso.local |
  Select-Object Role, Level, Subject, Thumbprint, NotAfter | Format-Table -AutoSize
# Each of RDGateway, RDWebAccess, RDPublishing, RDRedirector must show Level = 'Trusted'.

# e) DSC last status (on each VM)
Get-DscConfigurationStatus | Format-List Status, StartDate, NumberOfResources, Type
```

On the **gateway** VM:

```powershell
# Gateway listener is up on 443
Test-NetConnection -ComputerName localhost -Port 443
Get-WebBinding -Name 'Default Web Site'

# UDP transport listening on 3391
Get-NetUDPEndpoint -LocalPort 3391
```

### 4. End-to-end client connectivity

From a workstation in one of the allow-listed CIDRs:

```powershell
$fqdn = (az deployment group show -g rds-farm-rg -n main `
  --query properties.outputs.gatewayFqdn.value -o tsv)

# a) Public DNS resolves and TCP 443 reachable
Resolve-DnsName $fqdn
Test-NetConnection -ComputerName $fqdn -Port 443        # TcpTestSucceeded : True

# b) UDP 3391 reachable (improves session perf, not strictly required)
Test-NetConnection -ComputerName $fqdn -Port 3391 -InformationLevel Detailed

# c) Certificate chain validates and matches FQDN
$req = [Net.HttpWebRequest]::Create("https://$fqdn/RDWeb/")
try { $req.GetResponse() | Out-Null } catch { }
$cert = [Security.Cryptography.X509Certificates.X509Certificate2]::new($req.ServicePoint.Certificate)
$cert | Format-List Subject, Issuer, NotAfter, Thumbprint

# d) RD Web sign-in page returns 200
Invoke-WebRequest "https://$fqdn/RDWeb/Pages/en-US/login.aspx" -UseBasicParsing |
  Select-Object StatusCode, StatusDescription
```

Finally, launch **Remote Desktop Connection**, set **Advanced → Connect from anywhere → `$fqdn`**, and connect to one of the session hosts. You should land in a desktop session within ~15 s.

### 5. Continuous testing (recommended additions to CI)

The `deploy.yml` workflow already runs `bicep build` + `what-if` on every PR. For a deeper safety net, add a job that runs **after** the `deploy` job on `main`:

```yaml
post-deploy-tests:
  needs: deploy
  runs-on: ubuntu-latest
  environment: production
  steps:
    - uses: azure/login@v3
      with:
        client-id: ${{ secrets.AZURE_CLIENT_ID }}
        tenant-id: ${{ secrets.AZURE_TENANT_ID }}
        subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

    - name: All extensions Succeeded
      run: |
        set -euo pipefail
        BAD=$(az vm extension list \
          --ids $(az vm list -g "$AZURE_RESOURCE_GROUP" --query "[].id" -o tsv) \
          --query "[?provisioningState!='Succeeded'].{vm:id, ext:name, state:provisioningState}" -o json)
        if [ "$BAD" != "[]" ]; then echo "$BAD"; exit 1; fi

    - name: RD Web reachable
      run: |
        FQDN=$(az deployment group show -g "$AZURE_RESOURCE_GROUP" -n main \
          --query properties.outputs.gatewayFqdn.value -o tsv)
        curl -sS -o /dev/null -w '%{http_code}\n' "https://$FQDN/RDWeb/" | grep -q '^200$'
```

For pull requests against `main`, the `what-if` job is the test gate; no live RDS environment is changed.

## Common issues

| Symptom | Cause / fix |
| --- | --- |
| DSC extension fails with `Cannot bind argument to parameter 'Url'` | `artifactsLocation` doesn't end with `/`, or `Configuration.zip` not at the root of the container. |
| Domain join fails | Wrong `adDnsServerIp`, NSG blocking DNS/LDAP/Kerberos, or service account lacks rights in the target OU. |
| `New-RDSessionDeployment` fails | Session host VM names don't match `<sessionHostNamingPrefix><NN>.<adDomainName>`. Make sure `sessionHostNamingPrefix` here is the same as the prefix used to name the RDSH VMs in `main.bicep`. |
| `BindRDSCertificates` throws "Certificate ... not found" | KV VM extension hasn't synced yet, cert policy isn't `exportable: true`, or `certificateSubject` doesn't match the cert's subject. |
| `403` from Key Vault to the VM extension | UAMI doesn't have `Key Vault Secrets User` on the vault, **or** the vault still uses access policies instead of RBAC. |
| Health probe shows backend unhealthy | RD Gateway role not finished installing yet (give it ~15 min on first boot), or NSG blocking `AzureLoadBalancer` source tag. |

## CI/CD with GitHub Actions

A ready-to-use workflow is provided at [`.github/workflows/deploy.yml`](.github/workflows/deploy.yml). It uses **OIDC federated credentials** (no client secrets stored in GitHub) and runs:

| Trigger | Jobs |
| --- | --- |
| Pull request to `main` | `lint` → `package-dsc` → `upload-artifacts` → `what-if` |
| Push to `main` | `lint` → `package-dsc` → `upload-artifacts` → `deploy` |
| Manual (`workflow_dispatch`) | choose `what-if` or `deploy` |

The pipeline:

1. Compiles `main.bicep` and `main.bicepparam` for linting.
2. Zips `dsc/Configuration.ps1` → `Configuration.zip`.
3. Uploads the zip to your artifacts storage account using **`--auth-mode login`** (no account keys).
4. Generates a **user-delegation SAS** (2-hour expiry) and masks it from logs.
5. Runs `az deployment group what-if` (PRs) or `create` (main).
6. Posts the gateway FQDN and RD Web URL to the GitHub Actions job summary.

### One-time setup

#### 1. Create an Entra app + federated credentials

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

#### 2. Grant Azure RBAC to the service principal

The principal needs to:

| Scope | Role | Why |
| --- | --- | --- |
| Target resource group (`rds-farm-rg`) | `Contributor` | Deploy VMs, LB, NSG, etc. |
| Existing VNet RG | `Network Contributor` | Read existing VNet/subnet, attach NSG. |
| Existing Key Vault (if cert binding) | `Key Vault Reader` + `Role Based Access Control Administrator` | The Bicep `kv-role.bicep` creates a role assignment, which needs `Microsoft.Authorization/roleAssignments/write`. |
| Artifacts storage account | `Storage Blob Data Contributor` | Upload `Configuration.zip` and mint a user-delegation SAS. |

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

#### 3. Configure GitHub secrets, variables, environments

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

#### 4. Set the artifacts storage account name in `env`

The workflow reads `${{ vars.ARTIFACTS_STORAGE_ACCOUNT }}`. Make sure the container `dsc` exists:

```powershell
az storage container create \
  --account-name $env:ARTIFACTS_STORAGE_ACCOUNT \
  --name dsc \
  --auth-mode login
```

#### 5. Push and run

```powershell
git add .
git commit -m "ci: add GitHub Actions deployment for RDS farm"
git push origin main
```

Open a PR to see the `what-if` job comment its plan; merge to trigger the `deploy` job (gated by the `production` environment approval).

### Notes on the SAS approach

- The workflow uses `az storage blob generate-sas --auth-mode login --as-user`, which produces a **user-delegation SAS** signed with the service principal's Entra ID token. No storage account keys are ever required.
- SAS lifetime is 2 hours — enough for the DSC extension to download `Configuration.zip` during provisioning, but short enough that a leaked log line won't be exploitable for long. The SAS is also masked with `::add-mask::`.
- Bicep parameters set via `--parameters key=value` override values from `main.bicepparam`. The pipeline uses this to inject `artifactsLocation` so the file can stay environment-neutral in source control.

## When to use Azure Virtual Desktop (AVD) instead

If you don't have a hard requirement for self-managed RDS, **Azure Virtual Desktop** is the modern direction:

- No Broker / Gateway / Web Access VMs to operate.
- No public IPs at all (reverse-connect over outbound 443).
- Per-user CALs included in Microsoft 365 E3/E5 / Windows 11 multi-session entitlements.
- Use [`Azure/avdaccelerator`](https://github.com/Azure/avdaccelerator) for an enterprise-scale Bicep landing zone.

Stick with classic RDS (this template) when you need:

- Windows Server multi-session for apps that don't support Windows 11 multi-session.
- On-prem licensing parity (existing RDS CALs).
- Air-gapped or sovereign environments where AVD isn't available.

## License

MIT. The DSC role-deployment script is derived from the structure used by the historical `Azure/RDS-Templates` repository, modernized for current PowerShell `RemoteDesktop` cmdlets.
