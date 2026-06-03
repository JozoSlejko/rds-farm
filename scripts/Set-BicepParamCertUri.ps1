<#
.SYNOPSIS
    Patch the cert-binding params in main.bicepparam in place.

.DESCRIPTION
    Rewrites these lines in a Bicep .bicepparam file using regex substitution:
      param enableCertificateBinding = ...
      param keyVaultName             = '...'
      param keyVaultResourceGroup    = '...'   (optional)
      param keyVaultCertSecretUri    = '...'
      param certificateSubject       = '...'
      param publicGatewayFqdn        = '...'   (optional)

    Designed to be called by New-RdsCertificate.ps1 after a successful cert
    create/import, but you can also call it directly when you re-issue a cert.

    Safety:
      * Writes a backup file at <ParamFile>.bak unless -NoBackup is set.
      * Re-runs `az bicep build-params` after the edit to confirm the file
        still parses; restores the .bak on failure.
      * Does NOT modify params you didn't pass.

.PARAMETER ParamFile
    Path to main.bicepparam.

.PARAMETER KeyVaultName
    New value for `keyVaultName`.

.PARAMETER KeyVaultResourceGroup
    Optional. New value for `keyVaultResourceGroup`.

.PARAMETER KeyVaultCertSecretUri
    New value for `keyVaultCertSecretUri` (no version segment — the deploy will
    always serve the current version).

.PARAMETER CertificateSubject
    New value for `certificateSubject`, e.g. 'CN=rds.contoso.com'.

.PARAMETER PublicGatewayFqdn
    Optional. New value for `publicGatewayFqdn`.

.PARAMETER EnableCertificateBinding
    Optional ($true / $false). When supplied, sets `enableCertificateBinding`.

.PARAMETER NoBackup
    Skip writing the .bak file (use this only in CI).

.EXAMPLE
    .\scripts\Set-BicepParamCertUri.ps1 `
        -ParamFile .\main.bicepparam `
        -KeyVaultName contoso-rds-kv `
        -KeyVaultCertSecretUri 'https://contoso-rds-kv.vault.azure.net/secrets/rds-tls' `
        -CertificateSubject 'CN=rds.contoso.com'

.NOTES
    Uses a line-oriented regex (one param per line — same shape as the
    repo's main.bicepparam). If you've collapsed lines or added comments
    mid-line, eyeball the diff after running.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ParamFile,

    [string]$KeyVaultName,
    [string]$KeyVaultResourceGroup,
    [string]$KeyVaultCertSecretUri,
    [string]$CertificateSubject,
    [string]$PublicGatewayFqdn,
    [Nullable[bool]]$EnableCertificateBinding,

    [switch]$NoBackup
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ParamFile = (Resolve-Path -LiteralPath $ParamFile).Path
if (-not (Test-Path -LiteralPath $ParamFile -PathType Leaf)) {
    throw "Param file not found: $ParamFile"
}

# ---------------------------------------------------------------------------
# 1. Backup
# ---------------------------------------------------------------------------
$backup = "$ParamFile.bak"
if (-not $NoBackup) {
    Copy-Item -LiteralPath $ParamFile -Destination $backup -Force
    Write-Host "Backup written: $backup"
}

# ---------------------------------------------------------------------------
# 2. In-place substitution
# ---------------------------------------------------------------------------
$content = Get-Content -LiteralPath $ParamFile -Raw
$origLen = $content.Length

function Set-StringParam {
    param([string]$Body, [string]$Name, [string]$Value)
    if (-not $Value) { return $Body }
    # match: param <Name> = '<anything-not-newline>'
    $pattern = "(?m)^(?<lead>\s*param\s+$([regex]::Escape($Name))\s*=\s*)'[^']*'"
    if ($Body -notmatch $pattern) {
        Write-Warning "  param $Name not found in $ParamFile — skipped."
        return $Body
    }
    $replacement = "`${lead}'$Value'"
    return [regex]::Replace($Body, $pattern, $replacement)
}

function Set-BoolParam {
    param([string]$Body, [string]$Name, [Nullable[bool]]$Value)
    if ($null -eq $Value) { return $Body }
    $literal = if ($Value) { 'true' } else { 'false' }
    $pattern = "(?m)^(?<lead>\s*param\s+$([regex]::Escape($Name))\s*=\s*)(true|false)"
    if ($Body -notmatch $pattern) {
        Write-Warning "  param $Name not found in $ParamFile — skipped."
        return $Body
    }
    return [regex]::Replace($Body, $pattern, "`${lead}$literal")
}

$changes = @()
if ($EnableCertificateBinding -ne $null) {
    $content = Set-BoolParam   -Body $content -Name 'enableCertificateBinding' -Value $EnableCertificateBinding
    $changes += 'enableCertificateBinding'
}
if ($KeyVaultName) {
    $content = Set-StringParam -Body $content -Name 'keyVaultName'             -Value $KeyVaultName
    $changes += 'keyVaultName'
}
if ($KeyVaultResourceGroup) {
    $content = Set-StringParam -Body $content -Name 'keyVaultResourceGroup'    -Value $KeyVaultResourceGroup
    $changes += 'keyVaultResourceGroup'
}
if ($KeyVaultCertSecretUri) {
    $content = Set-StringParam -Body $content -Name 'keyVaultCertSecretUri'    -Value $KeyVaultCertSecretUri
    $changes += 'keyVaultCertSecretUri'
}
if ($CertificateSubject) {
    $content = Set-StringParam -Body $content -Name 'certificateSubject'       -Value $CertificateSubject
    $changes += 'certificateSubject'
}
if ($PublicGatewayFqdn) {
    $content = Set-StringParam -Body $content -Name 'publicGatewayFqdn'        -Value $PublicGatewayFqdn
    $changes += 'publicGatewayFqdn'
}

if ($changes.Count -eq 0) {
    Write-Host "Nothing to change. Pass at least one of: -KeyVaultName, -KeyVaultResourceGroup, -KeyVaultCertSecretUri, -CertificateSubject, -PublicGatewayFqdn, -EnableCertificateBinding." -ForegroundColor Yellow
    return
}

Set-Content -LiteralPath $ParamFile -Value $content -Encoding utf8 -NoNewline
$newLen = (Get-Item -LiteralPath $ParamFile).Length
Write-Host "Updated $($changes.Count) param(s): $($changes -join ', ')"
Write-Host "  ($origLen -> $newLen bytes)"

# ---------------------------------------------------------------------------
# 3. Validate
# ---------------------------------------------------------------------------
if (Get-Command az -ErrorAction SilentlyContinue) {
    Write-Host ""
    Write-Host "==> Verifying with az bicep build-params" -ForegroundColor Green

    foreach ($v in 'DOMAIN_JOIN_PASSWORD', 'LOCAL_ADMIN_PASSWORD') {
        if (-not [Environment]::GetEnvironmentVariable($v)) {
            [Environment]::SetEnvironmentVariable($v, 'placeholder-for-validation-only', 'Process')
        }
    }

    $tmp = New-TemporaryFile
    try {
        & az bicep build-params --file $ParamFile --outfile $tmp.FullName 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) {
            if (-not $NoBackup) {
                Copy-Item -LiteralPath $backup -Destination $ParamFile -Force
                Write-Host "Restored original from $backup" -ForegroundColor Yellow
                throw "Updated $ParamFile no longer compiles. Original restored."
            }
            throw "Updated $ParamFile no longer compiles. -NoBackup was set, so no restore; your file is in the modified state."
        }
        Write-Host "    OK — compiled successfully."
    } finally {
        Remove-Item -LiteralPath $tmp.FullName -Force -ErrorAction SilentlyContinue
    }
} else {
    Write-Warning "az CLI not in PATH — skipped post-edit validation."
}
