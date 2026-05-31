# Deployment

[← Back to main README](../README.md)

This guide walks a manual (non-CI) deployment. For automated GitHub Actions deploys, see [CI/CD with GitHub Actions](./ci-cd.md).

> [!TIP]
> **One-command shortcut.** [`scripts/Invoke-ManualDeploy.ps1`](../scripts/Invoke-ManualDeploy.ps1) bundles steps 1, 4 (`what-if`), and 4 (`create`) into a single call:
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

## 2. Set secrets in your shell

```powershell
$env:DOMAIN_JOIN_PASSWORD = '<svc-domainjoin password>'
$env:LOCAL_ADMIN_PASSWORD = '<local admin password>'
$env:ARTIFACTS_SAS         = '?sv=...'   # paste the SAS from step 1, or '' if container is public
```

## 3. Edit `main.bicepparam`

Set at minimum:

- `existingVnetName`, `existingVnetResourceGroup`, `existingRdsSubnetName`
- `adDomainName`, `adDnsServerIp`
- `allowedClientSourceAddressPrefixes` (your office/VPN egress IPs only)
- `gatewayDnsLabelPrefix` (must be globally unique in the region)
- `artifactsLocation` (e.g. `https://contosoartifactssa.blob.core.windows.net/dsc/`)
- If using certs: `enableCertificateBinding`, `keyVaultName`, `keyVaultResourceGroup`, `keyVaultCertSecretUri`, `publicGatewayFqdn`, `certificateSubject`

See the [parameters reference](./prerequisites.md#parameters-reference) for the full list.

## 4. Deploy

```powershell
cd C:\Users\jozoslejko\OneDrive\Dev\rds-farm

az group create -n rds-farm-rg -l westeurope

# Preview changes
az deployment group what-if -g rds-farm-rg --parameters main.bicepparam

# Apply
az deployment group create  -g rds-farm-rg --parameters main.bicepparam
```

Typical wall-clock time on `Standard_D4s_v5`: **25–40 minutes** (VM provisioning + domain join reboot + DSC role install + RDS deployment).

## 5. Verify

```powershell
$dep = az deployment group show -g rds-farm-rg -n main --query properties.outputs -o json | ConvertFrom-Json
$dep.rdWebUrl.value         # e.g. https://rds.contoso.com/RDWeb
$dep.gatewayFqdn.value      # underlying LB FQDN (CNAME target)
```

Open the `rdWebUrl` from a client in one of the allow-listed CIDRs. Sign in with a domain user; you should see the `DesktopCollection` resource.

Run the full [Testing & verification](./testing.md) checks (5 stages) to confirm everything is healthy end-to-end.

## Post-deployment steps still required

Even after a successful deployment, these items live outside the template and need a human:

1. **Public DNS.** If you're using a vanity hostname like `rds.contoso.com`, create the CNAME and verify per [Choosing your gateway FQDN → Option 2](./gateway-fqdn.md#option-2--use-a-vanity-cname-under-your-own-domain-recommended-for-production). Make sure the cert Subject/SAN matches the FQDN your users actually type.
2. **RDS CALs.** Install on the broker (`RD Licensing Manager → Activate Server`), and ensure the broker computer object is a member of the `Terminal Server License Servers` group in AD.
3. **Cert renewal.** See [Certificate renewal](./key-vault-cert.md#certificate-renewal) — the KV VM extension keeps the cert store in sync, but `Set-RDCertificate` only re-runs on DSC apply.
4. **Published apps.** This template provisions a full desktop collection. For RemoteApp:

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
