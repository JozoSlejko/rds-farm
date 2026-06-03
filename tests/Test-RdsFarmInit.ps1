<#
.SYNOPSIS
    Verify everything Initialize-RdsFarm.ps1 set up (one command, single PASS/FAIL).

.DESCRIPTION
    Read-only wrapper around the three existing Tier-0 verifiers. Initialize-
    RdsFarm.ps1 is the "doer" — it does not re-read its work after the fact.
    This script is the "checker": run it any time you want to confirm Tier 0
    is still intact (e.g. after someone "fixed" a role assignment by hand, or
    before you fire a manual deploy from a fresh shell).

    It composes:

      1. tests/Test-CiPrerequisites.ps1
         Entra app + SP, federated credentials, sub-scope role assignments,
         5 repo secrets, ARTIFACTS_STORAGE_ACCOUNT repo variable + the SA it
         points at, 'preview' and 'production' GitHub environments.

      2. tests/Test-BicepParamValues.ps1
         main.bicepparam compiles (with readEnvironmentVariable resolution),
         guard-rails hold (no 0.0.0.0/0, valid AD DNS IP, NetBIOS-safe naming,
         KV cert URI shape when enableCertificateBinding = true).

      3. tests/Test-PreDeployReadiness.ps1
         Existing VNet + RDS subnet present with enough usable IPs,
         Key Vault exists & is in RBAC mode, the referenced cert exists,
         policy has exportable = true, cert is not within 30 days of expiry,
         (optional) `az deployment group validate` passes against the target RG.

    Each child script is invoked in-process; its native exit code is captured
    and reported. Final summary lists which sections passed / failed and exits
    non-zero if any section failed (warnings inside PreDeployReadiness do NOT
    fail this wrapper — they only fail their own script when severe).

.PARAMETER GitHubRepo
    <owner>/<repo>. Forwarded to Test-CiPrerequisites.ps1.

.PARAMETER AppDisplayName
    Entra app display name. Default 'gh-rds-farm-deploy'. Forwarded to
    Test-CiPrerequisites.ps1.

.PARAMETER SubscriptionId
    Optional. Forwarded to Test-CiPrerequisites.ps1; the other two scripts
    use the active 'az' subscription.

.PARAMETER ResourceGroup
    Target farm RG. Default 'rds-farm-rg'. Forwarded to Test-PreDeployReadiness.ps1.

.PARAMETER Location
    Region forwarded to Test-PreDeployReadiness.ps1 for its implicit
    `az group create` when the target RG doesn't yet exist. Empty by
    default - reuse the existing RG's region (auto-detected) or pass
    explicitly when bootstrapping a fresh deployment.

.PARAMETER BicepParamFile
    Path to main.bicepparam. Default <repo>/main.bicepparam.

.PARAMETER BicepFile
    Path to main.bicep. Default <repo>/main.bicep.

.PARAMETER SkipBicepValidate
    Forwarded to Test-PreDeployReadiness.ps1. Use when you do not have
    rights to create the target RG locally.

.PARAMETER SkipCi
    Skip Test-CiPrerequisites.ps1 (use when you ran Initialize-RdsFarm.ps1
    with -SkipCiBootstrap or you do not have 'gh' available).

.PARAMETER SkipPreDeploy
    Skip Test-PreDeployReadiness.ps1 (use when KV / VNet are in a subscription
    you cannot reach right now and you only want to validate the bicepparam).

.EXAMPLE
    .\tests\Test-RdsFarmInit.ps1 -GitHubRepo contoso/rds-farm

.EXAMPLE
    # Bicepparam-only check (no Azure reachability required)
    .\tests\Test-RdsFarmInit.ps1 -GitHubRepo contoso/rds-farm -SkipCi -SkipPreDeploy

.NOTES
    Requires: 'az' signed in with Reader on the target RG + VNet RG + KV RG,
    plus 'gh' signed in with 'repo' scope (unless -SkipCi).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[^/]+/[^/]+$')]
    [string]$GitHubRepo,

    [string]$AppDisplayName = 'gh-rds-farm-deploy',
    [string]$SubscriptionId,

    [string]$ResourceGroup  = 'rds-farm-rg',
    [string]$Location       = '',

    [string]$BicepParamFile = (Join-Path $PSScriptRoot '..' 'main.bicepparam'),
    [string]$BicepFile      = (Join-Path $PSScriptRoot '..' 'main.bicep'),

    [switch]$SkipBicepValidate,
    [switch]$SkipCi,
    [switch]$SkipPreDeploy
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Invoke-Section {
    <#
        Runs one child verifier in-process, captures its exit code, and
        records a row in $results. We use the call operator so the child
        script's [CmdletBinding()] + parameter binding works the same way
        as a direct invocation, and we read $LASTEXITCODE because the
        children use 'exit N' on failure.
    #>
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$ScriptPath,
        [hashtable]$Arguments = @{}
    )

    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor Cyan
    Write-Host ("==> {0}" -f $Name) -ForegroundColor Cyan
    Write-Host ("    {0}" -f $ScriptPath) -ForegroundColor DarkGray
    Write-Host ('=' * 70) -ForegroundColor Cyan

    $global:LASTEXITCODE = 0
    try {
        & $ScriptPath @Arguments
        $exit = $LASTEXITCODE
        $err  = $null
    } catch {
        $exit = if ($LASTEXITCODE) { $LASTEXITCODE } else { 1 }
        $err  = $_.Exception.Message
    }

    [pscustomobject]@{
        Name      = $Name
        Ok        = ($exit -eq 0)
        ExitCode  = $exit
        Error     = $err
    }
}

# ---------------------------------------------------------------------------
# Resolve child script paths up-front so we fail fast if any are missing.
# ---------------------------------------------------------------------------

$ciScript        = Join-Path $PSScriptRoot 'Test-CiPrerequisites.ps1'
$paramScript     = Join-Path $PSScriptRoot 'Test-BicepParamValues.ps1'
$preDeployScript = Join-Path $PSScriptRoot 'Test-PreDeployReadiness.ps1'

foreach ($p in @($ciScript, $paramScript, $preDeployScript)) {
    if (-not (Test-Path -LiteralPath $p)) {
        throw "Required child script not found: $p"
    }
}

Write-Host ''
Write-Host 'Verifying Tier 0 (Initialize-RdsFarm.ps1) output' -ForegroundColor Green
Write-Host ("  GitHub repo     : {0}" -f $GitHubRepo)
Write-Host ("  App display     : {0}" -f $AppDisplayName)
Write-Host ('  Target RG       : {0}{1}' -f $ResourceGroup, $(if ($Location) { " ($Location)" } else { '' }))
Write-Host ("  Bicepparam      : {0}" -f $BicepParamFile)
if ($SkipCi)        { Write-Host '  [skip] CI prerequisites check' -ForegroundColor DarkYellow }
if ($SkipPreDeploy) { Write-Host '  [skip] Pre-deploy readiness check' -ForegroundColor DarkYellow }

$results = New-Object System.Collections.Generic.List[pscustomobject]

# ---------------------------------------------------------------------------
# 1. CI prerequisites
# ---------------------------------------------------------------------------
if (-not $SkipCi) {
    $ciArgs = @{
        GitHubRepo     = $GitHubRepo
        AppDisplayName = $AppDisplayName
    }
    if ($SubscriptionId) { $ciArgs['SubscriptionId'] = $SubscriptionId }

    $results.Add( (Invoke-Section -Name 'CI prerequisites' -ScriptPath $ciScript -Arguments $ciArgs) ) | Out-Null
}

# ---------------------------------------------------------------------------
# 2. Bicepparam values
# ---------------------------------------------------------------------------
$paramArgs = @{ ParamFile = $BicepParamFile }
$results.Add( (Invoke-Section -Name 'Bicepparam values' -ScriptPath $paramScript -Arguments $paramArgs) ) | Out-Null

# ---------------------------------------------------------------------------
# 3. Pre-deploy readiness (KV + cert + subnet + validate)
# ---------------------------------------------------------------------------
if (-not $SkipPreDeploy) {
    $preArgs = @{
        ResourceGroup  = $ResourceGroup
        BicepFile      = $BicepFile
        BicepParamFile = $BicepParamFile
    }
    if ($Location)          { $preArgs['Location']          = $Location }
    if ($SkipBicepValidate) { $preArgs['SkipBicepValidate'] = $true }

    $results.Add( (Invoke-Section -Name 'Pre-deploy readiness' -ScriptPath $preDeployScript -Arguments $preArgs) ) | Out-Null
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host ('=' * 70) -ForegroundColor Cyan
Write-Host '==> Summary' -ForegroundColor Cyan
Write-Host ('=' * 70) -ForegroundColor Cyan

foreach ($r in $results) {
    if ($r.Ok) {
        Write-Host ("  [PASS] {0}" -f $r.Name) -ForegroundColor Green
    } else {
        $detail = if ($r.Error) { $r.Error } else { "exit code $($r.ExitCode)" }
        Write-Host ("  [FAIL] {0}  ({1})" -f $r.Name, $detail) -ForegroundColor Red
    }
}

$failed = @($results | Where-Object { -not $_.Ok })
Write-Host ''
if ($failed.Count -eq 0) {
    Write-Host ("Tier 0 verification passed ({0} section(s))." -f $results.Count) -ForegroundColor Green
    exit 0
}

Write-Host ("Tier 0 verification FAILED: {0} of {1} section(s) failed." -f $failed.Count, $results.Count) -ForegroundColor Red
Write-Host 'Re-run the failing section by hand for the detailed per-check output.' -ForegroundColor Yellow
exit 1
