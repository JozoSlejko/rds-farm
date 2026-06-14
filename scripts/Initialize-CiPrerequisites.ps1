<#
.SYNOPSIS
    Tier-0 bootstrap for the rds-farm GitHub Actions pipeline.

.DESCRIPTION
    One-time setup that creates everything the workflow needs to AUTHENTICATE
    before it can do any work. After this script succeeds, the "Deploy RDS
    Farm" workflow can be triggered (workflow_dispatch with action: what-if or
    deploy) and it will deploy main.bicep into the existing Tier 0 artifacts
    storage account + Key Vault. Provision those data resources from your
    laptop via Initialize-RdsFarm.ps1 (which calls this script and then
    deploys prereqs/tier0.bicep).

    What this script does (all idempotent):
      1. Creates (or reuses) an Entra application and service principal.
      2. Creates 4 federated credentials (main branch, PRs, two environments).
      3. Grants the SP 'Contributor' + 'Role Based Access Control Administrator'
         at subscription scope.
      4. Sets the 5 required GitHub repository secrets:
           AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID,
           DOMAIN_JOIN_PASSWORD, LOCAL_ADMIN_PASSWORD
         Passwords are read with Read-Host -AsSecureString.
      5. Optionally sets the ARTIFACTS_STORAGE_ACCOUNT, AZURE_LOCATION, and
         AZURE_RESOURCE_GROUP repo variables. The workflow's env: block reads
         these (with sensible defaults) so the orchestrator's -Location and
         -FarmResourceGroup choices actually flow into CI.
      6. Creates the 'preview' and 'production' GitHub environments.

    What this script does NOT do (intentional):
      * Create the artifacts storage account / Key Vault / RGs — that is
        what `prereqs/tier0.bicep` does. Run it via Initialize-RdsFarm.ps1
        or by hand per docs/prereq-resources.md.
      * Create or import the TLS certificate — see docs/fqdn-and-cert.md.

.PARAMETER GitHubRepo
    Format: <org-or-user>/<repo>, e.g. 'contoso/rds-farm'.
    Used to scope `gh` commands and to build the federated-credential subjects.

.PARAMETER SubscriptionId
    Optional. Defaults to the subscription `az account show` returns.

.PARAMETER AppDisplayName
    Display name for the Entra app. Default: 'gh-rds-farm-deploy'.

.PARAMETER ArtifactsStorageAccount
    Optional. If you ALREADY have an artifacts storage account, pass its name
    and the script will set the ARTIFACTS_STORAGE_ACCOUNT repo variable.
    Skip this if you plan to provision the SA next via Initialize-RdsFarm.ps1
    (which will set the variable for you).

.PARAMETER Location
    Optional. Azure region the workflow will deploy the farm RG into. When set,
    written to GitHub as the AZURE_LOCATION repo variable. If omitted, the
    workflow falls back to whatever literal is in deploy.yml's env: block.

.PARAMETER FarmResourceGroup
    Optional. Name of the resource group the workflow creates and deploys
    main.bicep into. When set, written to GitHub as the AZURE_RESOURCE_GROUP
    repo variable. If omitted, the workflow falls back to 'rds-farm-rg'.

.PARAMETER RequireProductionApproval
    Switch. If set, the 'production' environment is created with the current
    GitHub user marked as a required reviewer. Requires GitHub Pro/Team/
    Enterprise on private repos.

.EXAMPLE
    .\scripts\Initialize-CiPrerequisites.ps1 -GitHubRepo 'contoso/rds-farm'

.EXAMPLE
    .\scripts\Initialize-CiPrerequisites.ps1 `
        -GitHubRepo 'contoso/rds-farm' `
        -ArtifactsStorageAccount 'contosoartifacts01' `
        -RequireProductionApproval

.NOTES
    Prerequisites on the machine running this script:
      * Azure CLI ('az') signed in: `az login` (use --tenant <id> if needed).
      * GitHub CLI ('gh')   signed in: `gh auth login` with `repo` scope.
      * PowerShell 7+ recommended.
      * Permission to create app registrations in the Entra tenant
        ('Application Developer' role at minimum) and Owner-equivalent rights
        on the target subscription (to assign 'Role Based Access Control
        Administrator').
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[^/]+/[^/]+$')]
    [string]$GitHubRepo,

    [string]$SubscriptionId,

    [string]$AppDisplayName = 'gh-rds-farm-deploy',

    [string]$ArtifactsStorageAccount,

    [string]$Location,

    [string]$FarmResourceGroup,

    [switch]$RequireProductionApproval,

    # Skip the read-only self-check at the end (Test-CiPrerequisites.ps1).
    # The orchestrator (Initialize-RdsFarm.ps1) sets this because the
    # storage account the self-check verifies doesn't exist yet at this
    # point in the orchestrator's flow; Test-RdsFarmInit.ps1 runs the
    # full check at the end instead.
    [switch]$SkipSelfCheck
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Helpers
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

function Set-GhSecret {
    param(
        [string]$Name,
        [string]$Value,
        [string]$Repo
    )
    Write-Host "  Setting secret '$Name'..."
    # Pass the value via --body, NOT via stdin. Reason: the previous
    # implementation used '$Value | gh secret set $Name --body -' which
    # actually sets the literal string '-' as the secret (--body wins; the
    # piped value is ignored). The naive fix ('$Value | gh secret set $Name')
    # works but PowerShell on Windows appends a trailing CRLF to piped
    # strings, which would silently land inside the stored secret and break
    # downstream uses (e.g. azure/login@v3 would see 'tenantid\r\n' and fail
    # with AADSTS90002 'Tenant not found'). --body is the most predictable
    # path. The value briefly appears on the gh.exe command line, which is
    # only visible to processes owned by the same user — acceptable on a
    # developer workstation that is itself doing the bootstrap.
    gh secret set $Name --repo $Repo --body $Value
    if ($LASTEXITCODE -ne 0) { throw "Failed to set GitHub secret '$Name'." }
}

# ---------------------------------------------------------------------------
# 0. Pre-flight
# ---------------------------------------------------------------------------
Write-Host "==> Pre-flight" -ForegroundColor Cyan
Assert-Tool 'az'
Assert-Tool 'gh'

Write-Host "  Verifying Azure auth..."
$ctx = az account show -o json 2>$null | ConvertFrom-Json
if (-not $ctx) { throw "Not logged in to Azure. Run 'az login' first." }

if ($SubscriptionId) {
    az account set --subscription $SubscriptionId | Out-Null
    $ctx = az account show -o json | ConvertFrom-Json
}
$SubscriptionId = $ctx.id
$TenantId       = $ctx.tenantId
Write-Host "    Subscription : $($ctx.name) ($SubscriptionId)"
Write-Host "    Tenant       : $TenantId"

Write-Host "  Verifying GitHub auth..."
gh auth status 1>$null 2>$null
if ($LASTEXITCODE -ne 0) { throw "GitHub CLI not authenticated. Run 'gh auth login' first." }

# ---------------------------------------------------------------------------
# 1. Entra app + service principal
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "==> Step 1: Entra app + service principal" -ForegroundColor Green

$app = az ad app list --display-name $AppDisplayName --query '[0]' -o json | ConvertFrom-Json
if (-not $app) {
    Write-Host "  Creating Entra app '$AppDisplayName'..."
    $app = az ad app create --display-name $AppDisplayName -o json | ConvertFrom-Json
} else {
    Write-Host "  Reusing existing Entra app '$AppDisplayName' (appId=$($app.appId))"
}
$AppId = $app.appId

$sp = az ad sp list --filter "appId eq '$AppId'" --query '[0]' -o json | ConvertFrom-Json
if (-not $sp) {
    Write-Host "  Creating service principal..."
    $sp = az ad sp create --id $AppId -o json | ConvertFrom-Json
} else {
    Write-Host "  Reusing existing service principal (objectId=$($sp.id))"
}
$SpObjectId = $sp.id

# ---------------------------------------------------------------------------
# 2. Federated credentials
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "==> Step 2: Federated credentials" -ForegroundColor Green

$creds = @(
    @{ name = 'gh-main';           subject = "repo:${GitHubRepo}:ref:refs/heads/main" }
    @{ name = 'gh-pr';             subject = "repo:${GitHubRepo}:pull_request" }
    @{ name = 'gh-env-production'; subject = "repo:${GitHubRepo}:environment:production" }
    @{ name = 'gh-env-preview';    subject = "repo:${GitHubRepo}:environment:preview" }
)

$existingCreds = az ad app federated-credential list --id $AppId -o json | ConvertFrom-Json
foreach ($c in $creds) {
    if ($existingCreds | Where-Object { $_.name -eq $c.name }) {
        Write-Host "  Reusing federated credential '$($c.name)'"
        continue
    }
    $payload = [ordered]@{
        name      = $c.name
        issuer    = 'https://token.actions.githubusercontent.com'
        subject   = $c.subject
        audiences = @('api://AzureADTokenExchange')
    } | ConvertTo-Json -Compress

    $tmp = New-TemporaryFile
    try {
        Set-Content -Path $tmp -Value $payload -Encoding utf8 -NoNewline
        Write-Host "  Creating federated credential '$($c.name)' -> '$($c.subject)'..."
        az ad app federated-credential create --id $AppId --parameters "@$($tmp.FullName)" | Out-Null
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# 3. Subscription-scope RBAC
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "==> Step 3: Subscription-scope RBAC" -ForegroundColor Green
Write-Host "    (Contributor lets the workflow create the farm RG and deploy main.bicep;"
Write-Host "     RBAC Admin lets modules/sa-role.bicep and modules/kv-role.bicep create"
Write-Host "     the SA/KV role assignments at deploy time.)"

$scope = "/subscriptions/$SubscriptionId"
$roles = @(
    'Contributor',
    'Role Based Access Control Administrator'
)

foreach ($r in $roles) {
    $existing = az role assignment list `
        --assignee $SpObjectId `
        --role     $r `
        --scope    $scope `
        -o json | ConvertFrom-Json

    if ($existing) {
        Write-Host "  '$r' already assigned at sub scope."
        continue
    }
    Write-Host "  Assigning '$r' at sub scope..."
    # Use --assignee-object-id to avoid Graph-propagation race after sp create.
    az role assignment create `
        --assignee-object-id      $SpObjectId `
        --assignee-principal-type ServicePrincipal `
        --role                    $r `
        --scope                   $scope | Out-Null
}

# ---------------------------------------------------------------------------
# 4. GitHub repository secrets
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "==> Step 4: GitHub repository secrets" -ForegroundColor Green

Set-GhSecret -Name 'AZURE_CLIENT_ID'       -Value $AppId          -Repo $GitHubRepo
Set-GhSecret -Name 'AZURE_TENANT_ID'       -Value $TenantId       -Repo $GitHubRepo
Set-GhSecret -Name 'AZURE_SUBSCRIPTION_ID' -Value $SubscriptionId -Repo $GitHubRepo

Write-Host ""
Write-Host "  The next two values are passwords. They are read silently and never echoed."
$domainSecure = Read-Host -Prompt '    DOMAIN_JOIN_PASSWORD' -AsSecureString
$localSecure  = Read-Host -Prompt '    LOCAL_ADMIN_PASSWORD' -AsSecureString

try {
    $domainPlain = ConvertFrom-SecureStringPlain $domainSecure
    $localPlain  = ConvertFrom-SecureStringPlain $localSecure
    Set-GhSecret -Name 'DOMAIN_JOIN_PASSWORD' -Value $domainPlain -Repo $GitHubRepo
    Set-GhSecret -Name 'LOCAL_ADMIN_PASSWORD' -Value $localPlain  -Repo $GitHubRepo
} finally {
    # Best-effort scrub from managed memory.
    $domainPlain = $null
    $localPlain  = $null
    [GC]::Collect()
}

# ---------------------------------------------------------------------------
# 5. GitHub repository variables
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "==> Step 5: GitHub repository variables" -ForegroundColor Green

function Set-GhVariable {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Repo
    )
    gh variable set $Name --repo $Repo --body $Value
    if ($LASTEXITCODE -ne 0) { throw "Failed to set repo variable $Name." }
    Write-Host "  Set repo variable $Name=$Value"
}

if ($ArtifactsStorageAccount) {
    Set-GhVariable -Name 'ARTIFACTS_STORAGE_ACCOUNT' -Value $ArtifactsStorageAccount -Repo $GitHubRepo
} else {
    Write-Host "  -ArtifactsStorageAccount not provided." -ForegroundColor Yellow
    Write-Host "  Set this with the SA name produced by Initialize-RdsFarm.ps1 / prereqs/tier0.bicep" -ForegroundColor Yellow
    Write-Host "  before you can trigger the deploy workflow." -ForegroundColor Yellow
}

if ($Location) {
    Set-GhVariable -Name 'AZURE_LOCATION' -Value $Location -Repo $GitHubRepo
} else {
    Write-Host "  -Location not provided; workflow will use the AZURE_LOCATION repo variable fallback in deploy.yml." -ForegroundColor Yellow
}

if ($FarmResourceGroup) {
    Set-GhVariable -Name 'AZURE_RESOURCE_GROUP' -Value $FarmResourceGroup -Repo $GitHubRepo
} else {
    Write-Host "  -FarmResourceGroup not provided; workflow will use its default ('rds-farm-rg')." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# 6. GitHub environments
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "==> Step 6: GitHub environments" -ForegroundColor Green

foreach ($envName in @('preview','production')) {
    Write-Host "  Creating/updating environment '$envName'..."
    if ($envName -eq 'production' -and $RequireProductionApproval) {
        $me = gh api user --jq .id
        if ($LASTEXITCODE -ne 0) { throw "Failed to query current GitHub user." }
        $body = @{
            reviewers = @(@{ type = 'User'; id = [int]$me })
        } | ConvertTo-Json -Compress
    } else {
        $body = '{}'
    }
    $body | gh api -X PUT "repos/$GitHubRepo/environments/$envName" --input - 1>$null
    if ($LASTEXITCODE -ne 0) { throw "Failed to create environment '$envName'." }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
# The "Next steps" footer is for standalone runs and explains how to finish
# the deploy by hand. When called from Initialize-RdsFarm.ps1 (-SkipSelfCheck)
# those steps are bogus — the orchestrator does them all automatically in its
# remaining steps — so suppress the whole footer in that case.
if (-not $SkipSelfCheck) {
    Write-Host ""
    Write-Host "==================== Bootstrap complete ====================" -ForegroundColor Green
    Write-Host "App ID (AZURE_CLIENT_ID) : $AppId"
    Write-Host "Tenant                   : $TenantId"
    Write-Host "Subscription             : $SubscriptionId"
    Write-Host "Service principal OID    : $SpObjectId"
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Cyan
    Write-Host "  1. Deploy prereqs/tier0.bicep from this laptop to create the artifacts SA + KV:"
    Write-Host "        scripts/Initialize-RdsFarm.ps1   (recommended orchestrator)"
    Write-Host "     or follow docs/prereq-resources.md Option 2 (manual az deployment sub create)."
    Write-Host "  2. Set the ARTIFACTS_STORAGE_ACCOUNT repo variable to the new SA name:"
    Write-Host "        gh variable set ARTIFACTS_STORAGE_ACCOUNT --repo $GitHubRepo --body <name>"
    Write-Host "     (Initialize-RdsFarm.ps1 does this for you.)"
    Write-Host "  3. Create the TLS certificate in the new Key Vault (docs/fqdn-and-cert.md)."
    Write-Host "  4. Update main.bicepparam with keyVaultName / keyVaultResourceGroup /"
    Write-Host "     keyVaultCertSecretUri."
    Write-Host "  5. In GitHub: Actions -> Deploy RDS Farm -> Run workflow with action: what-if."
    Write-Host "  6. Re-run with action: deploy once the what-if plan looks right."
} else {
    Write-Host ""
    Write-Host "    CI bootstrap done (App ID $AppId, SP OID $SpObjectId)." -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# 7. Self-check (read-only)
# ---------------------------------------------------------------------------
if ($SkipSelfCheck) {
    Write-Host ""
    Write-Host "(Self-check skipped — caller passed -SkipSelfCheck.)" -ForegroundColor DarkGray
    exit 0
}
$selfCheck = Join-Path $PSScriptRoot '..\tests\Test-CiPrerequisites.ps1'
if (Test-Path -LiteralPath $selfCheck) {
    Write-Host ""
    Write-Host "==> Step 7: Self-check (tests/Test-CiPrerequisites.ps1)" -ForegroundColor Green
    Write-Host "    Verifying everything the bootstrap just created is in place..."
    try {
        & $selfCheck -GitHubRepo $GitHubRepo -AppDisplayName $AppDisplayName -SubscriptionId $SubscriptionId
        if ($LASTEXITCODE -ne 0) {
            Write-Host ""
            Write-Host "Self-check reported issues (see PASS/WARN/FAIL output above)." -ForegroundColor Yellow
            Write-Host "Re-run this bootstrap, or fix the failing item by hand and re-run:" -ForegroundColor Yellow
            Write-Host "  ./tests/Test-CiPrerequisites.ps1 -GitHubRepo $GitHubRepo" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "Self-check threw: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "Bootstrap itself succeeded; run the self-check manually:" -ForegroundColor Yellow
        Write-Host "  ./tests/Test-CiPrerequisites.ps1 -GitHubRepo $GitHubRepo" -ForegroundColor Yellow
    }
} else {
    Write-Host ""
    Write-Host "(Self-check skipped — tests/Test-CiPrerequisites.ps1 not found.)" -ForegroundColor DarkGray
}

# Make the exit code explicit. Without this, $LASTEXITCODE leaks through
# from whatever native command (gh / az) ran last — e.g. a 'gh variable get'
# that returned 1 because the variable didn't exist (a non-fatal case the
# self-check handled as a soft-warn) would still register as exit 1 here
# and trip the orchestrator's '$LASTEXITCODE -ne 0' guard.
exit 0
