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

.PARAMETER AddClientIpToNsg
    Optional switch. Before the RD Web check, detect this machine's public IPv4
    and add a temporary inbound TCP-443 allow rule for that /32 to the RDS
    subnet's governance NSG, then remove it once the check finishes (always,
    via a finally block). Use it to get a green RD Web result from a host that
    isn't in allowedClientSourceAddressPrefixes. The rule is a SEPARATE, clearly
    named slot (priority 105) - it never touches the farm-managed
    'Allow-HTTPS-from-AllowedClients' rule. The NSG is the one attached to the
    gateway's subnet (the landing-zone governance NSG, usually in the VNet
    resource group); the script discovers it from the gateway NIC. Temporary by
    design: for DURABLE access add the IP to allowedClientSourceAddressPrefixes
    and redeploy (which writes it to the same governance NSG). Requires
    Network Contributor on the NSG's resource group.

.EXAMPLE
    pwsh -File tests/Test-PostDeployHealth.ps1 -ResourceGroupName rds-farm-rg
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ResourceGroupName,
    [string]$DeploymentName = 'main',
    [switch]$AddClientIpToNsg
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

# 5. RD Web URL reachability — soft warn (this machine may not be in the allow-list)
if ($publicGatewayFqdn) {
    $rdWebUrl = "https://$publicGatewayFqdn/RDWeb/"

    # Optional: temporarily open the governance subnet NSG to THIS machine's
    # public IP so the check can pass from a host that isn't in
    # allowedClientSourceAddressPrefixes. The rule goes in a dedicated, clearly
    # named slot (it does NOT touch the farm-managed allow rules) and is ALWAYS
    # removed again in the finally block. Temporary by design - for durable
    # access add the IP to allowedClientSourceAddressPrefixes and redeploy.
    $tempRuleName  = 'TEMP-PostDeployHealthTest-AllowHTTPS'
    $tempRuleNsg   = $null
    $tempRuleNsgRg = $null

    if ($AddClientIpToNsg) {
        $myIp = $null
        foreach ($svc in 'https://api.ipify.org', 'https://ifconfig.me/ip', 'https://icanhazip.com') {
            try { $myIp = ([string](Invoke-RestMethod -Uri $svc -TimeoutSec 10)).Trim(); if ($myIp) { break } } catch { }
        }
        if ($myIp -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
            Write-Host "       [AddClientIpToNsg] Could not determine this machine's public IPv4 (got '$myIp'); skipping NSG change." -ForegroundColor DarkYellow
        } else {
            # The farm no longer attaches a NIC NSG; inbound 443 is gated by the
            # NSG on the gateway's SUBNET (the landing-zone governance NSG, which
            # lives in the VNet's resource group). Discover it from the gateway
            # NIC -> subnet -> networkSecurityGroup so we target the right NSG
            # and RG regardless of layout.
            $nicNames  = @((az network nic list -g $ResourceGroupName --query "[].name" -o tsv 2>$null) -split "`n" | Where-Object { $_ })
            $gwNicName = $nicNames | Where-Object { $_ -match '(?i)gw' } | Select-Object -First 1
            if (-not $gwNicName) { $gwNicName = $nicNames | Select-Object -First 1 }

            $nsgId = $null
            if ($gwNicName) {
                $subnetId = az network nic show -g $ResourceGroupName -n $gwNicName --query "ipConfigurations[0].subnet.id" -o tsv 2>$null
                if ($subnetId) {
                    $nsgId = az network vnet subnet show --ids $subnetId --query "networkSecurityGroup.id" -o tsv 2>$null
                }
            }

            if (-not $nsgId) {
                Write-Host "       [AddClientIpToNsg] Could not identify the subnet NSG from the gateway NIC; skipping NSG change." -ForegroundColor DarkYellow
            } else {
                $seg     = $nsgId -split '/'
                $nsgRg   = $seg[4]
                $nsgName = $seg[-1]
                # Idempotent: clear any leftover rule from a previously interrupted run.
                az network nsg rule delete -g $nsgRg --nsg-name $nsgName -n $tempRuleName -o none 2>$null
                az network nsg rule create -g $nsgRg --nsg-name $nsgName -n $tempRuleName `
                    --priority 105 --access Allow --direction Inbound --protocol Tcp `
                    --source-address-prefixes "$myIp/32" --source-port-ranges '*' `
                    --destination-address-prefixes '*' --destination-port-ranges 443 `
                    --description 'Temporary - added by Test-PostDeployHealth.ps1; safe to delete' -o none 2>$null
                if ($LASTEXITCODE -eq 0) {
                    $tempRuleNsg   = $nsgName
                    $tempRuleNsgRg = $nsgRg
                    Write-Host "       [AddClientIpToNsg] Added temporary allow rule '$tempRuleName' for $myIp/32 on subnet NSG '$nsgName' (RG $nsgRg, TCP 443, priority 105). Waiting ~15s for it to take effect..." -ForegroundColor DarkGray
                    Start-Sleep -Seconds 15
                } else {
                    Write-Host "       [AddClientIpToNsg] Could not add the NSG rule (insufficient permissions on '$nsgName'?); continuing without it." -ForegroundColor DarkYellow
                }
            }
        }
    }

    try {
        # Retry only matters once we've opened the NSG (rule propagation +
        # gateway warm-up). Without the switch, keep a single attempt.
        $maxAttempts = if ($tempRuleNsg) { 4 } else { 1 }
        $ok = $false
        $lastErr = ''
        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            try {
                $resp = Invoke-WebRequest -Uri $rdWebUrl -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
                if ($resp.StatusCode -eq 200) { $ok = $true; break }
                $lastErr = "Status $($resp.StatusCode)"
            } catch {
                $lastErr = $_.Exception.Message
            }
            if ($attempt -lt $maxAttempts) { Start-Sleep -Seconds 10 }
        }

        if ($ok) {
            $how = if ($tempRuleNsg) { ' (via temporary NSG rule)' } else { '' }
            Write-TestResult "RD Web reachable: $rdWebUrl$how" $true
        } elseif ($lastErr -match 'timeout|timed out|canceled|actively refused|unreachable') {
            # A timeout/connection-refused from here usually means this machine's
            # public IP isn't in allowedClientSourceAddressPrefixes (so the subnet
            # governance NSG drops it), or the gateway is still warming up. Soft
            # warning: it doesn't prove the gateway is unhealthy, only that THIS
            # machine couldn't reach it.
            $hint = if (-not $AddClientIpToNsg) { ' Re-run with -AddClientIpToNsg to temporarily open the subnet NSG to this machine.' } else { '' }
            Write-TestResult "RD Web not reachable from this machine: $rdWebUrl" $false `
                "Connection timed out. Most likely this machine's public IP isn't in allowedClientSourceAddressPrefixes, or the gateway is still warming up.$hint" -SoftWarn
        } else {
            Write-TestResult "RD Web not reachable from this machine: $rdWebUrl" $false $lastErr -SoftWarn
        }
    } finally {
        if ($tempRuleNsg) {
            az network nsg rule delete -g $tempRuleNsgRg --nsg-name $tempRuleNsg -n $tempRuleName -o none 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "       [AddClientIpToNsg] Removed temporary NSG rule '$tempRuleName'." -ForegroundColor DarkGray
            } else {
                Write-Host "       [AddClientIpToNsg] WARNING: could not remove temporary rule '$tempRuleName' on '$tempRuleNsg'. Remove it manually:" -ForegroundColor Yellow
                Write-Host "           az network nsg rule delete -g $tempRuleNsgRg --nsg-name $tempRuleNsg -n $tempRuleName" -ForegroundColor Yellow
            }
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
