<#
.SYNOPSIS
    Verify the CI prerequisites set up by Initialize-CiPrerequisites.ps1.

.DESCRIPTION
    Read-only diagnostics. Confirms that all the things the GitHub Actions
    workflow expects are present and correctly configured:

      1. Entra app exists (by display name).
      2. Service principal exists for that app.
      3. All 4 federated credentials present, with the expected subjects.
      4. SP has the required sub-scope roles
         (Contributor + Role Based Access Control Administrator).
      5. All 5 repo secrets are set (existence only — values aren't readable).
      6. ARTIFACTS_STORAGE_ACCOUNT repo variable is set AND the storage
         account it points to actually exists.
      7. Both 'preview' and 'production' environments exist.

    Exits non-zero on any failure.

.PARAMETER GitHubRepo
    <org>/<repo>, same format as Initialize-CiPrerequisites.ps1.

.PARAMETER AppDisplayName
    Default: 'gh-rds-farm-deploy'.

.PARAMETER SubscriptionId
    Optional. Defaults to the active subscription.

.EXAMPLE
    .\tests\Test-CiPrerequisites.ps1 -GitHubRepo contoso/rds-farm

.NOTES
    Requires:
      * 'az' signed in.
      * 'gh' signed in with 'repo' scope.
      * Reader on the subscription (to list role assignments).
      * Read access to the repo's secrets/variables/environments.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[^/]+/[^/]+$')]
    [string]$GitHubRepo,

    [string]$AppDisplayName = 'gh-rds-farm-deploy',
    [string]$SubscriptionId
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

# ---------------------------------------------------------------------------
# 0. Pre-flight
# ---------------------------------------------------------------------------
Write-Host "==> Pre-flight" -ForegroundColor Cyan
Assert-Tool 'az'
Assert-Tool 'gh'

$ctx = az account show -o json 2>$null | ConvertFrom-Json
if (-not $ctx) { throw "Not logged in to Azure. Run 'az login' first." }
if ($SubscriptionId) {
    az account set --subscription $SubscriptionId | Out-Null
    $ctx = az account show -o json | ConvertFrom-Json
}
$SubscriptionId = $ctx.id
Write-Host "    Subscription : $($ctx.name) ($SubscriptionId)"
Write-Host "    Repo         : $GitHubRepo"
Write-Host "    App          : $AppDisplayName"
Write-Host ('-' * 60)

# ---------------------------------------------------------------------------
# 1. Entra app + SP
# ---------------------------------------------------------------------------
$app = az ad app list --display-name $AppDisplayName --query '[0]' -o json | ConvertFrom-Json
if (-not $app) {
    Write-TestResult "Entra app '$AppDisplayName' exists" $false 'Re-run Initialize-CiPrerequisites.ps1.'
    Write-Host "Aborting further checks (no app to inspect)." -ForegroundColor Red
    exit 1
}
Write-TestResult "Entra app '$AppDisplayName' exists" $true
$AppId = $app.appId

$sp = az ad sp list --filter "appId eq '$AppId'" --query '[0]' -o json | ConvertFrom-Json
if (-not $sp) {
    Write-TestResult "Service principal for $AppId exists" $false
    exit 1
}
Write-TestResult "Service principal for $AppId exists" $true
$SpObjectId = $sp.id

# ---------------------------------------------------------------------------
# 2. Federated credentials
# ---------------------------------------------------------------------------
$expectedCreds = @{
    'gh-main'           = "repo:${GitHubRepo}:ref:refs/heads/main"
    'gh-pr'             = "repo:${GitHubRepo}:pull_request"
    'gh-env-production' = "repo:${GitHubRepo}:environment:production"
    'gh-env-preview'    = "repo:${GitHubRepo}:environment:preview"
}

$creds = az ad app federated-credential list --id $AppId -o json | ConvertFrom-Json
foreach ($name in $expectedCreds.Keys) {
    $c = $creds | Where-Object { $_.name -eq $name }
    if (-not $c) {
        Write-TestResult "Federated credential '$name' exists" $false
        continue
    }
    if ($c.subject -ne $expectedCreds[$name]) {
        Write-TestResult "Federated credential '$name' has correct subject" $false `
            "expected '$($expectedCreds[$name])', got '$($c.subject)'"
        continue
    }
    Write-TestResult "Federated credential '$name'" $true
}

# ---------------------------------------------------------------------------
# 3. Subscription-scope RBAC
# ---------------------------------------------------------------------------
$scope = "/subscriptions/$SubscriptionId"
foreach ($r in @('Contributor', 'Role Based Access Control Administrator')) {
    $existing = az role assignment list --assignee $SpObjectId --role $r --scope $scope -o json | ConvertFrom-Json
    Write-TestResult "Role '$r' at sub scope" ([bool]$existing)
}

# ---------------------------------------------------------------------------
# 4. GitHub repo secrets
# ---------------------------------------------------------------------------
$secretsJson = gh secret list --repo $GitHubRepo --json name 2>$null
if ($LASTEXITCODE -ne 0 -or -not $secretsJson) {
    Write-TestResult "Read GitHub secrets" $false "gh secret list failed; check 'gh auth status'."
} else {
    $secretNames = ($secretsJson | ConvertFrom-Json).name
    foreach ($s in @('AZURE_CLIENT_ID','AZURE_TENANT_ID','AZURE_SUBSCRIPTION_ID','DOMAIN_JOIN_PASSWORD','LOCAL_ADMIN_PASSWORD')) {
        Write-TestResult "Secret '$s' is set" ($secretNames -contains $s)
    }
}

# ---------------------------------------------------------------------------
# 5. GitHub repo variable + storage account
# ---------------------------------------------------------------------------
$saName = (gh variable get ARTIFACTS_STORAGE_ACCOUNT --repo $GitHubRepo 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $saName) {
    Write-TestResult "Variable 'ARTIFACTS_STORAGE_ACCOUNT' is NOT set" $false `
        "Set it with: gh variable set ARTIFACTS_STORAGE_ACCOUNT --repo $GitHubRepo --body <name>" -SoftWarn
} else {
    $saName = $saName.Trim()
    Write-TestResult "Variable 'ARTIFACTS_STORAGE_ACCOUNT' is set ($saName)" $true

    $sa = az storage account list --query "[?name=='$saName'] | [0]" -o json | ConvertFrom-Json
    if (-not $sa) {
        Write-TestResult "Storage account '$saName' exists in current sub" $false `
            "Re-run scripts/Initialize-RdsFarm.ps1 (or prereqs/main.bicep manually) and update the variable."
    } else {
        Write-TestResult "Storage account '$saName' exists in current sub" $true
    }
}

# ---------------------------------------------------------------------------
# 6. GitHub environments
# ---------------------------------------------------------------------------
foreach ($envName in @('preview','production')) {
    gh api "repos/$GitHubRepo/environments/$envName" 1>$null 2>$null
    Write-TestResult "Environment '$envName' exists" ($LASTEXITCODE -eq 0)
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
Write-Host "All hard checks passed." -ForegroundColor Green
exit 0
