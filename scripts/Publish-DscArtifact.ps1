<#
.SYNOPSIS
    Package dsc/Configuration.ps1 and upload it to the artifacts storage account.

.DESCRIPTION
    Mirrors the `package-dsc` + `upload-artifacts` jobs in
    .github/workflows/deploy.yml for users running deployments by hand.
    Idempotent: re-running just overwrites the blob.

    Steps (all idempotent):
      1. Compress dsc/Configuration.ps1 into Configuration.zip.
      2. Upload the zip to <StorageAccount>/<Container>/<BlobName>
         using --auth-mode login (your Entra identity, no account keys).
      3. Print the artifacts base URL.

    No SAS is generated. The DSC extension authenticates to blob storage with
    the VM's user-assigned managed identity (Storage Blob Data Reader role on
    the SA, granted by modules/sa-role.bicep). The tenant policy in use here
    blocks both shared-key and SAS access, so this is the only viable path.

    The output object has these properties:
      ArtifactsLocation   # e.g. https://contosordsart01.blob.core.windows.net/dsc/
      BlobUrl             # full URL to the blob

    Capture the output to feed straight into Invoke-ManualDeploy.ps1 or to
    populate the ARTIFACTS_LOCATION environment variable.

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

.PARAMETER Repo
    Optional GitHub repo in the format <org>/<repo>. When supplied, the script
    reads ARTIFACTS_STORAGE_ACCOUNT from the repo variables (via `gh`).

.PARAMETER SetEnvVars
    Switch. When set, also assigns the value to $env:ARTIFACTS_LOCATION in the
    caller's session (handy before running az deployment manually).

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

$artifactsLocation = "https://$StorageAccount.blob.core.windows.net/$Container/"
$blobUrl = "$artifactsLocation$BlobName"

# ---------------------------------------------------------------------------
# 3. Result
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "==================== Done ====================" -ForegroundColor Green
Write-Host "ArtifactsLocation : $artifactsLocation"
Write-Host "BlobUrl           : $blobUrl"
Write-Host "Auth              : VM managed identity (Storage Blob Data Reader)"

if ($SetEnvVars) {
    $env:ARTIFACTS_LOCATION = $artifactsLocation
    Write-Host ""
    Write-Host "    Set `$env:ARTIFACTS_LOCATION in this session." -ForegroundColor Cyan
}

[pscustomobject]@{
    ArtifactsLocation = $artifactsLocation
    BlobUrl           = $blobUrl
}
