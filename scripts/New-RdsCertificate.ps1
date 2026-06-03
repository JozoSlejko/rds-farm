<#
.SYNOPSIS
    Create or import the TLS certificate for the RDS gateway in Key Vault.

.DESCRIPTION
    Automates the three flows in docs/manual-deploy.md Step 3:
      * Csr         — generate a CSR in Key Vault for a public CA to sign
                      (Option A). Writes the CSR to .csr file for you to
                      submit. Run again with -MergeSignedCert <file.cer>
                      after the CA returns the issued cert.
      * ImportPfx   — import an existing .pfx (Option B). Prompts for the
                      PFX password with Read-Host -AsSecureString.
      * SelfSigned  — Key Vault self-signs (Option C). Lab/dev only.

    All flows:
      * Force exportable = true (the most common gotcha that breaks
        Set-RDCertificate during DSC apply).
      * Use the Server Authentication EKU (OID 1.3.6.1.5.5.7.3.1).
      * Set the cert Subject + a single SAN DNS name.
      * After success: print the secret URI WITHOUT the version segment,
        ready to paste into main.bicepparam (keyVaultCertSecretUri).

    Idempotent for ImportPfx / SelfSigned (re-imports overwrite). For Csr,
    re-running before merge keeps the same pending operation.

.PARAMETER VaultName
    Name of the RBAC-enabled Key Vault.

.PARAMETER CertName
    Name to give the certificate object (default 'rds-tls').

.PARAMETER Fqdn
    Hostname for the Subject CN and the SAN DNS entry.
    Examples: 'rds.contoso.com', '*.contoso.com',
              'contoso-rds.westeurope.cloudapp.azure.com'.
    For SelfSigned, use the exact hostname your RD clients will type.

.PARAMETER Mode
    'Csr', 'ImportPfx', or 'SelfSigned'.

.PARAMETER PfxPath
    Required when -Mode ImportPfx. Path to the .pfx file.

.PARAMETER MergeSignedCert
    Optional path to a CA-signed cert (.cer / .crt) to merge into a pending
    CSR-mode certificate. Use this on the second run after submitting the CSR.
    When supplied, -Mode is ignored.

.PARAMETER ValidityMonths
    Default 12. Ignored when -MergeSignedCert is supplied (the CA decides).

.PARAMETER OutputBicepParam
    Optional path to main.bicepparam. When supplied AND the cert is
    successfully created/merged, this script invokes
    scripts/Set-BicepParamCertUri.ps1 to update keyVaultName /
    keyVaultCertSecretUri / certificateSubject in one go.

.EXAMPLE
    # Lab: self-signed in 30 seconds
    .\scripts\New-RdsCertificate.ps1 `
        -VaultName contoso-rds-kv `
        -Fqdn 'contoso-rds.westeurope.cloudapp.azure.com' `
        -Mode SelfSigned

.EXAMPLE
    # Production: generate CSR for a public CA
    .\scripts\New-RdsCertificate.ps1 `
        -VaultName contoso-rds-kv `
        -Fqdn 'rds.contoso.com' `
        -Mode Csr
    # ... submit the .csr to your CA ...
    .\scripts\New-RdsCertificate.ps1 `
        -VaultName contoso-rds-kv `
        -Fqdn 'rds.contoso.com' `
        -Mode Csr `
        -MergeSignedCert .\rds.cer

.EXAMPLE
    # Production: import an existing PFX and update bicepparam in one step
    .\scripts\New-RdsCertificate.ps1 `
        -VaultName contoso-rds-kv `
        -Fqdn 'rds.contoso.com' `
        -Mode ImportPfx `
        -PfxPath .\rds-contoso-com.pfx `
        -OutputBicepParam ..\main.bicepparam

.NOTES
    Requires:
      * 'az' signed in.
      * 'Key Vault Certificates Officer' on the target vault.
#>
[CmdletBinding(DefaultParameterSetName = 'Create')]
param(
    [Parameter(Mandatory)]
    [string]$VaultName,

    [string]$CertName = 'rds-tls',

    [Parameter(Mandatory)]
    [string]$Fqdn,

    [Parameter(ParameterSetName = 'Create', Mandatory)]
    [ValidateSet('Csr','ImportPfx','SelfSigned')]
    [string]$Mode,

    [Parameter(ParameterSetName = 'Create')]
    [string]$PfxPath,

    [Parameter(ParameterSetName = 'Merge', Mandatory)]
    [string]$MergeSignedCert,

    [int]$ValidityMonths = 12,

    [string]$OutputBicepParam
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

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

function Get-CertSubject { param([string]$Fqdn) "CN=$Fqdn" }

function Get-VersionlessSecretUri {
    param([string]$Vault, [string]$Name)
    $sid = az keyvault certificate show --vault-name $Vault --name $Name --query 'sid' -o tsv
    if ($LASTEXITCODE -ne 0 -or -not $sid) { throw "Could not read sid for $Name in $Vault." }
    # https://<vault>.vault.azure.net/secrets/<name>/<version>  ->  drop the version
    ($sid -split '/')[0..4] -join '/'
}

function New-KvCertPolicy {
    <#
        Build a Key Vault certificate policy in the camelCase shape the REST
        API (and modern Azure CLI) uses. Earlier versions of this function
        read 'az keyvault certificate get-default-policy' and patched the
        snake_case fields (key_props / x509_props / issuer_parameters), but
        the CLI switched the output to camelCase (keyProperties /
        x509CertificateProperties / issuerParameters), so the patch silently
        no-op'd and Set-StrictMode threw "key_props cannot be found".
        Building from scratch sidesteps the shape drift and gives us exactly
        the fields we need (SAN + Server Auth EKU + exportable key).
    #>
    param(
        [string]$Fqdn,
        [string]$IssuerName,            # 'Unknown' for CSR mode, 'Self' for self-signed
        [int]   $ValidityMonths
    )
    return @{
        keyProperties = @{
            exportable = $true
            keyType    = 'RSA'
            keySize    = 2048
            reuseKey   = $false
        }
        secretProperties = @{
            contentType = 'application/x-pkcs12'
        }
        x509CertificateProperties = @{
            subject = Get-CertSubject $Fqdn
            subjectAlternativeNames = @{
                dnsNames = @($Fqdn)
                emails   = @()
                upns     = @()
            }
            ekus = @('1.3.6.1.5.5.7.3.1')           # Server Authentication
            keyUsage = @(
                'digitalSignature',
                'keyEncipherment'
            )
            validityInMonths = $ValidityMonths
        }
        issuerParameters = @{
            name = $IssuerName
        }
        lifetimeActions = @(
            @{
                trigger = @{ daysBeforeExpiry = 90 }
                action  = @{ actionType       = 'AutoRenew' }
            }
        )
    }
}

function Save-PolicyToTempFile {
    param([object]$Policy)
    $tmp = New-TemporaryFile
    $Policy | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $tmp.FullName -Encoding utf8
    return $tmp
}

# ---------------------------------------------------------------------------
# 0. Pre-flight
# ---------------------------------------------------------------------------
Write-Host "==> Pre-flight" -ForegroundColor Cyan
Assert-Tool 'az'

$ctx = az account show -o json 2>$null | ConvertFrom-Json
if (-not $ctx) { throw "Not logged in to Azure. Run 'az login' first." }
Write-Host "    Subscription : $($ctx.name)"
Write-Host "    Vault        : $VaultName"
Write-Host "    Cert name    : $CertName"
Write-Host "    Subject      : $(Get-CertSubject $Fqdn)"

# Verify the vault exists & is RBAC-enabled.
$kv = az keyvault show --name $VaultName -o json 2>$null | ConvertFrom-Json
if (-not $kv) { throw "Key Vault '$VaultName' not found (or you lack 'list' permission)." }
if (-not $kv.properties.enableRbacAuthorization) {
    throw "Vault '$VaultName' is in access-policy mode. Run: az keyvault update -n $VaultName --enable-rbac-authorization true"
}
Write-Host "    RBAC enabled : true"

# ---------------------------------------------------------------------------
# Branch: merge a signed CSR vs create a new cert
# ---------------------------------------------------------------------------
if ($PSCmdlet.ParameterSetName -eq 'Merge') {
    Write-Host ""
    Write-Host "==> Merge signed CSR" -ForegroundColor Green
    if (-not (Test-Path -LiteralPath $MergeSignedCert -PathType Leaf)) {
        throw "Signed cert file not found: $MergeSignedCert"
    }
    Write-Host "    Merging $MergeSignedCert into pending cert '$CertName'..."
    az keyvault certificate pending merge `
        --vault-name $VaultName `
        --name       $CertName `
        --file       $MergeSignedCert | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Merge failed. Verify the cert matches the CSR." }
} else {
    switch ($Mode) {
        'Csr' {
            Write-Host ""
            Write-Host "==> Create CSR + pending cert" -ForegroundColor Green
            $policy   = New-KvCertPolicy -Fqdn $Fqdn -IssuerName 'Unknown' -ValidityMonths $ValidityMonths
            $tmpFile  = Save-PolicyToTempFile -Policy $policy
            try {
                az keyvault certificate create `
                    --vault-name $VaultName `
                    --name       $CertName `
                    --policy     "@$($tmpFile.FullName)" | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "create failed." }
            } finally {
                Remove-Item -LiteralPath $tmpFile.FullName -Force -ErrorAction SilentlyContinue
            }

            $csr = az keyvault certificate pending show `
                --vault-name $VaultName --name $CertName --query csr -o tsv
            if (-not $csr) { throw "No CSR returned — cert may already be issued." }

            $csrFile = Join-Path (Get-Location) "$CertName.csr"
            @(
                '-----BEGIN CERTIFICATE REQUEST-----'
                $csr
                '-----END CERTIFICATE REQUEST-----'
            ) | Set-Content -LiteralPath $csrFile -Encoding ascii

            Write-Host ""
            Write-Host "==================== CSR written ====================" -ForegroundColor Green
            Write-Host "CSR file : $csrFile"
            Write-Host ""
            Write-Host "Next steps:" -ForegroundColor Cyan
            Write-Host "  1. Submit $csrFile to your public CA."
            Write-Host "  2. Save the signed cert as e.g. .\$CertName.cer"
            Write-Host "  3. Re-run this script with -MergeSignedCert .\$CertName.cer"
            return
        }

        'ImportPfx' {
            if (-not $PfxPath) { throw "-PfxPath is required for -Mode ImportPfx." }
            if (-not (Test-Path -LiteralPath $PfxPath -PathType Leaf)) {
                throw "PFX file not found: $PfxPath"
            }
            Write-Host ""
            Write-Host "==> Import PFX" -ForegroundColor Green
            $pwdSecure = Read-Host -Prompt '    PFX password (silent)' -AsSecureString
            $pwdPlain  = $null
            try {
                $pwdPlain = ConvertFrom-SecureStringPlain $pwdSecure
                az keyvault certificate import `
                    --vault-name $VaultName `
                    --name       $CertName `
                    --file       $PfxPath `
                    --password   $pwdPlain | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "import failed." }
            } finally {
                $pwdPlain = $null
                [GC]::Collect()
            }

            # Force-verify exportable. NOTE: 'az keyvault certificate show-policy'
            # is not a real CLI subcommand; use 'show ... --query policy.<...>'.
            $exp = az keyvault certificate show --vault-name $VaultName --name $CertName --query 'policy.keyProperties.exportable' -o tsv
            if ($exp -ne 'true') {
                throw "Imported cert has exportable=$exp. Re-issue with exportable key material — RDS DSC will fail otherwise."
            }
            Write-Host "    exportable=true verified."
        }

        'SelfSigned' {
            Write-Host ""
            Write-Host "==> Create self-signed cert (lab/dev only)" -ForegroundColor Green
            $policy  = New-KvCertPolicy -Fqdn $Fqdn -IssuerName 'Self' -ValidityMonths $ValidityMonths
            $tmpFile = Save-PolicyToTempFile -Policy $policy
            try {
                az keyvault certificate create `
                    --vault-name $VaultName `
                    --name       $CertName `
                    --policy     "@$($tmpFile.FullName)" | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "create failed." }
            } finally {
                Remove-Item -LiteralPath $tmpFile.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Print the version-less secret URI for bicepparam
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "==> Secret URI for main.bicepparam" -ForegroundColor Green
$secretUri = Get-VersionlessSecretUri -Vault $VaultName -Name $CertName

Write-Host ""
Write-Host "==================== Done ====================" -ForegroundColor Green
Write-Host "keyVaultName          = '$VaultName'"
Write-Host "keyVaultCertSecretUri = '$secretUri'"
Write-Host "certificateSubject    = '$(Get-CertSubject $Fqdn)'"

if ($OutputBicepParam) {
    Write-Host ""
    Write-Host "==> Updating bicepparam: $OutputBicepParam" -ForegroundColor Green
    $updater = Join-Path $PSScriptRoot 'Set-BicepParamCertUri.ps1'
    & $updater `
        -ParamFile             $OutputBicepParam `
        -KeyVaultName          $VaultName `
        -KeyVaultCertSecretUri $secretUri `
        -CertificateSubject    (Get-CertSubject $Fqdn)
}

[pscustomobject]@{
    KeyVaultName          = $VaultName
    KeyVaultCertSecretUri = $secretUri
    CertificateSubject    = Get-CertSubject $Fqdn
}
