<#
.SYNOPSIS
    Tear down the RDS farm resource group (and optionally prereqs RGs).

.DESCRIPTION
    Destructive cleanup helper for lab/dev. Deletes:
      * The farm RG (default 'rds-farm-rg').
      * Optionally the artifacts RG ('rds-artifacts-rg' by default).
      * Optionally the security RG ('rds-security-rg' by default).

    Safety:
      * --confirm is OFF by default — you'll be prompted to type 'yes' for
        each RG. Pass -Force to skip the prompts.
      * Before deleting an RG, lists its resources so you see what goes.
      * Warns (and refuses without -Force) if any Key Vault in the RG has
        purgeProtection = true — deletion will fail, and even if it succeeds
        the vault name stays reserved for 90 days.
      * Does NOT touch your VNet, AD, DNS zones, Entra app, GitHub secrets,
        or anything in user-managed RGs.

.PARAMETER ResourceGroup
    The farm RG to delete. Default: 'rds-farm-rg'.

.PARAMETER IncludeArtifactsRg
    Also delete the artifacts RG.

.PARAMETER ArtifactsResourceGroup
    Default: 'rds-artifacts-rg'. Used when -IncludeArtifactsRg.

.PARAMETER IncludeSecurityRg
    Also delete the security RG (Key Vault home).

.PARAMETER SecurityResourceGroup
    Default: 'rds-security-rg'. Used when -IncludeSecurityRg.

.PARAMETER Force
    Skip all confirmation prompts and the purge-protection veto.
    Useful only in fully scripted lab teardowns.

.EXAMPLE
    # Just the farm — leaves SA + KV intact for the next deploy
    .\scripts\Remove-RdsFarm.ps1

.EXAMPLE
    # Full lab wipe (will still pause if any KV has purgeProtection)
    .\scripts\Remove-RdsFarm.ps1 -IncludeArtifactsRg -IncludeSecurityRg

.NOTES
    Requires Contributor on each target RG.
    Soft-delete + purge-protection on Key Vaults reserve the vault NAME for
    90 days even after the RG is gone — pick a different keyVaultName next
    time, or use 'az keyvault purge' (refused while purgeProtection=true).
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup           = 'rds-farm-rg',
    [switch]$IncludeArtifactsRg,
    [string]$ArtifactsResourceGroup  = 'rds-artifacts-rg',
    [switch]$IncludeSecurityRg,
    [string]$SecurityResourceGroup   = 'rds-security-rg',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Tool {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required tool '$Name' was not found in PATH."
    }
}

function Remove-RgIfRequested {
    param(
        [string]$Name,
        [switch]$WarnPurgeProtect
    )

    if (-not $Name) { return }

    Write-Host ""
    Write-Host "==> Inspecting RG '$Name'" -ForegroundColor Cyan
    $exists = (az group exists -n $Name) -eq 'true'
    if (-not $exists) {
        Write-Host "    RG '$Name' does not exist — nothing to delete."
        return
    }

    $resources = az resource list -g $Name --query "[].{type:type,name:name}" -o json | ConvertFrom-Json
    if (-not $resources) {
        Write-Host "    RG is empty."
    } else {
        Write-Host "    Contains $($resources.Count) resource(s):"
        $resources | ForEach-Object { Write-Host ("      - {0,-55} {1}" -f $_.type, $_.name) }
    }

    if ($WarnPurgeProtect) {
        $vaults = az keyvault list -g $Name --query "[].{name:name, purge:properties.enablePurgeProtection}" -o json | ConvertFrom-Json
        $protected = @($vaults | Where-Object { $_.purge })
        if ($protected.Count -gt 0) {
            Write-Host ""
            Write-Host "    WARNING: $($protected.Count) Key Vault(s) have purgeProtection=true:" -ForegroundColor Yellow
            $protected | ForEach-Object { Write-Host "      - $($_.name)" -ForegroundColor Yellow }
            Write-Host "    The RG delete WILL FAIL until you remove the vaults manually," -ForegroundColor Yellow
            Write-Host "    and even then the vault NAME is reserved for 90 days." -ForegroundColor Yellow
            if (-not $Force) {
                Write-Host "    Refusing to delete '$Name' (pass -Force to override)." -ForegroundColor Red
                return
            }
        }
    }

    if (-not $Force) {
        $answer = Read-Host "    Type 'yes' to DELETE RG '$Name' (anything else aborts)"
        if ($answer -ne 'yes') {
            Write-Host "    Skipped." -ForegroundColor Yellow
            return
        }
    }

    Write-Host "    Deleting (no-wait)..."
    az group delete --name $Name --yes --no-wait
    if ($LASTEXITCODE -ne 0) {
        Write-Host "    Delete request returned $LASTEXITCODE." -ForegroundColor Red
    } else {
        Write-Host "    Delete in progress. Track with: az group show -n $Name" -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------
# 0. Pre-flight
# ---------------------------------------------------------------------------
Write-Host "==> Pre-flight" -ForegroundColor Cyan
Assert-Tool 'az'

$ctx = az account show -o json 2>$null | ConvertFrom-Json
if (-not $ctx) { throw "Not logged in to Azure. Run 'az login' first." }
Write-Host "    Subscription : $($ctx.name) ($($ctx.id))"
Write-Host ""
Write-Host "This will delete:" -ForegroundColor Yellow
Write-Host "  - $ResourceGroup (farm)"
if ($IncludeArtifactsRg) { Write-Host "  - $ArtifactsResourceGroup (artifacts SA)" }
if ($IncludeSecurityRg)  { Write-Host "  - $SecurityResourceGroup (Key Vault)" }
Write-Host ""
Write-Host "Will NOT touch: your VNet, AD, DNS zones, Entra app, GitHub secrets, or anything outside these RGs." -ForegroundColor Cyan

Remove-RgIfRequested -Name $ResourceGroup
if ($IncludeArtifactsRg) { Remove-RgIfRequested -Name $ArtifactsResourceGroup }
if ($IncludeSecurityRg)  { Remove-RgIfRequested -Name $SecurityResourceGroup -WarnPurgeProtect }

Write-Host ""
Write-Host "==================== Done ====================" -ForegroundColor Green
