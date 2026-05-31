# Testing & verification

[← Back to main README](../README.md)

A staged set of checks: **(1)** template sanity before you deploy, **(2)** Azure-side smoke tests right after `az deployment group create` returns, **(3)** RDS-role checks on the VMs themselves, **(4)** end-to-end client connection, and **(5)** continuous testing in CI. Run them in order — most "RD Web won't open" tickets are caught by checks 2 or 3.

## 1. Pre-deployment (no resources touched)

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

## 5. Continuous testing (recommended additions to CI)

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
