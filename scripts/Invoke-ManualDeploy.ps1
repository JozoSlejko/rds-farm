<#
.SYNOPSIS
    End-to-end manual deployment wrapper for the RDS farm (no CI required).

.DESCRIPTION
    Replaces the four-step recipe in docs/manual-deploy.md with a single command.
    Mirrors what the GitHub Actions workflow does but runs on your laptop:

      1. Read passwords interactively (Read-Host -AsSecureString) unless
         already present in the environment.
      2. Call scripts/Publish-DscArtifact.ps1 to zip + upload + mint SAS.
      3. Set DOMAIN_JOIN_PASSWORD / LOCAL_ADMIN_PASSWORD / ARTIFACTS_SAS
         in the process environment (so bicepparam's readEnvironmentVariable
         calls resolve).
      4. Ensure the target resource group exists.
      5. Run tests/Test-PreDeployReadiness.ps1 (same checks the pipeline's
         `pre-deploy-checks` job runs - VNet/subnet sizing, KV+cert, SAS
         reachability, az deployment group validate). Skip with
         -SkipReadinessCheck.
      6. Run 'az deployment group what-if' (always) and, if -Action deploy,
         then 'az deployment group create'.
      7. Print the deployment outputs (gatewayFqdn, rdWebUrl, etc.).

    The script never echoes secrets and never persists them to disk.

.PARAMETER Action
    'what-if' (default) — preview only.
    'deploy'  — run what-if first, then actually deploy.

.PARAMETER StorageAccount
    Artifacts storage account name. Same resolution order as
    Publish-DscArtifact.ps1 (parameter -> -Repo lookup -> env var).

.PARAMETER ResourceGroup
    Target resource group. Default: 'rds-farm-rg'.

.PARAMETER Location
    Azure region for `az group create`. Default: 'westeurope'.

.PARAMETER BicepFile
    Path to the main Bicep template. Default: <repo>/main.bicep.

.PARAMETER BicepParamFile
    Path to main.bicepparam. Default: <repo>/main.bicepparam.

.PARAMETER Repo
    Optional <org>/<repo>. Forwarded to Publish-DscArtifact.ps1 when
    -StorageAccount is omitted.

.PARAMETER SkipPublish
    Reuse existing $env:ARTIFACTS_LOCATION + $env:ARTIFACTS_SAS instead of
    re-uploading. Useful when iterating on Bicep without touching DSC.

.PARAMETER SkipWhatIf
    Go straight to deploy without running what-if first. Use sparingly.

.PARAMETER SkipReadinessCheck
    Skip the tests/Test-PreDeployReadiness.ps1 gate that runs the same checks
    the pipeline's `pre-deploy-checks` job runs (VNet/subnet sizing, Key Vault
    + cert sanity, SAS reachability, `az deployment group validate`). Skip only
    when you have a known-bad config you're explicitly trying to deploy.

.EXAMPLE
    # Preview a manual deployment
    .\scripts\Invoke-ManualDeploy.ps1 -StorageAccount contosordsart01

.EXAMPLE
    # Full manual deploy from this laptop
    .\scripts\Invoke-ManualDeploy.ps1 `
        -Action deploy `
        -StorageAccount contosordsart01 `
        -ResourceGroup rds-farm-rg

.NOTES
    Requires:
      * 'az' signed in with Contributor on the target RG.
      * 'Storage Blob Data Contributor' on the artifacts SA (for Publish step).
      * 'Key Vault Certificates Officer' on the vault (only if
        enableCertificateBinding = true, to let validate read cert metadata).
      * PowerShell 7+.
#>
[CmdletBinding()]
param(
    [ValidateSet('what-if','deploy')]
    [string]$Action = 'what-if',

    [string]$StorageAccount,
    [string]$ResourceGroup = 'rds-farm-rg',
    [string]$Location      = 'westeurope',

    [string]$BicepFile      = (Join-Path $PSScriptRoot '..' 'main.bicep'),
    [string]$BicepParamFile = (Join-Path $PSScriptRoot '..' 'main.bicepparam'),

    [ValidatePattern('^[^/]+/[^/]+$')]
    [string]$Repo,

    [switch]$SkipPublish,
    [switch]$SkipWhatIf,
    [switch]$SkipReadinessCheck
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Helpers (same primitives as Initialize-CiPrerequisites.ps1)
# ---------------------------------------------------------------------------
function Assert-Tool {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required tool '$Name' was not found in PATH."
    }
}

function ConvertFrom-SecureStringPlain {
    param([System.Security.SecureString]$Secure)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try   { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Read-SecretIfMissing {
    param([string]$EnvVar, [string]$Prompt)
    if ([Environment]::GetEnvironmentVariable($EnvVar)) {
        Write-Host "    $EnvVar already set in environment — keeping it."
        return
    }
    $secure = Read-Host -Prompt "    $Prompt" -AsSecureString
    try {
        $plain = ConvertFrom-SecureStringPlain $secure
        [Environment]::SetEnvironmentVariable($EnvVar, $plain, 'Process')
    } finally {
        $plain  = $null
        [GC]::Collect()
    }
}

# ---------------------------------------------------------------------------
# 0. Pre-flight
# ---------------------------------------------------------------------------
Write-Host "==> Pre-flight" -ForegroundColor Cyan
Assert-Tool 'az'

$BicepFile      = (Resolve-Path -LiteralPath $BicepFile).Path
$BicepParamFile = (Resolve-Path -LiteralPath $BicepParamFile).Path
foreach ($f in @($BicepFile, $BicepParamFile)) {
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { throw "File not found: $f" }
}
Write-Host "    Template     : $BicepFile"
Write-Host "    Parameters   : $BicepParamFile"

$ctx = az account show -o json 2>$null | ConvertFrom-Json
if (-not $ctx) { throw "Not logged in to Azure. Run 'az login' first." }
Write-Host "    Subscription : $($ctx.name) ($($ctx.id))"
Write-Host "    Action       : $Action"
Write-Host "    Resource grp : $ResourceGroup (in $Location)"

# ---------------------------------------------------------------------------
# 1. Secrets
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "==> Step 1: Deployment secrets" -ForegroundColor Green
Read-SecretIfMissing -EnvVar 'DOMAIN_JOIN_PASSWORD' -Prompt 'DOMAIN_JOIN_PASSWORD'
Read-SecretIfMissing -EnvVar 'LOCAL_ADMIN_PASSWORD' -Prompt 'LOCAL_ADMIN_PASSWORD'

# ---------------------------------------------------------------------------
# 2. Publish DSC artifact
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "==> Step 2: Publish DSC artifact" -ForegroundColor Green
if ($SkipPublish) {
    if (-not $env:ARTIFACTS_LOCATION -or -not $env:ARTIFACTS_SAS) {
        throw "-SkipPublish set but `$env:ARTIFACTS_LOCATION / `$env:ARTIFACTS_SAS not present."
    }
    Write-Host "    -SkipPublish: reusing existing env vars."
} else {
    $publishArgs = @{ SetEnvVars = $true }
    if ($StorageAccount) { $publishArgs.StorageAccount = $StorageAccount }
    if ($Repo)           { $publishArgs.Repo           = $Repo }
    $publishScript = Join-Path $PSScriptRoot 'Publish-DscArtifact.ps1'
    & $publishScript @publishArgs | Out-Null
}
Write-Host "    ArtifactsLocation = $env:ARTIFACTS_LOCATION"

# ---------------------------------------------------------------------------
# 3. Ensure RG
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "==> Step 3: Ensure resource group" -ForegroundColor Green
az group create -n $ResourceGroup -l $Location -o none
if ($LASTEXITCODE -ne 0) { throw "Failed to create/ensure RG $ResourceGroup." }
Write-Host "    OK"

# ---------------------------------------------------------------------------
# 4. Pre-deploy readiness (same checks as the pipeline's pre-deploy-checks job)
# ---------------------------------------------------------------------------
if (-not $SkipReadinessCheck) {
    Write-Host ""
    Write-Host "==> Step 4: Pre-deploy readiness" -ForegroundColor Green
    $readiness = Join-Path $PSScriptRoot '..' 'tests' 'Test-PreDeployReadiness.ps1'
    if (Test-Path -LiteralPath $readiness) {
        & $readiness -ResourceGroup $ResourceGroup -Location $Location `
            -BicepFile $BicepFile -BicepParamFile $BicepParamFile
        if ($LASTEXITCODE -ne 0) {
            throw "Pre-deploy readiness check FAILED (exit $LASTEXITCODE). Fix the issues above or rerun with -SkipReadinessCheck if you know better."
        }
        Write-Host "    All readiness checks passed."
    } else {
        Write-Host "    [WARN] tests/Test-PreDeployReadiness.ps1 not found - skipping." -ForegroundColor Yellow
    }
} else {
    Write-Host ""
    Write-Host "==> Step 4: Pre-deploy readiness SKIPPED (per -SkipReadinessCheck)" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# 5. What-if (unless suppressed) + optional deploy
# ---------------------------------------------------------------------------
$commonArgs = @(
    '--resource-group', $ResourceGroup,
    '--template-file',  $BicepFile,
    '--parameters',     $BicepParamFile,
    '--parameters',     "artifactsLocation=$($env:ARTIFACTS_LOCATION)"
)

if (-not $SkipWhatIf) {
    Write-Host ""
    Write-Host "==> Step 5a: what-if" -ForegroundColor Green
    az deployment group what-if @commonArgs
    if ($LASTEXITCODE -ne 0) { throw "what-if failed (exit $LASTEXITCODE)." }
}

if ($Action -eq 'deploy') {
    Write-Host ""
    Write-Host "==> Step 5b: deploy" -ForegroundColor Green
    $depName = "main-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss')
    $outputsJson = az deployment group create `
        --name $depName `
        @commonArgs `
        --query properties.outputs `
        -o json
    if ($LASTEXITCODE -ne 0) { throw "deploy failed (exit $LASTEXITCODE)." }

    Write-Host ""
    Write-Host "==================== Deployed ====================" -ForegroundColor Green
    Write-Host "Deployment name : $depName"
    if ($outputsJson) {
        $o = $outputsJson | ConvertFrom-Json
        foreach ($prop in $o.PSObject.Properties) {
            Write-Host ("{0,-22}: {1}" -f $prop.Name, $prop.Value.value)
        }
        Write-Host ""
        Write-Host "Next:" -ForegroundColor Cyan
        Write-Host "  * Create the CNAME (vanity FQDN): scripts/Set-GatewayCname.ps1"
        Write-Host "  * Run smoke tests              : tests/Test-PostDeployHealth.ps1 -ResourceGroupName $ResourceGroup"
    }
} else {
    Write-Host ""
    Write-Host "what-if complete. Re-run with -Action deploy to apply." -ForegroundColor Cyan
}
