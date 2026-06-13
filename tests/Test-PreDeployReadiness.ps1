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
.PARAMETER Location
    Azure region used only when the RG doesn't yet exist (validate needs an
    RG to target). If the RG already exists, the script auto-discovers its
    location and ignores this parameter. Falls back to $env:AZURE_LOCATION
    on fresh deployments.

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
    [string]$Location       = '',
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
        # Two reasons we have to PSObject-probe instead of $sub.addressPrefix:
        # (1) Set-StrictMode -Version Latest is on, so touching a missing
        #     property is a terminating error, not $null.
        # (2) Azure returns *either* 'addressPrefix' (single, classic) *or*
        #     'addressPrefixes' (array, dual-stack / multi-CIDR subnets).
        #     Subnets created post-2023 via portal often only have the array.
        $names = $sub.PSObject.Properties.Name
        $cidr  =
            if (($names -contains 'addressPrefix') -and $sub.addressPrefix) {
                $sub.addressPrefix
            }
            elseif (($names -contains 'addressPrefixes') -and $sub.addressPrefixes) {
                $sub.addressPrefixes[0]
            }
            else { $null }

        if (-not $cidr) {
            Write-TestResult "Subnet '$subnet' has an addressPrefix" $false `
                "Neither addressPrefix nor addressPrefixes is set on $vnet/$subnet. Check the subnet exists and isn't delegated to a managed service that hides the CIDR."
        } else {
            $pfx    = [int](($cidr -split '/')[1])
            # Azure reserves 5 IPs per subnet.
            $avail  = ([math]::Pow(2, 32 - $pfx) - 5)
            $needed = 2 + $shCount   # gateway + broker + N session hosts
            if ($avail -lt $needed) {
                Write-TestResult "Subnet '$subnet' ($cidr) has $avail usable IPs (need $needed)" $false
            } else {
                Write-TestResult "Subnet '$subnet' ($cidr) has $avail usable IPs (need $needed)" $true
            }
        }
    }

    if ($deployBast) {
        # main.bicep defaults bastionSubnetName to 'AzureBastionSubnet', but the
        # compiled bicepparam JSON omits params that aren't explicitly set in
        # main.bicepparam. Apply the same default here so this check mirrors
        # Invoke-ManualDeploy.ps1 and actually runs the subnet-existence test
        # below instead of short-circuiting on an "unset" value.
        if ([string]::IsNullOrWhiteSpace($bastionSub)) { $bastionSub = 'AzureBastionSubnet' }

        az network vnet subnet show -g $vnetRg --vnet-name $vnet -n $bastionSub -o none 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-TestResult "Bastion subnet '$bastionSub' present (deployBastion=true)" $true
        } else {
            # The bastion this template would deploy (Standard SKU) needs this
            # subnet. When it's absent the deploy skips the bastion module
            # (Invoke-ManualDeploy.ps1 and CI set deployBastion=false) and the
            # rest of the farm still deploys. A bastion created out-of-band
            # (e.g. a Developer-SKU host from the portal) is separate and
            # unaffected by this.
            Write-TestResult "Bastion subnet '$bastionSub' not found in $vnet - IaC bastion will be skipped" $false `
                "Only affects the Standard-SKU bastion this template manages. To have the IaC deploy one, pre-create '$bastionSub' (/26 or larger) in $vnet. If you run a bastion separately, ignore this." -SoftWarn
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
        # Capture stderr so we can distinguish a missing cert from a vault that
        # simply rejects this caller (e.g. publicNetworkAccess=Disabled, RBAC role
        # not yet propagated). The deploy can still succeed in those cases because
        # the gateway VM uses its managed identity over a private endpoint.
        $polJson = az keyvault certificate show --vault-name $kvName --name $certNameFromUri --query policy -o json 2>&1
        $polRc   = $LASTEXITCODE
        $polTxt  = ($polJson | Out-String)

        # Heuristic: any 'Forbidden' / 'public network access' / 'not allowed'
        # error means we're blocked by network or RBAC, not that the cert is
        # missing. Mark inconclusive (SoftWarn) instead of failing the run.
        $isBlockedByPolicy =
            ($polRc -ne 0) -and (
                $polTxt -match 'Public network access is disabled' -or
                $polTxt -match 'ForbiddenByConnection' -or
                $polTxt -match 'ForbiddenByFirewall' -or
                $polTxt -match 'Forbidden' -or
                $polTxt -match 'does not have certificates (get|list) permission'
            )

        if ($isBlockedByPolicy) {
            Write-TestResult "Cert '$certNameFromUri' present in $kvName (inconclusive)" $false `
                "Vault data-plane is not reachable from this host (public access disabled or RBAC not yet effective). The gateway VM will still reach the cert via its managed identity. URI: $kvSecretUri" -SoftWarn
        }
        elseif ($polRc -ne 0 -or -not $polJson -or $polTxt.Trim() -eq 'null') {
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
    # Capture stderr+stdout so we can distinguish "blob is missing" from
    # "this caller is blocked" (publicNetworkAccess=Disabled, RBAC role not
    # yet propagated, network ACL deny, ...). The VMs use their managed
    # identity over a private endpoint / service endpoint at deploy time and
    # will still succeed even if our laptop is blocked.
    $blobOut = az storage blob exists `
        --account-name   $artifactsSa `
        --container-name $artifactsContainer `
        --name           $artifactsBlobName `
        --auth-mode      login `
        --query exists -o tsv 2>&1
    $blobRc  = $LASTEXITCODE
    $blobTxt = ($blobOut | Out-String)

    # Heuristic: any of these stderr signatures means we're blocked by
    # network or RBAC, not that the blob is missing.
    $isBlockedByPolicy =
        ($blobRc -ne 0) -and (
            $blobTxt -match 'Public access is not permitted' -or
            $blobTxt -match 'PublicAccessNotPermitted' -or
            $blobTxt -match 'public network access is disabled' -or
            $blobTxt -match 'AuthorizationFailure' -or
            $blobTxt -match 'AuthorizationPermissionMismatch' -or
            $blobTxt -match 'This request is not authorized' -or
            $blobTxt -match 'not authorized to perform this operation' -or
            $blobTxt -match 'Forbidden'
        )

    if ($isBlockedByPolicy) {
        Write-TestResult "Blob $artifactsContainer/$artifactsBlobName reachable from this host (inconclusive)" $false `
            "Storage data-plane is not reachable from this host (public access disabled or RBAC not yet effective). The VMs will still pull the artifact via their managed identity over the private endpoint. SA: $artifactsSa" -SoftWarn
    }
    elseif ($blobRc -ne 0) {
        Write-TestResult "Blob $artifactsContainer/$artifactsBlobName exists on $artifactsSa" $false `
            'az storage blob exists failed. Ensure you have Storage Blob Data Reader on the SA (login auth).'
    } elseif ($blobTxt.Trim() -eq 'true') {
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
        if (-not $Location -and $env:AZURE_LOCATION) { $Location = $env:AZURE_LOCATION }
        if (-not $Location) {
            Write-TestResult "Ensure RG $ResourceGroup" $false "RG doesn't exist and no -Location / `$env:AZURE_LOCATION supplied to create it."
        } else {
            Write-Host "    Creating RG $ResourceGroup in $Location (validate needs an RG to target)..."
            az group create -n $ResourceGroup -l $Location -o none
            if ($LASTEXITCODE -ne 0) {
                Write-TestResult "Ensure RG $ResourceGroup" $false 'Need Contributor on the subscription / RG to create.'
            }
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
