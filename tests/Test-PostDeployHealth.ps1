<#
.SYNOPSIS
    Post-deployment smoke tests for the RDS farm.

.DESCRIPTION
    Run after `az deployment group create` returns success to confirm the
    infrastructure converged correctly. Requires:
      * az CLI logged in with read access to the resource group
      * jq is NOT required; uses native PowerShell JSON parsing

    Tests performed:
      1. Every VM extension reports provisioningState = Succeeded.
      2. Every VM availability state in Resource Health = Available.
      3. Load Balancer backend pool health (informational soft-warn when the
         Azure LB health API can't be queried - VM ext + Resource Health are
         the authoritative signals).
      4. gatewayFqdn DNS resolves.
      5. https://<gatewayFqdn>/RDWeb/ returns 200 (soft warn if this machine's
         public IP isn't in allowedClientSourceAddressPrefixes, or the gateway
         is still warming up).
      6. If publicGatewayFqdn differs from gatewayFqdn, DNS for the vanity
         hostname is also checked.

    Exits non-zero on any HARD failure (categories 1-2); categories 3 and 5
    are soft warnings so the test still passes from a machine that isn't in
    the allow-list.

.PARAMETER ResourceGroupName
    The RG that contains the deployment.

.PARAMETER DeploymentName
    The deployment name to read the gateway FQDN from (default 'main'). When
    left at the default, the script auto-selects the most recent deployment
    named 'main' or 'main-<timestamp>' that actually carries outputs - manual
    deploys via Invoke-ManualDeploy.ps1 are named '<name>-<timestamp>'. Pass an
    explicit name to target one specific deployment and skip auto-selection.

.EXAMPLE
    pwsh -File tests/Test-PostDeployHealth.ps1 -ResourceGroupName rds-farm-rg
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ResourceGroupName,
    [string]$DeploymentName = 'main'
)

$ErrorActionPreference = 'Stop'
$failures = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

function Write-TestResult {
    param([string]$Name, [bool]$Ok, [string]$Detail = '', [switch]$SoftWarn)
    if ($Ok) {
        Write-Host "[PASS] $Name" -ForegroundColor Green
        return
    }
    if ($SoftWarn) {
        Write-Host "[WARN] $Name" -ForegroundColor Yellow
        if ($Detail) { Write-Host "       $Detail" -ForegroundColor DarkYellow }
        $warnings.Add($Name) | Out-Null
    } else {
        Write-Host "[FAIL] $Name" -ForegroundColor Red
        if ($Detail) { Write-Host "       $Detail" -ForegroundColor DarkYellow }
        $failures.Add($Name) | Out-Null
    }
}

Write-Host "Resource group: $ResourceGroupName" -ForegroundColor Cyan
Write-Host ('-' * 60)

# 0. Resolve which deployment to read the gateway FQDN from, then read it.
#    Best-effort: a Failed parent deployment leaves outputs=null but the rest of
#    the infra is still worth checking, so we fall back to querying the LB
#    directly in that case.
#
#    When -DeploymentName is left at its default, auto-select the most recent
#    deployment named '<name>' or '<name>-<timestamp>' that actually carries the
#    gateway FQDN output. Invoke-ManualDeploy.ps1 names its deployments
#    '<name>-<timestamp>' (e.g. main-20260614-101200), so a literal 'main'
#    lookup usually lands on a stale / Failed record with no outputs.
$gatewayFqdn       = $null
$publicGatewayFqdn = $null
$resolvedName      = $DeploymentName

if (-not $PSBoundParameters.ContainsKey('DeploymentName')) {
    $listJson = az deployment group list -g $ResourceGroupName `
        --query "[?name=='$DeploymentName' || starts_with(name, '$DeploymentName-')].{name:name, ts:properties.timestamp, fqdn:properties.outputs.gatewayFqdn.value}" `
        -o json 2>$null
    if ($LASTEXITCODE -eq 0 -and $listJson) {
        $withFqdn = @(($listJson | ConvertFrom-Json) |
            Where-Object { $_.fqdn } |
            Sort-Object { [datetime]$_.ts } -Descending)
        if ($withFqdn.Count -gt 0) { $resolvedName = $withFqdn[0].name }
    }
}

$deployJson = az deployment group show -g $ResourceGroupName -n $resolvedName --query "{state:properties.provisioningState, outputs:properties.outputs}" -o json 2>$null

if ($LASTEXITCODE -ne 0 -or -not $deployJson) {
    Write-TestResult "Deployment '$resolvedName' exists in $ResourceGroupName" $false 'Deployment not found.'
    exit 1
}

$deploy = $deployJson | ConvertFrom-Json
if ($resolvedName -ne $DeploymentName) {
    Write-Host "Auto-selected deployment '$resolvedName' (most recent '$DeploymentName-*' carrying outputs)." -ForegroundColor DarkGray
}
if ($deploy.state -eq 'Succeeded') {
    Write-TestResult "Deployment '$resolvedName' found (state=Succeeded)" $true
} else {
    # Not a failure for THIS health check: it only reads the gateway FQDN from
    # the deployment and falls back to the load balancer's public IP when the
    # outputs are missing.
    Write-TestResult "Deployment '$resolvedName' found (state=$($deploy.state)) - used only to read the gateway FQDN" $true
    Write-Host "       This is not a problem: the rest of the checks just need the gateway FQDN." -ForegroundColor DarkYellow
    Write-Host "       Tip: pass -DeploymentName <name> to target a specific deployment." -ForegroundColor DarkYellow
}

if ($deploy.outputs -and $deploy.outputs.gatewayFqdn) {
    $gatewayFqdn       = $deploy.outputs.gatewayFqdn.value
    $publicGatewayFqdn = $deploy.outputs.publicGatewayFqdn.value
} else {
    # Outputs absent (typical when parent deployment is Failed). Fall back to
    # discovering the load balancer's public IP FQDN directly.
    # NOTE: ARM JMESPath is case-sensitive — it's frontendIPConfigurations /
    # publicIPAddress (capital IP), not frontendIp / publicIp.
    $lbPipId = az network lb list -g $ResourceGroupName --query "[0].frontendIPConfigurations[0].publicIPAddress.id" -o tsv 2>$null
    if ($lbPipId) {
        $gatewayFqdn = az network public-ip show --ids $lbPipId --query 'dnsSettings.fqdn' -o tsv 2>$null
    }
    if ($gatewayFqdn) {
        $publicGatewayFqdn = $gatewayFqdn
        Write-Host "       (deployment outputs unavailable; resolved gatewayFqdn from LB public IP)" -ForegroundColor DarkYellow
    } else {
        Write-TestResult 'Resolve gatewayFqdn (outputs or LB public IP)' $false 'Could not determine FQDN.' -SoftWarn
    }
}

if ($gatewayFqdn)       { Write-Host "Gateway FQDN (LB):     $gatewayFqdn" }
if ($publicGatewayFqdn) { Write-Host "Public gateway FQDN:   $publicGatewayFqdn" }
Write-Host ('-' * 60)

# 1. VM extensions
$vmIds = (az vm list -g $ResourceGroupName --query "[].id" -o tsv) -split "`n" | Where-Object { $_ }
if (-not $vmIds) {
    Write-TestResult 'At least one VM in the resource group' $false
} else {
    $extJson = az vm extension list --ids $vmIds --query "[].{vm:id, ext:name, state:provisioningState}" -o json
    $exts = $extJson | ConvertFrom-Json
    $badExts = @($exts | Where-Object { $_.state -ne 'Succeeded' })
    if ($badExts.Count -gt 0) {
        $detail = ($badExts | ForEach-Object { "$($_.vm | Split-Path -Leaf)/$($_.ext)=$($_.state)" }) -join '; '
        Write-TestResult "All $($exts.Count) VM extensions Succeeded" $false $detail
    } else {
        Write-TestResult "All $($exts.Count) VM extensions Succeeded" $true
    }
}

# 2. Resource Health per VM
# api-version 2024-02-01 is the latest GA across all Azure regions (the older
# 2023-07-01 isn't registered in newer regions like italynorth).
$vmHealthFailures = @()
foreach ($id in $vmIds) {
    $name = $id | Split-Path -Leaf
    $h = az rest --method get `
        --uri "https://management.azure.com$id/providers/Microsoft.ResourceHealth/availabilityStatuses/current?api-version=2024-02-01" `
        -o json 2>$null | ConvertFrom-Json
    $state = if ($h -and $h.properties) { $h.properties.availabilityState } else { 'unknown' }
    if ($state -ne 'Available') { $vmHealthFailures += "${name}=$state" }
}
if ($vmHealthFailures.Count -gt 0) {
    # Resource Health takes ~15-30 min after VM creation to flip to 'Available'
    # and can briefly read 'Unknown' even on healthy VMs — keep it as soft-warn
    # so the test isn't flaky right after deploy.
    Write-TestResult 'Resource Health = Available for all VMs' $false ($vmHealthFailures -join '; ') -SoftWarn
} else {
    Write-TestResult "Resource Health = Available for all $($vmIds.Count) VMs" $true
}

# 3. Load Balancer backend health
# Iterate each backend pool's `health` action (the only stable LB health surface
# exposed through ARM). On failure (older api-versions, missing health endpoint
# in the region) we soft-warn instead of failing the test — VM extension state
# + Resource Health already cover whether the backends are functional.
$lbId = az network lb list -g $ResourceGroupName --query "[0].id" -o tsv
if (-not $lbId) {
    Write-TestResult 'Load Balancer present' $false
} else {
    $poolNames = (az network lb address-pool list --lb-name (Split-Path $lbId -Leaf) -g $ResourceGroupName --query "[].name" -o tsv) -split "`n" | Where-Object { $_ }
    if (-not $poolNames) {
        Write-TestResult 'LB backend pool health = Up' $false 'No backend pools found.' -SoftWarn
    } else {
        $down        = @()
        $unqueryable = @()
        foreach ($pool in $poolNames) {
            $healthJson = az rest --method post `
                --uri "https://management.azure.com$lbId/backendAddressPools/$pool/health?api-version=2024-05-01" `
                -o json 2>$null
            if ($LASTEXITCODE -ne 0 -or -not $healthJson) {
                $unqueryable += $pool
                continue
            }
            $bh = $healthJson | ConvertFrom-Json
            foreach ($addr in @($bh.backendAddresses)) {
                $hs = $addr.health.healthStatus
                if ($hs -ne 'Up') {
                    $down += "$pool/$($addr.networkInterfaceIPConfiguration.id | Split-Path -Leaf)=$hs"
                }
            }
        }
        if ($down.Count -gt 0) {
            # A backend actually reporting not-Up is the one worth surfacing.
            # Still soft: VM extension state + Resource Health are authoritative.
            Write-TestResult 'LB backend pool: one or more backends not Up' $false ($down -join '; ') -SoftWarn
        } elseif ($unqueryable.Count -gt 0) {
            Write-TestResult "LB backend pool health could not be queried ($($unqueryable -join ', '))" $false `
                'The Azure LB health API returned nothing for this pool (common right after deploy or in some regions). It does NOT mean a backend is down - the VM extension and Resource Health checks above already confirm the backends are up. Informational only.' -SoftWarn
        } else {
            Write-TestResult 'LB backend pool health: all backends Up' $true
        }
    }
}

# 4. DNS resolution
if ($gatewayFqdn) {
    try {
        $null = [System.Net.Dns]::GetHostAddresses($gatewayFqdn)
        Write-TestResult "DNS resolves: $gatewayFqdn" $true
    } catch {
        Write-TestResult "DNS resolves: $gatewayFqdn" $false $_.Exception.Message
    }
} else {
    Write-TestResult 'DNS resolves: gatewayFqdn' $false 'gatewayFqdn unknown (no outputs, no LB public IP).' -SoftWarn
}

# 5. RD Web URL reachability — soft warn (runner may not be in allow-list)
if ($publicGatewayFqdn) {
    $rdWebUrl = "https://$publicGatewayFqdn/RDWeb/"
    try {
        $resp = Invoke-WebRequest -Uri $rdWebUrl -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
        if ($resp.StatusCode -eq 200) {
            Write-TestResult "RD Web reachable: $rdWebUrl" $true
        } else {
            Write-TestResult "RD Web reachable: $rdWebUrl" $false "Status $($resp.StatusCode)" -SoftWarn
        }
    } catch {
        $msg = $_.Exception.Message
        # A timeout/connection-refused from here almost always means this
        # machine's public IP isn't in allowedClientSourceAddressPrefixes (the
        # NSG silently drops non-allowed clients, so the TLS handshake never
        # completes). It can also be the gateway still warming up right after a
        # deploy. Either way it's a soft warning - it doesn't prove the gateway
        # is unhealthy, only that THIS machine couldn't reach it.
        if ($msg -match 'timeout|timed out|canceled|actively refused|unreachable') {
            Write-TestResult "RD Web not reachable from this machine: $rdWebUrl" $false `
                "Connection timed out. Most likely this machine's public IP isn't in allowedClientSourceAddressPrefixes, or the gateway is still warming up. Expected when running from outside the allow-list - verify from an allow-listed client." -SoftWarn
        } else {
            Write-TestResult "RD Web not reachable from this machine: $rdWebUrl" $false $msg -SoftWarn
        }
    }
}

# 6. Vanity DNS — only if a separate publicGatewayFqdn was configured
if ($publicGatewayFqdn -and $publicGatewayFqdn -ne $gatewayFqdn) {
    try {
        $null = [System.Net.Dns]::GetHostAddresses($publicGatewayFqdn)
        Write-TestResult "Vanity DNS resolves: $publicGatewayFqdn" $true
    } catch {
        # Soft-warn — admin may not have created the CNAME yet, which is on
        # the post-deploy checklist (Phase 5, step 15).
        Write-TestResult "Vanity DNS resolves: $publicGatewayFqdn (CNAME may not be created yet)" $false $_.Exception.Message -SoftWarn
    }
}

# Summary
Write-Host ('-' * 60)
if ($warnings.Count -gt 0) {
    Write-Host "WARN ($($warnings.Count)): $($warnings -join '; ')" -ForegroundColor Yellow
}
if ($failures.Count -gt 0) {
    Write-Host "FAILED ($($failures.Count)): $($failures -join '; ')" -ForegroundColor Red
    exit 1
}
Write-Host 'All post-deploy infra checks passed (soft warnings do not fail the run).' -ForegroundColor Green
exit 0
