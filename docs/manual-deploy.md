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

These three env vars provide the values for the **four CI-injected `main.bicepparam` parameters** (`domainJoinPassword`, `localAdminPassword`, `artifactsLocationSasToken`, plus `artifactsLocation` which we pass via `--parameters` in step 4):

```powershell
$env:DOMAIN_JOIN_PASSWORD = '<svc-domainjoin password>'
$env:LOCAL_ADMIN_PASSWORD = '<local admin password>'
# $env:ARTIFACTS_LOCATION and $env:ARTIFACTS_SAS were set in step 1
```

## 3. Edit `main.bicepparam`

Set at minimum the values listed in [README → Set these in `main.bicepparam`](../README.md#set-these-in-mainbicepparam-ci-and-laptop-both-read-the-file) (existing VNet, AD config, allowed source IPs, gateway DNS label prefix, cert/FQDN block if `enableCertificateBinding=true`).

**Do not** put real values into `domainJoinPassword`, `localAdminPassword`, `artifactsLocationSasToken`, or `artifactsLocation` — those come from env vars (step 2) and the `--parameters` override (step 4). Leave them as their `readEnvironmentVariable(...)` defaults.

Full list: [parameters reference](./parameters-reference.md).

## 4. Deploy

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

## 5. Verify

```powershell
$dep = az deployment group show -g rds-farm-rg -n main --query properties.outputs -o json | ConvertFrom-Json
$dep.rdWebUrl.value         # e.g. https://rds.contoso.com/RDWeb
$dep.gatewayFqdn.value      # underlying LB FQDN (CNAME target)
```

Open the `rdWebUrl` from a client in one of the allow-listed CIDRs. Sign in with a domain user; you should see the `DesktopCollection` resource.

Run the full [Testing & verification](./testing.md) checks (5 stages) to confirm everything is healthy end-to-end.

## Post-deployment steps still required

These live outside the template regardless of which path (pipeline or this page) ran the deploy. See [README → Tier 2 — Post-deploy operations](../README.md#tier-2--post-deploy-operations) for the full walkthrough:

1. **Public DNS CNAME** for the vanity FQDN — `scripts/Set-GatewayCname.ps1` if you use Azure DNS, otherwise create it in your DNS provider; see [Choosing your gateway FQDN](./gateway-fqdn.md).
2. **RDS CALs** — activate on the broker (`RD Licensing Manager → Activate Server`) and add the broker computer object to the `Terminal Server License Servers` AD group.
3. **Smoke tests** — [`tests/Test-PostDeployHealth.ps1`](../tests/Test-PostDeployHealth.ps1) plus the manual stages in [Testing & verification](./testing.md).
4. **Cert renewal cadence** — see [Certificate renewal](./key-vault-cert.md#certificate-renewal). The KV VM extension keeps the local cert store in sync; `Set-RDCertificate` only re-runs on the next DSC apply.

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
