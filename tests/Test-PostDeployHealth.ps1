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
      3. Load Balancer backend health probe shows the gateway pool Up.
      4. gatewayFqdn DNS resolves.
      5. https://<gatewayFqdn>/RDWeb/ returns 200 (soft warn if the runner's
         egress IP isn't in allowedClientSourceAddressPrefixes).
      6. If publicGatewayFqdn differs from gatewayFqdn, DNS for the vanity
         hostname is also checked.

    Exits non-zero on any HARD failure (categories 1-3); category 5 is a soft
    warning so the test still passes from a runner that isn't in the allow-list.

.PARAMETER ResourceGroupName
    The RG that contains the deployment.

.PARAMETER DeploymentName
    The deployment name to read outputs from (default 'main').

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

# 0. Deployment outputs
$outputsJson = az deployment group show -g $ResourceGroupName -n $DeploymentName --query properties.outputs -o json 2>$null
if ($LASTEXITCODE -ne 0 -or -not $outputsJson) {
    Write-TestResult "Deployment '$DeploymentName' exists in $ResourceGroupName" $false
    exit 1
}
$outputs = $outputsJson | ConvertFrom-Json
$gatewayFqdn       = $outputs.gatewayFqdn.value
$publicGatewayFqdn = $outputs.publicGatewayFqdn.value
Write-Host "Gateway FQDN (LB):     $gatewayFqdn"
Write-Host "Public gateway FQDN:   $publicGatewayFqdn"
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
$vmHealthFailures = @()
foreach ($id in $vmIds) {
    $name = $id | Split-Path -Leaf
    $h = az rest --method get `
        --uri "https://management.azure.com$id/providers/Microsoft.ResourceHealth/availabilityStatuses/current?api-version=2023-07-01" `
        -o json 2>$null | ConvertFrom-Json
    $state = $h.properties.availabilityState
    if ($state -ne 'Available') { $vmHealthFailures += "${name}=$state" }
}
if ($vmHealthFailures.Count -gt 0) {
    Write-TestResult 'Resource Health = Available for all VMs' $false ($vmHealthFailures -join '; ')
} else {
    Write-TestResult "Resource Health = Available for all $($vmIds.Count) VMs" $true
}

# 3. Load Balancer backend health
$lbId = az network lb list -g $ResourceGroupName --query "[0].id" -o tsv
if (-not $lbId) {
    Write-TestResult 'Load Balancer present' $false
} else {
    $healthJson = az rest --method get --uri "https://management.azure.com$lbId/backendHealth?api-version=2024-05-01" -o json 2>$null
    if ($LASTEXITCODE -eq 0 -and $healthJson) {
        $bh = $healthJson | ConvertFrom-Json
        $allUp = $true
        foreach ($pool in $bh.backendAddressPools) {
            foreach ($addr in $pool.backendAddresses) {
                if ($addr.health.healthStatus -ne 'Up') {
                    $allUp = $false
                    Write-Host "       Backend $($addr.networkInterfaceIPConfiguration.id | Split-Path -Leaf) = $($addr.health.healthStatus) ($($addr.health.healthStatusDetails))" -ForegroundColor DarkYellow
                }
            }
        }
        Write-TestResult 'LB backend pool health = Up' $allUp
    } else {
        Write-TestResult 'LB backend pool health = Up' $false 'Could not query backendHealth'
    }
}

# 4. DNS resolution
try {
    $null = [System.Net.Dns]::GetHostAddresses($gatewayFqdn)
    Write-TestResult "DNS resolves: $gatewayFqdn" $true
} catch {
    Write-TestResult "DNS resolves: $gatewayFqdn" $false $_.Exception.Message
}

# 5. RD Web URL reachability — soft warn (runner may not be in allow-list)
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
    # Timeout / connect-refused is most likely the runner's egress IP isn't in allowedClientSourceAddressPrefixes.
    Write-TestResult "RD Web reachable: $rdWebUrl (runner may not be in allow-list)" $false $msg -SoftWarn
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
