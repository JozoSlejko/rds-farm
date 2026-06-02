# Manual deploy (Tier 1 escape hatch)

[← Back to main README](../README.md)

> [!IMPORTANT]
> **Use the pipeline.** The supported deploy path is [CI/CD with GitHub Actions](./ci-cd.md) — every push to `main` runs `what-if` and (after approval) `deploy`. This page documents the same `main.bicep` / `main.bicepparam` flow as a **Tier 1 alternative** for the handful of cases where CI isn't an option:
>
> - CI is temporarily unavailable (workflow disabled, GitHub outage).
> - You're iterating on `main.bicep` or `dsc/Configuration.ps1` and want a fast local loop.
> - You don't have repo write access to wire up GitHub Actions yet.
>
> If none of those apply, close this page and `git push` instead. The pipeline supplies the four CI-injected values (`domainJoinPassword`, `localAdminPassword`, `artifactsLocationSasToken`, `artifactsLocation`); the laptop path asks you for them at runtime.

See [README → Deployment guide](../README.md#deployment-guide) for the bigger picture.

---

## What the deployment does end-to-end

From a clean run — pipeline or laptop — the template performs the following **without any manual step on the VMs** before the test user can sign in to RD Web:

| # | Step | Where it runs | How |
| --- | --- | --- | --- |
| 1 | Provision NSG, LB, Public IP, NICs, VMs (Trusted Launch) | ARM control plane | Bicep |
| 2 | Set NIC DNS → your existing DC IP (`adDnsServerIp`) | VM NIC | Bicep (`dnsSettings.dnsServers`) |
| 3 | **Domain-join every VM** to your existing AD | VM | `JsonADDomainExtension` v1.3 (`Options: 3`) |
| 4 | Install RDS roles (`RDS-Gateway`, `RDS-Web-Access`, `RPC-over-HTTP-Proxy`, `RDS-Connection-Broker`, `RDS-Licensing`, `RDS-RD-Server`, RSAT) | VM | DSC `WindowsFeature` resources |
| 5 | `New-RDSessionDeployment` (broker + web access + session hosts) | Broker | DSC `Script CreateRDSDeployment` |
| 6 | `Add-RDServer -Role RDS-GATEWAY -GatewayExternalFqdn <publicGatewayFqdn>` | Broker | same script |
| 7 | `Add-RDServer -Role RDS-LICENSING` + `Set-RDLicenseConfiguration -Mode PerUser` (120-day grace) | Broker | same script |
| 8 | `Set-RDDeploymentGatewayConfiguration` — force traffic through gateway, cache RD Web creds | Broker | same script |
| 9 | `New-RDSessionCollection` (default `DesktopCollection`) | Broker | same script |
| 10 | `Set-RDSessionCollectionConfiguration -UserGroup <netbios>\<rdsAccessGroup>` | Broker | same script |
| 11 | **Create default RD CAP + RAP scoped to `rdsAccessGroup`** so the gateway actually accepts sessions | Gateway | DSC `Script ConfigureRDGatewayPolicies` (uses `RDS:\GatewayServer` PSDrive) |
| 12 | Optional: pull TLS cert from Key Vault → `Set-RDCertificate` for all 4 roles | Broker | KV VM extension + DSC `Script BindRDSCertificates` |

After step 12 returns success, opening `https://<publicGatewayFqdn>/RDWeb/` from a client in an allow-listed CIDR and signing in as any member of `rdsAccessGroup` returns the `DesktopCollection` desktop.

---

> [!TIP]
> **One-command shortcut.** [`scripts/Invoke-ManualDeploy.ps1`](../scripts/Invoke-ManualDeploy.ps1) bundles steps 1, 2, 5 (`what-if`), and 5 (`create`) into a single call:
>
> ```powershell
> # Preview only
> ./scripts/Invoke-ManualDeploy.ps1 -Action what-if -StorageAccount contosoartifactssa
>
> # Apply
> ./scripts/Invoke-ManualDeploy.ps1 -Action deploy   -StorageAccount contosoartifactssa
> ```
>
> The wrapper packages `dsc/Configuration.ps1` via [`scripts/Publish-DscArtifact.ps1`](../scripts/Publish-DscArtifact.ps1), mints a user-delegation SAS, sets `ARTIFACTS_SAS`/`ARTIFACTS_STORAGE_ACCOUNT` for the process, prompts for `DOMAIN_JOIN_PASSWORD`/`LOCAL_ADMIN_PASSWORD` if missing, and runs `az deployment group what-if` (always) and `az deployment group create` (when `-Action deploy`). The sections below remain the canonical reference for what each step does under the hood.

## 1. Package and upload DSC artifacts

Use [`scripts/Publish-DscArtifact.ps1`](../scripts/Publish-DscArtifact.ps1) — the same script the pipeline calls. It zips `dsc/Configuration.ps1`, uploads via `az storage blob upload --auth-mode login` (no account keys), and mints a 2-hour user-delegation SAS:

```powershell
cd C:\Users\jozoslejko\OneDrive\Dev\rds-farm

$result = ./scripts/Publish-DscArtifact.ps1 `
  -StorageAccount contosoartifactssa `
  -Container dsc
# $result has .ArtifactsLocation (URL ending /) and .Sas (token with leading '?')

$env:ARTIFACTS_LOCATION = $result.ArtifactsLocation
$env:ARTIFACTS_SAS      = $result.Sas
```

If you'd rather run the underlying `az` commands by hand, they are:

```powershell
Compress-Archive -Path .\dsc\Configuration.ps1 -DestinationPath .\Configuration.zip -Force

az storage blob upload `
  --account-name contosoartifactssa `
  --container-name dsc `
  --name Configuration.zip `
  --file .\Configuration.zip `
  --auth-mode login --overwrite

$expiry = (Get-Date).ToUniversalTime().AddHours(2).ToString('yyyy-MM-ddTHH:mm:ssZ')
$sas    = az storage blob generate-sas `
  --account-name contosoartifactssa --container-name dsc --name Configuration.zip `
  --permissions r --expiry $expiry --auth-mode login --as-user -o tsv
```

## 2. Set secrets in your shell

These three env vars provide the values for the **four CI-injected `main.bicepparam` parameters** (`domainJoinPassword`, `localAdminPassword`, `artifactsLocationSasToken`, plus `artifactsLocation` which we pass via `--parameters` in step 5):

```powershell
$env:DOMAIN_JOIN_PASSWORD = '<svc-domainjoin password>'
$env:LOCAL_ADMIN_PASSWORD = '<local admin password>'
# $env:ARTIFACTS_LOCATION and $env:ARTIFACTS_SAS were set in step 1
```

## 3. Create the TLS certificate in Key Vault *(only if Tier 0 did not)*

Skip this step entirely if `scripts/Initialize-RdsFarm.ps1` already provisioned the cert (the normal path). It's documented here only for the rare case where you have to do it by hand — e.g. the orchestrator can't run in your environment, or your security team owns cert issuance in a separate workflow.

> [!TIP]
> **Scripted shortcut.** [`scripts/New-RdsCertificate.ps1`](../scripts/New-RdsCertificate.ps1) wraps all three modes and enforces the policy invariants (`exportable: true`, RSA 2048, EKU Server Authentication, SAN = your `Fqdn`):
>
> ```powershell
> # Option A — CSR (production)
> ./scripts/New-RdsCertificate.ps1 -VaultName contoso-rds-kv01 -CertName rds-tls -Fqdn rds.contoso.com -Mode Csr
> # ...submit rds-tls.csr to your CA, then:
> ./scripts/New-RdsCertificate.ps1 -VaultName contoso-rds-kv01 -CertName rds-tls -MergeSignedCert .\rds-tls.cer
>
> # Option B — import existing PFX (prompts for password securely)
> ./scripts/New-RdsCertificate.ps1 -VaultName contoso-rds-kv01 -CertName rds-tls -Fqdn rds.contoso.com -Mode ImportPfx -PfxPath .\rds-tls.pfx
>
> # Option C — self-signed (lab only)
> ./scripts/New-RdsCertificate.ps1 -VaultName contoso-rds-kv01 -CertName rds-tls -Fqdn rds.contoso.com -Mode SelfSigned
>
> # Patch the cert-related params in main.bicepparam in one shot
> ./scripts/New-RdsCertificate.ps1 -VaultName contoso-rds-kv01 -CertName rds-tls -Fqdn rds.contoso.com `
>   -Mode SelfSigned -OutputBicepParam ../main.bicepparam
> ```
>
> The verbose `az` recipes below remain the canonical reference for what each mode does. For the **decision** of which mode + hostname to pick, see [Gateway FQDN and TLS certificate](./fqdn-and-cert.md).

### 3a. Make sure the vault uses RBAC, not access policies

`kv-role.bicep` assigns the built-in role `Key Vault Secrets User` (`4633458b-17de-408a-b874-0445c86b69e6`) to the user-assigned identity. This **only works on RBAC-mode vaults**.

```powershell
# Verify
az keyvault show -n contoso-rds-kv01 --query "properties.enableRbacAuthorization" -o tsv
# Expected: true

# If false, switch (this disables all existing access policies)
az keyvault update -n contoso-rds-kv01 --enable-rbac-authorization true
```

You also need **Key Vault Certificates Officer** (or higher) on your own user to create / import the cert below:

```powershell
$me = az ad signed-in-user show --query id -o tsv
az role assignment create `
  --assignee $me `
  --role 'Key Vault Certificates Officer' `
  --scope (az keyvault show -n contoso-rds-kv01 --query id -o tsv)
```

### 3b. Generate a CSR in Key Vault, sign with a public CA *(production)*

Keeps the private key inside Key Vault — you never see it. Works with any public CA that accepts a CSR.

```powershell
$vault    = 'contoso-rds-kv01'
$certName = 'rds-tls'
$fqdn     = 'rds.contoso.com'   # your vanity gateway FQDN (matches publicGatewayFqdn)

# 1) Build an exportable policy with the right subject / SAN / EKU.
#    NOTE: the Key Vault REST API + modern Azure CLI use camelCase
#    (keyProperties / x509CertificateProperties / issuerParameters). Older
#    docs that read `az keyvault certificate get-default-policy` and patched
#    snake_case fields (key_props / x509_props / issuer_parameters) silently
#    no-op on current CLI — build the policy directly instead.
$policy = @{
    keyProperties = @{
        exportable = $true
        keyType    = 'RSA'
        keySize    = 2048
        reuseKey   = $false
    }
    secretProperties = @{
        contentType = 'application/x-pkcs12'
    }
    x509CertificateProperties = @{
        subject = "CN=$fqdn"
        subjectAlternativeNames = @{
            dnsNames = @($fqdn)
            emails   = @()
            upns     = @()
        }
        ekus             = @('1.3.6.1.5.5.7.3.1')   # Server Authentication
        keyUsage         = @('digitalSignature','keyEncipherment')
        validityInMonths = 12
    }
    issuerParameters = @{
        # 'Unknown' = manual CSR; replace with 'DigiCert' / 'GlobalSign' if
        # you have a KV-integrated CA account.
        name = 'Unknown'
    }
    lifetimeActions = @(
        @{
            trigger = @{ daysBeforeExpiry = 90 }
            action  = @{ actionType       = 'AutoRenew' }
        }
    )
}
$policy | ConvertTo-Json -Depth 10 | Out-File policy.json -Encoding utf8

# 2) Start the cert operation (creates a pending cert + CSR)
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

### 3c. Import an existing PFX *(you already have a cert)*

Use this when your security team already has a `.pfx` from your enterprise CA or a public CA.

```powershell
$vault    = 'contoso-rds-kv01'
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

# Confirm it's exportable (note: 'show-policy' is not a real CLI subcommand;
# use 'show ... --query policy.<...>' instead)
az keyvault certificate show --vault-name $vault --name $certName `
  --query 'policy.keyProperties.exportable' -o tsv
# Must print: true
```

> [!WARNING]
> If your `.pfx` was generated with the private key flagged non-exportable (e.g. created on a Windows machine with `-KeyExportPolicy NonExportable`), Key Vault will store it but the broker DSC step will fail to re-export. Re-issue the cert with exportable key material before importing.

### 3d. Self-signed via Key Vault *(lab only)*

Useful to verify the end-to-end binding flow before paying for a real cert. **Clients see a trust warning** and must click through it.

```powershell
$vault    = 'contoso-rds-kv01'
$certName = 'rds-tls-selfsigned'
$fqdn     = 'contoso-rds.westeurope.cloudapp.azure.com'   # match exactly what RD clients connect to

# Build the policy directly in camelCase — see the note in 3b for why.
$policy = @{
    keyProperties = @{
        exportable = $true
        keyType    = 'RSA'
        keySize    = 2048
        reuseKey   = $false
    }
    secretProperties = @{
        contentType = 'application/x-pkcs12'
    }
    x509CertificateProperties = @{
        subject = "CN=$fqdn"
        subjectAlternativeNames = @{
            dnsNames = @($fqdn)
            emails   = @()
            upns     = @()
        }
        ekus             = @('1.3.6.1.5.5.7.3.1')   # Server Authentication
        keyUsage         = @('digitalSignature','keyEncipherment')
        validityInMonths = 12
    }
    issuerParameters = @{ name = 'Self' }
    lifetimeActions = @(
        @{
            trigger = @{ daysBeforeExpiry = 90 }
            action  = @{ actionType       = 'AutoRenew' }
        }
    )
}
$policy | ConvertTo-Json -Depth 10 | Out-File policy.json -Encoding utf8

az keyvault certificate create --vault-name $vault --name $certName --policy `@policy.json
```

### 3e. Get the secret URI

The KV VM extension and `Set-RDCertificate` need the **secret** URI (not the certificate URI), version-stripped so the deployment always picks up the current version:

```powershell
$secretUri = az keyvault certificate show --vault-name $vault --name $certName --query 'sid' -o tsv
# Returns: https://contoso-rds-kv01.vault.azure.net/secrets/rds-tls/<version>

$secretUri = ($secretUri -split '/')[0..4] -join '/'
$secretUri
# https://contoso-rds-kv01.vault.azure.net/secrets/rds-tls
```

Plug that value into `keyVaultCertSecretUri` in step 4.

## 4. Edit `main.bicepparam`

If Tier 0 ran, the file is already fully populated and you can skip this step. Otherwise set at minimum:

```bicep
// --- existing infra (always required) ---
param existingVnetName              = 'corp-vnet'
param existingVnetResourceGroup     = 'network-rg'
param existingRdsSubnetName         = 'snet-rds'
param adDomainName                  = 'contoso.local'
param adDnsServerIp                 = '10.10.0.4'
param allowedClientSourceAddressPrefixes = ['203.0.113.0/24','198.51.100.10/32']
param gatewayDnsLabelPrefix         = 'contoso-rds'   // <prefix>.<region>.cloudapp.azure.com

// --- TLS cert + vanity FQDN (only when enableCertificateBinding = true) ---
param enableCertificateBinding = true
param keyVaultName             = 'contoso-rds-kv01'
param keyVaultResourceGroup    = 'rds-security-rg'
param keyVaultCertSecretUri    = 'https://contoso-rds-kv01.vault.azure.net/secrets/rds-tls'  // from step 3e
param publicGatewayFqdn        = 'rds.contoso.com'    // vanity FQDN clients type
param certificateSubject       = 'CN=rds.contoso.com' // must be a substring of the cert's actual Subject
```

**Do not** put real values into `domainJoinPassword`, `localAdminPassword`, `artifactsLocationSasToken`, or `artifactsLocation` — those come from env vars (step 2) and the `--parameters` override (step 5). Leave them as their `readEnvironmentVariable(...)` defaults.

Full list of every parameter and its source: [README → Parameters reference](../README.md#parameters-reference-mainbicepparam).

> [!TIP]
> **Scripted shortcut for the cert block.** [`scripts/Set-BicepParamCertUri.ps1`](../scripts/Set-BicepParamCertUri.ps1) patches the six cert / FQDN values in place, takes a `.bak` backup, and validates with `az bicep build-params` (restoring on failure):
>
> ```powershell
> ./scripts/Set-BicepParamCertUri.ps1 `
>   -ParamFile main.bicepparam `
>   -KeyVaultName contoso-rds-kv01 `
>   -KeyVaultResourceGroup rds-security-rg `
>   -KeyVaultCertSecretUri 'https://contoso-rds-kv01.vault.azure.net/secrets/rds-tls' `
>   -CertificateSubject 'CN=rds.contoso.com' `
>   -PublicGatewayFqdn rds.contoso.com `
>   -EnableCertificateBinding $true
> ```

## 5. Deploy

```powershell
cd C:\Users\jozoslejko\OneDrive\Dev\rds-farm

az group create -n rds-farm-rg -l westeurope

# Preview changes (note the artifactsLocation override matching the SA from step 1)
az deployment group what-if `
  -g rds-farm-rg `
  --template-file main.bicep `
  --parameters main.bicepparam `
  --parameters artifactsLocation=$env:ARTIFACTS_LOCATION

# Apply
az deployment group create `
  -g rds-farm-rg `
  --template-file main.bicep `
  --parameters main.bicepparam `
  --parameters artifactsLocation=$env:ARTIFACTS_LOCATION
```

Typical wall-clock time on `Standard_D4s_v5`: **25–40 minutes** (VM provisioning + domain join reboot + DSC role install + RDS deployment).

## 6. Verify

```powershell
$dep = az deployment group show -g rds-farm-rg -n main --query properties.outputs -o json | ConvertFrom-Json
$dep.rdWebUrl.value         # e.g. https://rds.contoso.com/RDWeb
$dep.gatewayFqdn.value      # underlying LB FQDN (CNAME target)
```

Open the `rdWebUrl` from a client in one of the allow-listed CIDRs. Sign in with a domain user; you should see the `DesktopCollection` resource.

Run the full [Testing & verification](./testing.md) checks (5 stages) to confirm everything is healthy end-to-end.

## 7. Post-deployment steps still required

These live outside the template regardless of which path (pipeline or this page) ran the deploy. See [README → Tier 2 — Post-deploy operations](../README.md#tier-2--post-deploy-operations) for the full walkthrough.

### 7a. Public DNS CNAME *(vanity FQDN only)*

The Bicep deploy outputs `gatewayFqdn` — the target of your CNAME. Decision rationale: [Gateway FQDN and TLS certificate](./fqdn-and-cert.md).

**Azure DNS shortcut:**

```powershell
# Auto-discover everything from the contoso.com zone + main deployment in rds-farm-rg
./scripts/Set-GatewayCname.ps1 -ZoneName contoso.com -RecordName rds -Verify

# Pin to a specific zone RG / different farm RG / explicit target, and probe RDWeb after
./scripts/Set-GatewayCname.ps1 -ZoneName contoso.com -RecordName rds `
  -ZoneResourceGroup dns-rg -FarmResourceGroup rds-farm-rg `
  -Target contoso-rds.westeurope.cloudapp.azure.com -Verify
```

**Manually, with `az`:**

```powershell
# 1) Grab the LB FQDN from the deploy outputs
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
#     create a CNAME record manually in their portal:
#     Name:  rds
#     Type:  CNAME
#     Value: <gatewayFqdn from step 1>
#     TTL:   300  (5 min — keeps you nimble during cutover / rollback)
```

### 7b. RDS CALs

Activate the license server on the broker (`RD Licensing Manager → Activate Server`) and install your real RDS CALs. Then add the broker computer object to the AD `Terminal Server License Servers` group (requires Domain Admin — outside the rights granted to the domain-join service account). Without it, the broker can't hand out CALs after the 120-day per-user grace period expires.

### 7c. Smoke tests

[`tests/Test-PostDeployHealth.ps1`](../tests/Test-PostDeployHealth.ps1) plus the manual stages in [Testing & verification](./testing.md).

### 7d. Cert renewal cadence

The KV VM extension keeps the local cert store in sync; `Set-RDCertificate` only re-runs on the next DSC apply. Full renewal flow: [Gateway FQDN and TLS certificate → Certificate renewal](./fqdn-and-cert.md#certificate-renewal).

For published apps instead of the default desktop collection:

```powershell
New-RDRemoteApp -Alias notepad -DisplayName 'Notepad' `
  -FilePath 'C:\Windows\System32\notepad.exe' `
  -CollectionName 'DesktopCollection' `
  -ConnectionBroker 'rds-cb-01.contoso.local'
```

## Cleanup

To remove the farm (and optionally the artifacts / security resource groups created by `prereqs/`), use:

```powershell
# Remove the farm RG only (interactive 'yes' prompt)
./scripts/Remove-RdsFarm.ps1

# Also remove the artifacts RG and skip prompts (CI)
./scripts/Remove-RdsFarm.ps1 -IncludeArtifactsRg -Force
```

The script enumerates resources, warns about Key Vaults with purge protection enabled, and uses `az group delete --no-wait`. Track progress with `az group show -n rds-farm-rg`.
