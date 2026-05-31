<#
.SYNOPSIS
    Package dsc/Configuration.ps1 and upload it to the artifacts storage account.

.DESCRIPTION
    Mirrors the `package-dsc` + `upload-artifacts` jobs in
    .github/workflows/deploy.yml for users running deployments by hand.
    Idempotent: re-running just overwrites the blob and mints a fresh SAS.

    Steps (all idempotent):
      1. Compress dsc/Configuration.ps1 into Configuration.zip.
      2. Upload the zip to <StorageAccount>/<Container>/<BlobName>
         using --auth-mode login (your Entra identity, no account keys).
      3. Mint a short-lived USER-DELEGATION SAS (default 2 hours, read-only).
      4. Print the artifacts base URL and the SAS as two object fields.

    The output object has these properties:
      ArtifactsLocation   # e.g. https://contosordsart01.blob.core.windows.net/dsc/
      ArtifactsSas        # e.g. ?sv=...&sig=...   (already prefixed with '?')
      BlobUrl             # full URL to the blob (no SAS)
      Expiry              # SAS expiry, ISO-8601 UTC

    Capture the output to feed straight into Invoke-ManualDeploy.ps1 or to
    populate the ARTIFACTS_SAS / ARTIFACTS_LOCATION environment variables.

.PARAMETER StorageAccount
    Name of the storage account that hosts the DSC artifacts. If omitted, the
    script reads the GitHub repo variable ARTIFACTS_STORAGE_ACCOUNT (when -Repo
    is also supplied) or falls back to the env var ARTIFACTS_STORAGE_ACCOUNT.

.PARAMETER Container
    Blob container name. Default: 'dsc' (matches workflow ARTIFACTS_CONTAINER).

.PARAMETER BlobName
    Target blob name. Default: 'Configuration.zip'.

.PARAMETER ConfigurationPath
    Path to the DSC script to package. Default: <repo>/dsc/Configuration.ps1.

.PARAMETER SasExpiryHours
    SAS token lifetime in hours. Default: 2 (matches workflow).

.PARAMETER Repo
    Optional GitHub repo in the format <org>/<repo>. When supplied, the script
    reads ARTIFACTS_STORAGE_ACCOUNT from the repo variables (via `gh`).

.PARAMETER SetEnvVars
    Switch. When set, also assigns the values to $env:ARTIFACTS_LOCATION /
    $env:ARTIFACTS_SAS in the caller's session (handy before running az
    deployment manually).

.EXAMPLE
    .\scripts\Publish-DscArtifact.ps1 -StorageAccount contosordsart01

.EXAMPLE
    $a = .\scripts\Publish-DscArtifact.ps1 -StorageAccount contosordsart01 -SetEnvVars
    az deployment group what-if -g rds-farm-rg `
        --template-file main.bicep `
        --parameters main.bicepparam `
        --parameters artifactsLocation=$($a.ArtifactsLocation)

.NOTES
    Requires:
      * Azure CLI signed in (`az login`).
      * 'Storage Blob Data Contributor' on the storage account (the prereqs
        template grants this to adminPrincipals).
#>
[CmdletBinding()]
param(
    [string]$StorageAccount,
    [string]$Container = 'dsc',
    [string]$BlobName  = 'Configuration.zip',
    [string]$ConfigurationPath = (Join-Path $PSScriptRoot '..' 'dsc' 'Configuration.ps1'),
    [int]   $SasExpiryHours = 2,
    [ValidatePattern('^[^/]+/[^/]+$')]
    [string]$Repo,
    [switch]$SetEnvVars
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

$ConfigurationPath = (Resolve-Path -LiteralPath $ConfigurationPath).Path
if (-not (Test-Path -LiteralPath $ConfigurationPath -PathType Leaf)) {
    throw "DSC configuration not found: $ConfigurationPath"
}
Write-Host "    Source : $ConfigurationPath"

if (-not $StorageAccount) {
    if ($Repo) {
        Assert-Tool 'gh'
        Write-Host "    Reading ARTIFACTS_STORAGE_ACCOUNT from repo $Repo..."
        $StorageAccount = (gh variable get ARTIFACTS_STORAGE_ACCOUNT --repo $Repo 2>$null).Trim()
        if (-not $StorageAccount) {
            throw "Repo variable ARTIFACTS_STORAGE_ACCOUNT is not set on $Repo."
        }
    } elseif ($env:ARTIFACTS_STORAGE_ACCOUNT) {
        $StorageAccount = $env:ARTIFACTS_STORAGE_ACCOUNT
    } else {
        throw "Specify -StorageAccount, or -Repo <org>/<repo>, or set `$env:ARTIFACTS_STORAGE_ACCOUNT."
    }
}
Write-Host "    Target : $StorageAccount/$Container/$BlobName"

$ctx = az account show -o json 2>$null | ConvertFrom-Json
if (-not $ctx) { throw "Not logged in to Azure. Run 'az login' first." }
Write-Host "    Subscription : $($ctx.name)"

# ---------------------------------------------------------------------------
# 1. Package
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "==> Step 1: Package Configuration.zip" -ForegroundColor Green

$zipDir  = Split-Path -Path $ConfigurationPath -Parent
$zipPath = Join-Path $zipDir 'Configuration.zip'
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}
Compress-Archive -LiteralPath $ConfigurationPath -DestinationPath $zipPath -Force
$zipBytes = (Get-Item -LiteralPath $zipPath).Length
Write-Host "    Wrote $zipPath ($zipBytes bytes)"

# ---------------------------------------------------------------------------
# 2. Upload
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "==> Step 2: Upload to blob storage" -ForegroundColor Green

az storage blob upload `
    --account-name   $StorageAccount `
    --container-name $Container `
    --name           $BlobName `
    --file           $zipPath `
    --overwrite `
    --auth-mode      login | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Blob upload failed. Make sure you have 'Storage Blob Data Contributor' on $StorageAccount."
}
Write-Host "    Uploaded."

# ---------------------------------------------------------------------------
# 3. Generate user-delegation SAS
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "==> Step 3: Generate user-delegation SAS (${SasExpiryHours}h, read-only)" -ForegroundColor Green

# az expects ISO-8601 with minute precision: 2026-06-01T12:34Z
$expiryUtc = (Get-Date).ToUniversalTime().AddHours($SasExpiryHours)
$expiryStr = $expiryUtc.ToString('yyyy-MM-ddTHH:mmZ')

$sas = az storage blob generate-sas `
    --account-name   $StorageAccount `
    --container-name $Container `
    --name           $BlobName `
    --permissions    r `
    --expiry         $expiryStr `
    --auth-mode      login `
    --as-user `
    --https-only `
    -o tsv
if ($LASTEXITCODE -ne 0 -or -not $sas) {
    throw "SAS generation failed. Re-check your role assignments."
}
$sasToken = "?$sas"
$artifactsLocation = "https://$StorageAccount.blob.core.windows.net/$Container/"
$blobUrl = "$artifactsLocation$BlobName"

# ---------------------------------------------------------------------------
# 4. Result
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "==================== Done ====================" -ForegroundColor Green
Write-Host "ArtifactsLocation : $artifactsLocation"
Write-Host "BlobUrl           : $blobUrl"
Write-Host "Expiry            : $expiryStr"
Write-Host "ArtifactsSas      : (suppressed; in returned object / env var)"

if ($SetEnvVars) {
    $env:ARTIFACTS_LOCATION = $artifactsLocation
    $env:ARTIFACTS_SAS      = $sasToken
    Write-Host ""
    Write-Host "    Set `$env:ARTIFACTS_LOCATION and `$env:ARTIFACTS_SAS in this session." -ForegroundColor Cyan
}

[pscustomobject]@{
    ArtifactsLocation = $artifactsLocation
    ArtifactsSas      = $sasToken
    BlobUrl           = $blobUrl
    Expiry            = $expiryStr
}
