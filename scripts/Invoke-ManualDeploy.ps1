<#
.SYNOPSIS
    End-to-end manual deployment wrapper for the RDS farm (no CI required).

.DESCRIPTION
    Replaces the four-step recipe in docs/manual-deploy.md with a single command.
    Mirrors what the GitHub Actions workflow does but runs from your in-VNet host
    (jumpbox / DC; the private-endpoint-only KV/SA aren't reachable from a plain laptop):

      1. Read passwords interactively (Read-Host -AsSecureString) unless
         already present in the environment.
      2. Call scripts/Publish-DscArtifact.ps1 to zip + upload Configuration.zip.
         The DSC extension reads it back at apply-time using the VM's user-
         assigned managed identity (Storage Blob Data Reader on the SA).
      3. Set DOMAIN_JOIN_PASSWORD / LOCAL_ADMIN_PASSWORD in the process
         environment (so bicepparam's readEnvironmentVariable calls resolve).
      4. Ensure the target resource group exists.
      5. Run tests/Test-PreDeployReadiness.ps1 (same checks the pipeline's
         `pre-deploy-checks` job runs - VNet/subnet sizing, KV+cert, blob
         reachability via MSI auth, az deployment group validate). Skip with
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
    Azure region to use when CREATING the resource group. If the RG already
    exists the script auto-discovers its location and reuses it (RG location
    is immutable in Azure). When omitted on a fresh deployment, the script
    falls back to $env:AZURE_LOCATION; if neither is set it errors out
    instead of guessing.

.PARAMETER BicepFile
    Path to the main Bicep template. Default: <repo>/main.bicep.

.PARAMETER BicepParamFile
    Path to main.bicepparam. Default: <repo>/main.bicepparam.

.PARAMETER Repo
    Optional <org>/<repo>. Forwarded to Publish-DscArtifact.ps1 when
    -StorageAccount is omitted.

.PARAMETER SkipPublish
    Reuse the existing $env:ARTIFACTS_LOCATION instead of re-uploading.
    Useful when iterating on Bicep without touching DSC.

.PARAMETER SkipWhatIf
    Go straight to deploy without running what-if first. Use sparingly.

.PARAMETER SkipReadinessCheck
    Skip the tests/Test-PreDeployReadiness.ps1 gate that runs the same checks
    the pipeline's `pre-deploy-checks` job runs (VNet/subnet sizing, Key Vault
    + cert sanity, blob reachability via MSI auth, `az deployment group
    validate`). Skip only when you have a known-bad config you're explicitly
    trying to deploy.

.PARAMETER SkipPostDeployTest
    Skip the automatic tests/Test-PostDeployHealth.ps1 smoke test that runs
    after a successful `-Action deploy`. By default the wrapper runs it so the
    jumpbox flow is deploy-and-verify in one command (the CI post-deploy job
    can't run — the runner is outside the VNet). A non-zero test result is
    surfaced but does not fail the deploy (the farm is already deployed).

.PARAMETER AddClientIpToNsg
    Forwarded to the post-deploy smoke test. Temporarily opens the subnet
    governance NSG to this machine's public IP so the RD Web reachability
    check can pass from a host that isn't in allowedClientSourceAddressPrefixes,
    then removes the rule. No effect with -SkipPostDeployTest or -Action what-if.

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
    [string]$Location      = '',

    [string]$BicepFile      = (Join-Path $PSScriptRoot '..' 'main.bicep'),
    [string]$BicepParamFile = (Join-Path $PSScriptRoot '..' 'main.bicepparam'),

    [ValidatePattern('^[^/]+/[^/]+$')]
    [string]$Repo,

    [switch]$SkipPublish,
    [switch]$SkipWhatIf,
    [switch]$SkipReadinessCheck,
    [switch]$SkipPostDeployTest,
    [switch]$AddClientIpToNsg
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
Write-Host "    Resource grp : $ResourceGroup$( if ($Location) { " (target region: $Location)" })"

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
    if (-not $env:ARTIFACTS_LOCATION) {
        throw "-SkipPublish set but `$env:ARTIFACTS_LOCATION not present."
    }
    Write-Host "    -SkipPublish: reusing existing ARTIFACTS_LOCATION."
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

# RG location is immutable in Azure. Don't try to "create" an existing RG in a
# different region (az group create with -l != existing.location fails with
# InvalidResourceGroupLocation). Instead: if it exists, adopt its location; if
# it doesn't, demand -Location (or $env:AZURE_LOCATION) and create.
$rgExists = (az group exists -n $ResourceGroup) -eq 'true'
if ($rgExists) {
    $rgInfo = az group show -n $ResourceGroup -o json | ConvertFrom-Json
    $discoveredLocation = $rgInfo.location
    if ($Location -and ($Location -ne $discoveredLocation)) {
        throw "RG '$ResourceGroup' already exists in '$discoveredLocation' but -Location is '$Location'. " +
              "RG location is immutable. Drop -Location to reuse the existing region, or use a different RG."
    }
    $Location = $discoveredLocation
    Write-Host "    RG $ResourceGroup already exists in '$Location' - reusing."
} else {
    if (-not $Location -and $env:AZURE_LOCATION) {
        $Location = $env:AZURE_LOCATION
        Write-Host "    Using `$env:AZURE_LOCATION = '$Location' for new RG."
    }
    if (-not $Location) {
        throw "Resource group '$ResourceGroup' does not exist and no -Location was supplied. " +
              "Pass -Location <region> (e.g. -Location italynorth) or set `$env:AZURE_LOCATION."
    }
    Write-Host "    Creating RG $ResourceGroup in '$Location'..."
    az group create -n $ResourceGroup -l $Location -o none
    if ($LASTEXITCODE -ne 0) { throw "Failed to create RG $ResourceGroup." }
}
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

# Effective bastion decision (mirrors deploy.yml -> pre-deploy-checks job):
# if deployBastion=true in the bicepparam but AzureBastionSubnet is missing
# from the existing VNet, downgrade to false so the rest of the farm still
# deploys. Compile the bicepparam to JSON to read the values without taking a
# dependency on parsing Bicep ourselves.
$effectiveDeployBastion = $null
$tmpParams = New-TemporaryFile
try {
    az bicep build-params --file $BicepParamFile --outfile $tmpParams.FullName 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $compiled = Get-Content -LiteralPath $tmpParams.FullName -Raw | ConvertFrom-Json

        function Get-CompiledParamValue {
            param(
                [Parameter(Mandatory)] $Compiled,
                [Parameter(Mandatory)] [string] $Name,
                $Default = $null
            )

            if (-not $Compiled -or -not $Compiled.parameters) { return $Default }
            if ($Compiled.parameters.PSObject.Properties[$Name]) {
                return $Compiled.parameters.$Name.value
            }
            return $Default
        }

        $deployBastion = [bool](Get-CompiledParamValue -Compiled $compiled -Name 'deployBastion' -Default $false)
        $vnetName      = [string](Get-CompiledParamValue -Compiled $compiled -Name 'existingVnetName' -Default '')
        $vnetRg        = [string](Get-CompiledParamValue -Compiled $compiled -Name 'existingVnetResourceGroup' -Default '')

        # main.bicep defaults this to AzureBastionSubnet, but build-params JSON
        # can omit params that are not explicitly set in main.bicepparam.
        $bastionSubnet = [string](Get-CompiledParamValue -Compiled $compiled -Name 'bastionSubnetName' -Default 'AzureBastionSubnet')

        if ($deployBastion) {
            if ([string]::IsNullOrWhiteSpace($vnetRg) -or [string]::IsNullOrWhiteSpace($vnetName)) {
                Write-Host "    [WARN] deployBastion=true but VNet params are unresolved in compiled bicepparam; leaving deployBastion unchanged." -ForegroundColor Yellow
            } else {
                az network vnet subnet show -g $vnetRg --vnet-name $vnetName -n $bastionSubnet -o none 2>$null
                if ($LASTEXITCODE -eq 0) {
                    $effectiveDeployBastion = 'true'
                } else {
                    Write-Host "    [WARN] deployBastion=true but bastion subnet '$bastionSubnet' is not in $vnetName - skipping the IaC-managed (Standard SKU) bastion; the rest of the farm still deploys. A separately-created bastion (e.g. Developer SKU) is unaffected." -ForegroundColor Yellow
                    $effectiveDeployBastion = 'false'
                }
            }
        } else {
            $effectiveDeployBastion = 'false'
        }
    }
} finally {
    Remove-Item -LiteralPath $tmpParams.FullName -Force -ErrorAction SilentlyContinue
}

$commonArgs = @(
    '--resource-group', $ResourceGroup,
    '--template-file',  $BicepFile,
    '--parameters',     $BicepParamFile,
    '--parameters',     "artifactsLocation=$($env:ARTIFACTS_LOCATION)"
)
if ($effectiveDeployBastion) {
    $commonArgs += @('--parameters', "deployBastion=$effectiveDeployBastion")
}

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

        # The CNAME step only applies to a vanity FQDN: publicGatewayFqdn is the
        # hostname clients type, gatewayFqdn is the Azure LB hostname. When they
        # match, publicGatewayFqdn was left empty / set to the LB FQDN (the
        # self-signed lab path) and there's nothing to CNAME.
        $publicFqdn = if ($o.PSObject.Properties['publicGatewayFqdn']) { [string]$o.publicGatewayFqdn.value } else { '' }
        $lbFqdn     = if ($o.PSObject.Properties['gatewayFqdn'])       { [string]$o.gatewayFqdn.value }       else { '' }
        $usesVanityFqdn = $publicFqdn -and $lbFqdn -and ($publicFqdn -ne $lbFqdn)

        Write-Host ""
        Write-Host "Next:" -ForegroundColor Cyan
        if ($usesVanityFqdn) {
            Write-Host "  * Point your vanity FQDN at the LB: CNAME $publicFqdn -> $lbFqdn (scripts/Set-GatewayCname.ps1)"
        }
        if ($SkipPostDeployTest) {
            Write-Host "  * Run smoke tests              : tests/Test-PostDeployHealth.ps1 -ResourceGroupName $ResourceGroup"
        }
    }

    # Deploy-and-verify in one command: the CI post-deploy-tests job can't run
    # (the runner is outside the VNet), so run the smoke test here unless asked
    # not to. A failing test does NOT fail the deploy - the farm is already up;
    # we just surface the result so it's visible.
    if (-not $SkipPostDeployTest) {
        $postDeployTest = Join-Path $PSScriptRoot '..' 'tests' 'Test-PostDeployHealth.ps1'
        if (Test-Path -LiteralPath $postDeployTest) {
            Write-Host ""
            Write-Host "==> Step 6: post-deploy smoke test" -ForegroundColor Green
            $testArgs = @{ ResourceGroupName = $ResourceGroup }
            if ($AddClientIpToNsg) { $testArgs['AddClientIpToNsg'] = $true }
            try {
                & $postDeployTest @testArgs
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "    Post-deploy smoke test reported failures (exit $LASTEXITCODE). The farm is deployed; review the output above." -ForegroundColor Yellow
                }
            } catch {
                Write-Host "    Post-deploy smoke test could not run: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        } else {
            Write-Host "    (post-deploy smoke test not found at $postDeployTest - skipped)" -ForegroundColor DarkYellow
        }
    }
} else {
    Write-Host ""
    Write-Host "what-if complete. Re-run with -Action deploy to apply." -ForegroundColor Cyan
}
