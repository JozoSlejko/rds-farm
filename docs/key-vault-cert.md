# Key Vault prep (only if `enableCertificateBinding = true`)

[← Back to main README](../README.md)

> [!NOTE]
> **Where this fits in the tier model.** This entire page is **Tier 0** — runs once, before your first pipeline / laptop deploy. [Renewal](#certificate-renewal) is occasional Tier 2 work (Key Vault VM extension picks up new versions automatically; only `Set-RDCertificate` rebinding needs a DSC re-apply). The pipeline's `pre-deploy-checks` job verifies your cert is exportable and not expiring within 30 days on every run.

This guide walks you through getting a TLS cert into Key Vault so the deployment can bind it to all four RDS roles (`RDGateway`, `RDWebAccess`, `RDPublishing`, `RDRedirector`) automatically. Pick your gateway hostname first per [Choosing your gateway FQDN](./gateway-fqdn.md) — the cert Subject must match it exactly.

> [!TIP]
> **The typical entry point is [`scripts/Initialize-RdsFarm.ps1`](../scripts/Initialize-RdsFarm.ps1)**, which provisions the Key Vault (via [`prereqs/main.bicep`](../prereqs/main.bicep)), creates the cert (via [`scripts/New-RdsCertificate.ps1`](../scripts/New-RdsCertificate.ps1)), and patches `main.bicepparam` in one orchestrated run. Read this page when you need to understand *what* it's doing — or when you're renewing / re-issuing a cert outside the bootstrap.

## What kind of certificate do I need?

RDS uses the **same** TLS cert for all four roles, so you need **one** certificate that meets all of these:

| Requirement | Why | What to set |
| --- | --- | --- |
| Issued by a **publicly trusted CA** | The cert is presented to remote users connecting from outside your network; their machines won't trust a private/internal CA. | Buy from DigiCert/Sectigo/GoDaddy, get a free one from Let's Encrypt, or use any CA your organization already has integrated with Key Vault. **Self-signed certs only work for lab testing** (see [Option 1](./gateway-fqdn.md#option-1--use-the-azure-managed-lb-hostname-labdev-only)). Public CAs **will not issue** a cert for `*.cloudapp.azure.com` — use a hostname in a domain you own (see [Option 2](./gateway-fqdn.md#option-2--use-a-vanity-cname-under-your-own-domain-recommended-for-production)). |
| **Subject CN or SAN** matches the public FQDN of your gateway | RDP client validates the hostname against the cert. Any mismatch → "*The remote computer could not be authenticated due to problems with its security certificate*". | Set this to whatever you put in `publicGatewayFqdn` — e.g. `rds.contoso.com`, or `*.contoso.com` for a wildcard. Match `certificateSubject` to the cert's actual Subject string. |
| **Key type RSA 2048+** (or ECC P-256) | Required by Schannel / RD Gateway. RSA 4096 is fine, RSA 1024 is not. | `key_props.key_type = 'RSA'`, `key_size = 2048`. |
| **Enhanced Key Usage = Server Authentication** (OID `1.3.6.1.5.5.7.3.1`) | RDS rejects certs without it (you'd see error 0x80092004 in the EventLog). | Default for any TLS cert; explicit in JSON: `"ekus": ["1.3.6.1.5.5.7.3.1"]`. |
| **`exportable: true`** in the KV cert policy | The broker DSC step exports a temporary PFX to call `Set-RDCertificate -ImportPath`. A non-exportable cert pulled by the KV VM extension cannot be re-exported, even by `LocalSystem`. | `key_props.exportable = true`. **This is the most common gotcha.** |
| **Includes the private key** | `Set-RDCertificate` needs the private key to install on the other RDS servers. | KV-generated certs always include it; if you import a `.pfx`, use the form with the private key (not `.cer`). |
| **Valid for at least 90 days** | RDS doesn't auto-rotate; you want headroom before re-running the deployment. | KV default is 12 months. |

> [!IMPORTANT]
> A **wildcard cert (`CN=*.contoso.com`)** also works and is convenient if you serve multiple RDS farms from the same domain — just make sure `certificateSubject` in `main.bicepparam` matches its subject (e.g. `CN=*.contoso.com`).

## Step 1. Make sure the vault uses RBAC, not access policies

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

## Step 2. Create the certificate

Choose **one** of the three options below.

> [!TIP]
> **Scripted shortcut.** [`scripts/New-RdsCertificate.ps1`](../scripts/New-RdsCertificate.ps1) wraps all three options and enforces the policy invariants (`exportable: true`, RSA 2048, EKU Server Authentication, SAN = your `Fqdn`):
>
> ```powershell
> # Option A — CSR
> ./scripts/New-RdsCertificate.ps1 -VaultName contoso-rds-kv -CertName rds-tls -Fqdn rds.contoso.com -Mode Csr
> # …submit rds-tls.csr to your CA, then:
> ./scripts/New-RdsCertificate.ps1 -VaultName contoso-rds-kv -CertName rds-tls -MergeSignedCert .\rds-tls.cer
>
> # Option B — import existing PFX (prompts for password securely)
> ./scripts/New-RdsCertificate.ps1 -VaultName contoso-rds-kv -CertName rds-tls -Fqdn rds.contoso.com -Mode ImportPfx -PfxPath .\rds-tls.pfx
>
> # Option C — self-signed (lab only)
> ./scripts/New-RdsCertificate.ps1 -VaultName contoso-rds-kv -CertName rds-tls -Fqdn rds.contoso.com -Mode SelfSigned
>
> # Optional: also patch main.bicepparam (keyVaultName, keyVaultCertSecretUri, certificateSubject, publicGatewayFqdn)
> ./scripts/New-RdsCertificate.ps1 -VaultName contoso-rds-kv -CertName rds-tls -Fqdn rds.contoso.com -Mode SelfSigned -OutputBicepParam ../main.bicepparam
> ```
>
> The sections below remain the canonical reference for what each option does.

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

## Step 3. Get the secret URI and put it in `main.bicepparam`

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

Then in [`main.bicepparam`](../main.bicepparam):

```bicep
param enableCertificateBinding = true
param keyVaultName             = 'contoso-rds-kv'
param keyVaultResourceGroup    = 'security-rg'
param keyVaultCertSecretUri    = 'https://contoso-rds-kv.vault.azure.net/secrets/rds-tls'
param publicGatewayFqdn        = 'rds.contoso.com'       // vanity FQDN users type (CNAME → gatewayFqdn)
param certificateSubject       = 'CN=rds.contoso.com'   // must be a substring of the cert's actual Subject
```

> [!TIP]
> **Scripted shortcut.** [`scripts/Set-BicepParamCertUri.ps1`](../scripts/Set-BicepParamCertUri.ps1) patches these six values in place, takes a `.bak` backup, and validates the result with `az bicep build-params` (restoring on failure):
>
> ```powershell
> ./scripts/Set-BicepParamCertUri.ps1 `
>   -ParamFile main.bicepparam `
>   -KeyVaultName contoso-rds-kv `
>   -KeyVaultResourceGroup security-rg `
>   -KeyVaultCertSecretUri 'https://contoso-rds-kv.vault.azure.net/secrets/rds-tls' `
>   -CertificateSubject 'CN=rds.contoso.com' `
>   -PublicGatewayFqdn rds.contoso.com `
>   -EnableCertificateBinding $true
> ```

That's all you need. On deploy, the user-assigned MI gets `Key Vault Secrets User` on the vault (via `kv-role.bicep`), the **Key Vault VM extension** on every RDS VM polls `keyVaultCertSecretUri` every hour and installs the cert into `LocalMachine\My` with its private key intact, and the broker DSC's `BindRDSCertificates` finds it by `certificateSubject` and binds it to all four RDS roles.

## Certificate renewal

The Key Vault VM extension keeps the **OS cert store** in sync automatically (within the polling interval, default 1 h). However, `Set-RDCertificate` is **only re-run during DSC apply**, so RDS will keep pointing at the old cert thumbprint until you either:

- **Re-run the pipeline** (`workflow_dispatch → deploy`) — the DSC `BindRDSCertificates.TestScript` only matches `Level=Trusted` certs by subject, so after a renewal the new thumbprint gets bound on the next DSC apply, **or**
- **Add a scheduled task on the broker** that runs the same `Set-RDCertificate` block weekly.
