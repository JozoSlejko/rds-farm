<#
.SYNOPSIS
    Create/update the vanity CNAME for the RDS gateway in Azure DNS.

.DESCRIPTION
    Automates docs/manual-deploy.md Step 7a (Azure-DNS-only path).

    Reads the deployment output `gatewayFqdn` from your `main` deployment,
    then sets a CNAME at <RecordName>.<ZoneName> pointing to it (TTL 300 by
    default). Idempotent — re-running just refreshes the record.

    Only supports Azure DNS zones (the `az network dns` API). For Cloudflare,
    Route 53, GoDaddy etc. the docs still show the manual steps; this script
    deliberately doesn't depend on third-party providers.

.PARAMETER ZoneName
    Public DNS zone you own in Azure DNS, e.g. 'contoso.com'.

.PARAMETER RecordName
    Short record name (subdomain), e.g. 'rds' for rds.contoso.com.
    Must NOT include the zone — pass the short name only.

.PARAMETER ZoneResourceGroup
    Resource group that contains the DNS zone. If omitted, the script tries
    to discover it from `az network dns zone list`.

.PARAMETER FarmResourceGroup
    RG containing the RDS deployment (where `main` deployment lives).
    Default: 'rds-farm-rg'.

.PARAMETER DeploymentName
    Name of the RDS deployment. Default: 'main'.

.PARAMETER Target
    Explicit CNAME target (FQDN of the Azure LB). Skips reading deployment
    outputs. Useful when the deployment lives in another subscription.

.PARAMETER Ttl
    Record TTL in seconds. Default: 300.

.PARAMETER Verify
    After creating the record, resolve it via Resolve-DnsName and probe
    https://<recordName>.<zoneName>/RDWeb/ for a 200/302 (3-attempt warmup).

.EXAMPLE
    .\scripts\Set-GatewayCname.ps1 -ZoneName contoso.com -RecordName rds

.EXAMPLE
    .\scripts\Set-GatewayCname.ps1 `
        -ZoneName contoso.com -RecordName rds `
        -Target contoso-rds.westeurope.cloudapp.azure.com `
        -Verify

.NOTES
    Requires:
      * 'az' signed in with 'DNS Zone Contributor' on the zone (or its RG).
      * 'Reader' on the farm RG (only when reading deployment outputs).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ZoneName,
    [Parameter(Mandatory)] [string]$RecordName,
    [string]$ZoneResourceGroup,
    [string]$FarmResourceGroup = 'rds-farm-rg',
    [string]$DeploymentName    = 'main',
    [string]$Target,
    [int]   $Ttl = 300,
    [switch]$Verify
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Tool {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required tool '$Name' was not found in PATH."
    }
}

# ---------------------------------------------------------------------------
# 0. Pre-flight
# ---------------------------------------------------------------------------
Write-Host "==> Pre-flight" -ForegroundColor Cyan
Assert-Tool 'az'

if ($RecordName -like "*.$ZoneName") {
    throw "Pass the SHORT record name (e.g. 'rds') — not the FQDN '$RecordName'."
}

$ctx = az account show -o json 2>$null | ConvertFrom-Json
if (-not $ctx) { throw "Not logged in to Azure. Run 'az login' first." }
Write-Host "    Subscription : $($ctx.name)"

# ---------------------------------------------------------------------------
# 1. Locate the DNS zone
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "==> Step 1: Locate DNS zone $ZoneName" -ForegroundColor Green
if (-not $ZoneResourceGroup) {
    $zone = az network dns zone list --query "[?name=='$ZoneName'] | [0]" -o json | ConvertFrom-Json
    if (-not $zone) { throw "DNS zone '$ZoneName' not found in this subscription. Pass -ZoneResourceGroup explicitly." }
    $ZoneResourceGroup = $zone.resourceGroup
    Write-Host "    Auto-discovered RG: $ZoneResourceGroup"
} else {
    az network dns zone show -g $ZoneResourceGroup -n $ZoneName -o none
    if ($LASTEXITCODE -ne 0) { throw "DNS zone '$ZoneName' not found in '$ZoneResourceGroup'." }
}

# ---------------------------------------------------------------------------
# 2. Determine the CNAME target
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "==> Step 2: Determine target FQDN" -ForegroundColor Green
if (-not $Target) {
    Write-Host "    Reading gatewayFqdn from $FarmResourceGroup/$DeploymentName..."
    $Target = az deployment group show -g $FarmResourceGroup -n $DeploymentName --query properties.outputs.gatewayFqdn.value -o tsv
    if ($LASTEXITCODE -ne 0 -or -not $Target) {
        throw "Could not read gatewayFqdn from deployment '$DeploymentName' in RG '$FarmResourceGroup'. Pass -Target explicitly."
    }
}
$fqdn = "$RecordName.$ZoneName"
Write-Host "    $fqdn -> $Target"

# ---------------------------------------------------------------------------
# 3. Write the record
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "==> Step 3: Set CNAME (TTL=$Ttl)" -ForegroundColor Green

# set-record is idempotent — creates the record set if missing and adds/refreshes the CNAME.
az network dns record-set cname set-record `
    --resource-group $ZoneResourceGroup `
    --zone-name      $ZoneName `
    --record-set-name $RecordName `
    --cname          $Target `
    --ttl            $Ttl | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Failed to set CNAME." }
Write-Host "    Done."

# ---------------------------------------------------------------------------
# 4. Optional verify
# ---------------------------------------------------------------------------
if ($Verify) {
    Write-Host ""
    Write-Host "==> Step 4: Verify resolution + RD Web reachability" -ForegroundColor Green

    Start-Sleep -Seconds 5
    try {
        $r = Resolve-DnsName -Name $fqdn -Type CNAME -ErrorAction Stop
        Write-Host "    CNAME lookup OK: $($r | Where-Object Type -eq 'CNAME' | Select-Object -First 1 -ExpandProperty NameHost)"
    } catch {
        Write-Warning "    CNAME not resolving yet (TTL=$Ttl). Wait $Ttl seconds and try Resolve-DnsName $fqdn."
    }

    $url = "https://$fqdn/RDWeb/"
    for ($i = 1; $i -le 3; $i++) {
        try {
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10 -MaximumRedirection 0 -ErrorAction Stop
            Write-Host "    HTTP $($resp.StatusCode) from $url"
            break
        } catch {
            Write-Host "    Attempt $i/3: $($_.Exception.Message)"
            if ($i -lt 3) { Start-Sleep -Seconds 5 }
        }
    }
}

Write-Host ""
Write-Host "==================== Done ====================" -ForegroundColor Green
Write-Host "Record  : $fqdn"
Write-Host "Target  : $Target"
Write-Host "TTL     : $Ttl"
Write-Host ""
Write-Host "Reminder:" -ForegroundColor Cyan
Write-Host "  Cert Subject/SAN must match '$fqdn'. If you haven't issued the cert yet,"
Write-Host "  run scripts/New-RdsCertificate.ps1 with -Fqdn '$fqdn'."
