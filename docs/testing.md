# Testing & verification

[← Back to main README](../README.md)

> [!NOTE]
> **Where this fits in the tier model.** Layers 1–4 below are Tier 2 (ad-hoc, from your laptop or a jumpbox). Layer 5 is Tier 1 (the pipeline runs the same checks automatically on every push/PR/deploy). The local-only [`tests/Test-PreDeployReadiness.ps1`](../tests/Test-PreDeployReadiness.ps1) wraps Layer 1 with extra Azure-side pre-flight checks and is the laptop equivalent of the pipeline's `pre-deploy-checks` job.

A staged set of checks: **(1)** template sanity before you deploy, **(2)** Azure-side smoke tests right after `az deployment group create` returns, **(3)** RDS-role checks on the VMs themselves, **(4)** end-to-end client connection, and **(5)** continuous testing in CI. Run them in order — most "RD Web won't open" tickets are caught by checks 2 or 3.

## 1. Pre-deployment (no resources touched)

> [!TIP]
> **Scripted shortcut.** [`tests/Test-PreDeployReadiness.ps1`](../tests/Test-PreDeployReadiness.ps1) bundles all of (a), (b), (c) below with extra checks — VNet/subnet capacity (does the subnet have enough free IPs for `sessionHostCount + 2`?), Key Vault cert exists with `exportable: true` and 30+ days to expiry, SAS reachability (`HEAD` on `artifactsLocation + Configuration.zip?<SAS>`), `az deployment group validate`, and chains [`tests/Test-BicepParamValues.ps1`](../tests/Test-BicepParamValues.ps1):
>
> ```powershell
> ./tests/Test-PreDeployReadiness.ps1
> # Exits 1 on any FAIL; prints PASS/WARN/FAIL per check.
> ```
>
> This is the local equivalent of the `pre-deploy-checks` job in [`deploy.yml`](../.github/workflows/deploy.yml) — run it before every manual deploy.

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

## 2. Post-deployment Azure-side smoke tests

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

## 3. Inside-the-VM RDS role checks

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

## 4. End-to-end client connectivity

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

## 5. Continuous testing in CI

The `.github/workflows/deploy.yml` pipeline runs all of the above automatically, in three layers:

| Layer | Job | When | Needs Azure? | What it covers |
| --- | --- | --- | --- | --- |
| 1. Config | `lint` + `config-tests` | every push / PR | no | `bicep build`, `bicep build-params`, [`actionlint`](https://github.com/rhysd/actionlint), `markdownlint`, DSC parse + PSScriptAnalyzer (`tests/Test-DscConfiguration.ps1`), bicepparam value invariants (`tests/Test-BicepParamValues.ps1`) |
| 2. Pre-deploy | `pre-deploy-checks` | after `upload-artifacts`, before `what-if`/`deploy` | yes (read-only) | existing VNet/subnet present + has enough free IPs, Bastion subnet (if `deployBastion=true`), Key Vault is RBAC-enabled and cert is exportable + not expiring, `Configuration.zip` reachable via SAS, `az deployment group validate` (catches RBAC / policy errors that `what-if` masks) |
| 3. Post-deploy | `post-deploy-tests` | after `deploy` succeeds on `main` | yes | every VM extension `provisioningState=Succeeded`, per-VM Resource Health, LB backend pool health, `gatewayFqdn` resolves, `https://<fqdn>/RDWeb/` returns 200 (soft-warn — the runner IP may not be in `allowedClientSourceAddressPrefixes`), vanity-CNAME (`publicGatewayFqdn`) resolves to the LB if different from the Azure-issued FQDN (soft-warn) |

The three test PowerShell scripts also run standalone:

```powershell
# Layer 1 — local, no Azure
./tests/Test-DscConfiguration.ps1
./tests/Test-BicepParamValues.ps1

# Layer 3 — after a deploy, requires az login + RG read access
./tests/Test-PostDeployHealth.ps1 -ResourceGroupName rds-farm-rg
```

For pull requests against `main`, the gate is `lint` → `config-tests` → `package-dsc` → `upload-artifacts` → `pre-deploy-checks` → `what-if`. The `prereqs` job is workflow_dispatch-only — see [CI/CD → trigger table](./ci-cd.md). Nothing in the live environment is changed.
