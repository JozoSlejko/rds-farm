<#
.SYNOPSIS
    Local equivalent of the workflow's `pre-deploy-checks` job.

.DESCRIPTION
    Runs the same five readiness checks the GitHub Actions workflow runs in
    .github/workflows/deploy.yml before what-if / deploy, so you can catch
    classic blockers without burning a CI run:

      1. Existing VNet + RDS subnet exist; subnet has enough usable IPs for
         (gateway + broker + sessionHostCount). Bastion subnet present when
         deployBastion = true.
      2. If enableCertificateBinding = true:
           - Key Vault exists and is in RBAC mode.
           - The certificate referenced by keyVaultCertSecretUri exists.
           - Cert policy has keyProperties.exportable = true.
           - Cert expires more than 30 days from now (soft warn otherwise).
      3. If $env:ARTIFACTS_STORAGE_ACCOUNT is set (or readable from
         bicepparam), verify Configuration.zip exists in the dsc container
         using `az storage blob exists --auth-mode login` (managed-identity-
         compatible; no SAS — the SA blocks SAS via tenant policy).
         Configuration.zip via the SAS and require 200 OK. Skipped when
         the env vars are missing (you haven't published yet — that's fine
         for a pure "is my config valid?" check).
      4. `az deployment group validate` against the target RG using the
         compiled bicepparam. This is what catches RBAC + policy + template
         errors that what-if would mask as ResourceNotFound.
      5. Sanity-check sessionHostNamingPrefix, gatewayDnsLabelPrefix and
         the no-internet-allow CIDR rule by chaining tests/Test-BicepParamValues.ps1.

    Exits non-zero on any HARD failure. Soft warnings (e.g. cert close to
    expiry, runner not in NSG allow-list) still let the script succeed.

.PARAMETER ResourceGroup
    Target RG for `az deployment group validate`. Default: 'rds-farm-rg'.

.PARAMETER Location
    Azure region for `az group create`. Default: 'westeurope'.

.PARAMETER BicepFile
    Default: <repo>/main.bicep.

.PARAMETER BicepParamFile
    Default: <repo>/main.bicepparam.

.PARAMETER SkipBicepValidate
    Skip step 4. Useful when you don't yet have RG-create rights.

.EXAMPLE
    # Standalone pre-flight before deploying by hand
    .\tests\Test-PreDeployReadiness.ps1

.EXAMPLE
    # In CI (after Publish-DscArtifact has set the env vars)
    .\tests\Test-PreDeployReadiness.ps1 -ResourceGroup rds-farm-rg

.NOTES
    Requires: 'az' signed in with Reader on the target RG + VNet RG + KV RG.
    Contributor needed only for the implicit `az group create` in step 4.
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup  = 'rds-farm-rg',
    [string]$Location       = 'westeurope',
    [string]$BicepFile      = (Join-Path $PSScriptRoot '..' 'main.bicep'),
    [string]$BicepParamFile = (Join-Path $PSScriptRoot '..' 'main.bicepparam'),
    [switch]$SkipBicepValidate
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

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

function Assert-Tool {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required tool '$Name' was not found in PATH."
    }
}

function Get-CompiledParam {
    param([string]$Json, [string]$Name)
    $obj = $Json | ConvertFrom-Json
    if ($obj.parameters.PSObject.Properties[$Name]) {
        return $obj.parameters.$Name.value
    }
    return $null
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

$ctx = az account show -o json 2>$null | ConvertFrom-Json
if (-not $ctx) { throw "Not logged in to Azure. Run 'az login' first." }
Write-Host "    Subscription   : $($ctx.name)"
Write-Host "    Resource group : $ResourceGroup (in $Location)"
Write-Host "    Template       : $BicepFile"
Write-Host "    Parameters     : $BicepParamFile"
Write-Host ('-' * 60)

# Compile bicepparam once so all subsequent checks read the resolved values.
foreach ($v in 'DOMAIN_JOIN_PASSWORD', 'LOCAL_ADMIN_PASSWORD') {
    if (-not [Environment]::GetEnvironmentVariable($v)) {
        [Environment]::SetEnvironmentVariable($v, 'placeholder-for-validation-only', 'Process')
    }
}

$tmp = New-TemporaryFile
try {
    & az bicep build-params --file $BicepParamFile --outfile $tmp.FullName 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "az bicep build-params failed." }
    $paramJson = Get-Content -LiteralPath $tmp.FullName -Raw
} finally {
    Remove-Item -LiteralPath $tmp.FullName -Force -ErrorAction SilentlyContinue
}

$vnet         = Get-CompiledParam $paramJson 'existingVnetName'
$vnetRg       = Get-CompiledParam $paramJson 'existingVnetResourceGroup'
$subnet       = Get-CompiledParam $paramJson 'existingRdsSubnetName'
$bastionSub   = Get-CompiledParam $paramJson 'bastionSubnetName'
$deployBast   = [bool](Get-CompiledParam $paramJson 'deployBastion')
$shCount      = [int](Get-CompiledParam $paramJson 'sessionHostCount')
$certEnabled  = [bool](Get-CompiledParam $paramJson 'enableCertificateBinding')
$kvName       = Get-CompiledParam $paramJson 'keyVaultName'
$kvRg         = Get-CompiledParam $paramJson 'keyVaultResourceGroup'
$kvSecretUri  = Get-CompiledParam $paramJson 'keyVaultCertSecretUri'

# ---------------------------------------------------------------------------
# 1. VNet + subnet
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "==> Step 1: VNet + subnet" -ForegroundColor Green
$vnetJson = az network vnet show -g $vnetRg -n $vnet -o json 2>$null
if ($LASTEXITCODE -ne 0 -or -not $vnetJson) {
    Write-TestResult "VNet $vnetRg/$vnet exists" $false
} else {
    Write-TestResult "VNet $vnetRg/$vnet exists" $true

    $subJson = az network vnet subnet show -g $vnetRg --vnet-name $vnet -n $subnet -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $subJson) {
        Write-TestResult "Subnet '$subnet' present in $vnet" $false
    } else {
        $sub  = $subJson | ConvertFrom-Json
        $cidr = if ($sub.addressPrefix) { $sub.addressPrefix } else { $sub.addressPrefixes[0] }
        $pfx  = [int](($cidr -split '/')[1])
        # Azure reserves 5 IPs per subnet.
        $avail = ([math]::Pow(2, 32 - $pfx) - 5)
        $needed = 2 + $shCount   # gateway + broker + N session hosts
        if ($avail -lt $needed) {
            Write-TestResult "Subnet '$subnet' ($cidr) has $avail usable IPs (need $needed)" $false
        } else {
            Write-TestResult "Subnet '$subnet' ($cidr) has $avail usable IPs (need $needed)" $true
        }
    }

    if ($deployBast) {
        az network vnet subnet show -g $vnetRg --vnet-name $vnet -n $bastionSub -o none 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-TestResult "Bastion subnet '$bastionSub' present (deployBastion=true)" $true
        } else {
            # Soft fallback: deploy will skip bastion automatically (the CI
            # pipeline overrides deployBastion=false in this case). Same
            # behavior on the laptop path via Invoke-ManualDeploy.ps1.
            Write-TestResult "Bastion subnet '$bastionSub' missing - bastion will be skipped at deploy time" $false `
                "Pre-create '$bastionSub' (exact name 'AzureBastionSubnet', /26 or larger) in $vnet if you want bastion provisioned." -SoftWarn
        }
    }
}

# ---------------------------------------------------------------------------
# 2. Key Vault + cert
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "==> Step 2: Key Vault + cert" -ForegroundColor Green
if (-not $certEnabled) {
    Write-Host "    enableCertificateBinding = false — skipped"
} else {
    $kvJson = az keyvault show -g $kvRg -n $kvName -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $kvJson) {
        Write-TestResult "Key Vault $kvRg/$kvName exists" $false
    } else {
        $kv = $kvJson | ConvertFrom-Json
        Write-TestResult "Key Vault $kvRg/$kvName exists" $true
        Write-TestResult "Key Vault uses RBAC (enableRbacAuthorization=true)" ([bool]$kv.properties.enableRbacAuthorization)

        # https://<vault>.vault.azure.net/secrets/<name>[/<version>]
        $certNameFromUri = ($kvSecretUri -split '/')[4]
        # NOTE: 'az keyvault certificate show-policy' is not a real CLI subcommand.
        # Use 'show ... --query policy' to get the policy object. The CLI returns
        # camelCase (keyProperties), so the JSON we parse uses .keyProperties too.
        $polJson = az keyvault certificate show --vault-name $kvName --name $certNameFromUri --query policy -o json 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $polJson -or $polJson -eq 'null') {
            Write-TestResult "Certificate '$certNameFromUri' exists in $kvName" $false `
                "URI was: $kvSecretUri"
        } else {
            Write-TestResult "Certificate '$certNameFromUri' exists in $kvName" $true
            $pol = $polJson | ConvertFrom-Json
            Write-TestResult "Cert '$certNameFromUri' policy is exportable" ([bool]$pol.keyProperties.exportable)

            $attrs = az keyvault certificate show --vault-name $kvName --name $certNameFromUri --query attributes -o json 2>$null | ConvertFrom-Json
            if ($attrs.expires) {
                $expires  = [datetime]$attrs.expires
                $daysLeft = [int]([math]::Floor(($expires.ToUniversalTime() - (Get-Date).ToUniversalTime()).TotalDays))
                if ($daysLeft -lt 0) {
                    Write-TestResult "Cert '$certNameFromUri' is not expired ($daysLeft days)" $false
                } elseif ($daysLeft -lt 30) {
                    Write-TestResult "Cert '$certNameFromUri' has 30+ days left ($daysLeft days)" $false `
                        "Consider renewing soon." -SoftWarn
                } else {
                    Write-TestResult "Cert '$certNameFromUri' has 30+ days left ($daysLeft days)" $true
                }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# 3. Artifacts blob reachability (managed-identity auth)
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "==> Step 3: Artifacts blob reachable (MSI auth)" -ForegroundColor Green

# Resolve the SA name from env (preferred) or from the compiled bicepparam.
$artifactsSa = $env:ARTIFACTS_STORAGE_ACCOUNT
if (-not $artifactsSa) {
    $artifactsSa = Get-CompiledParam $paramJson 'artifactsStorageAccountName'
}
$artifactsContainer = 'dsc'
$artifactsBlobName  = 'Configuration.zip'

if (-not $artifactsSa) {
    Write-Host "    Storage account name not resolved (env ARTIFACTS_STORAGE_ACCOUNT empty and bicepparam has no artifactsStorageAccountName) — skipped" -ForegroundColor DarkYellow
} else {
    $exists = az storage blob exists `
        --account-name   $artifactsSa `
        --container-name $artifactsContainer `
        --name           $artifactsBlobName `
        --auth-mode      login `
        --query exists -o tsv 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-TestResult "Blob $artifactsContainer/$artifactsBlobName exists on $artifactsSa" $false `
            'az storage blob exists failed. Ensure you have Storage Blob Data Reader on the SA (login auth).'
    } elseif ($exists -eq 'true') {
        Write-TestResult "Blob $artifactsContainer/$artifactsBlobName exists on $artifactsSa" $true
    } else {
        Write-TestResult "Blob $artifactsContainer/$artifactsBlobName exists on $artifactsSa" $false `
            'Run scripts/Publish-DscArtifact.ps1 (or push to trigger the workflow) before deploying.'
    }
}

# ---------------------------------------------------------------------------
# 4. ARM validate
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "==> Step 4: az deployment group validate" -ForegroundColor Green
if ($SkipBicepValidate) {
    Write-Host "    -SkipBicepValidate set — skipped"
} else {
    $rgExists = (az group exists -n $ResourceGroup) -eq 'true'
    if (-not $rgExists) {
        Write-Host "    Creating RG $ResourceGroup in $Location (validate needs an RG to target)..."
        az group create -n $ResourceGroup -l $Location -o none
        if ($LASTEXITCODE -ne 0) {
            Write-TestResult "Ensure RG $ResourceGroup" $false 'Need Contributor on the subscription / RG to create.'
        }
    }

    $artifactsArg = if ($env:ARTIFACTS_LOCATION) {
        "artifactsLocation=$($env:ARTIFACTS_LOCATION)"
    } else {
        $null
    }
    $validateCmd = @(
        'deployment','group','validate',
        '--resource-group', $ResourceGroup,
        '--template-file',  $BicepFile,
        '--parameters',     $BicepParamFile
    )
    if ($artifactsArg) { $validateCmd += @('--parameters', $artifactsArg) }
    $validateCmd += @('-o','none')

    & az @validateCmd
    Write-TestResult "Template validates against current Azure state" ($LASTEXITCODE -eq 0)
}

# ---------------------------------------------------------------------------
# 5. Bicep param value sanity
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "==> Step 5: Bicep param-value sanity" -ForegroundColor Green
$paramSanityScript = Join-Path $PSScriptRoot 'Test-BicepParamValues.ps1'
if (Test-Path -LiteralPath $paramSanityScript) {
    & $paramSanityScript -ParamFile $BicepParamFile
    Write-TestResult "Test-BicepParamValues.ps1 passed" ($LASTEXITCODE -eq 0)
} else {
    Write-TestResult "Test-BicepParamValues.ps1 present" $false "Expected at $paramSanityScript"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ('-' * 60)
Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host "$($failures.Count) check(s) FAILED:" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
if ($warnings.Count -gt 0) {
    Write-Host "$($warnings.Count) warning(s):" -ForegroundColor Yellow
    $warnings | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
}
Write-Host "All hard checks passed — safe to deploy." -ForegroundColor Green
exit 0
