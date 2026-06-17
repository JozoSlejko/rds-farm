<#
.SYNOPSIS
    Issue/renew a Let's Encrypt (DV) TLS certificate for the RDS farm via DNS-01,
    import it into Key Vault, and stage a PFX for the Entra application proxy upload.

.DESCRIPTION
    Phase 1 of the Entra application proxy migration (see docs/app-proxy.md). Uses
    Posh-ACME with the Azure DNS plugin and a CNAME challenge alias, so the ACME
    TXT record is written to an Azure DNS zone you control. GoDaddy hosts
    slejco.com but gates its API, so only a single static CNAME lives there.

    Flow:
      1. Ensure Posh-ACME is available and point it at Let's Encrypt (staging with
         -Staging, production otherwise).
      2. Request/renew the cert for -Fqdn using DNS-01. Posh-ACME writes the TXT to
         -DnsAlias in Azure DNS (auth via the host's managed identity by default,
         or a service principal). Let's Encrypt follows the static GoDaddy CNAME
         (_acme-challenge.<fqdn> -> <alias>) to read it.
      3. Import the new full-chain PFX into Key Vault (-CertName, default rds-tls)
         so the existing KV VM extension + DSC bind it on the RDS roles.
      4. Stage the full-chain PFX (path + password) so Configure-AppProxy.ps1 can
         upload it to the app registration - App Proxy can't pull from Key Vault.

    One-time prerequisites (see docs/app-proxy.md):
      * Azure DNS public zone for the alias parent (e.g. acme.slejco.com),
        delegated from GoDaddy with an NS record.
      * Static GoDaddy CNAME: _acme-challenge.<fqdn> -> <DnsAlias>.
      * The identity running this (managed identity or service principal) can write
        TXT records in that Azure DNS zone (a custom "DNS TXT Contributor" role is
        enough - least privilege).
      * Run from an IN-VNET host: Key Vault is private-endpoint-only.

.PARAMETER Fqdn
    Public vanity hostname the cert is for. Default: rds.slejco.com.

.PARAMETER DnsAlias
    The Azure DNS record where Posh-ACME writes the challenge TXT. The static
    GoDaddy CNAME _acme-challenge.<Fqdn> must point here. Default: rds.acme.slejco.com.

.PARAMETER KeyVaultName
    Key Vault that holds the RDS cert. Default: rdsjslejcokv01.

.PARAMETER CertName
    Key Vault certificate name. Default: rds-tls (matches keyVaultCertSecretUri).

.PARAMETER Contact
    Email for the Let's Encrypt account (expiry notices). Required.

.PARAMETER SubscriptionId
    Subscription containing the Azure DNS zone. Defaults to the current az account.

.PARAMETER Staging
    Use the Let's Encrypt STAGING environment (recommended for the first run to
    avoid burning production rate limits while you validate delegation).

.PARAMETER UseServicePrincipal
    Authenticate the Azure DNS plugin with a service principal instead of the
    host's managed identity. Requires -ServicePrincipalCredential and -TenantId.

.PARAMETER ServicePrincipalCredential
    PSCredential for the service principal: AppId as username, client secret as
    password. Used only with -UseServicePrincipal.

.PARAMETER TenantId
    Entra tenant GUID. Used only with -UseServicePrincipal.

.PARAMETER PfxOutDir
    Directory to stage the App Proxy PFX. Default: <temp>/rds-appproxy.

.PARAMETER Force
    Force renewal even if the current cert isn't due, and force the Key Vault import.

.EXAMPLE
    ./New-LetsEncryptRdsCertificate.ps1 -Contact admin@slejco.com -Staging
    First run against Let's Encrypt STAGING using the host's managed identity.

.EXAMPLE
    ./New-LetsEncryptRdsCertificate.ps1 -Contact admin@slejco.com
    Production issuance/renewal + Key Vault import + staged App Proxy PFX.
#>
[CmdletBinding()]
param(
    [string]$Fqdn = 'rds.slejco.com',
    [string]$DnsAlias = 'rds.acme.slejco.com',
    [string]$KeyVaultName = 'rdsjslejcokv01',
    [string]$CertName = 'rds-tls',
    [Parameter(Mandatory)][string]$Contact,
    [string]$SubscriptionId,
    [switch]$Staging,
    [switch]$UseServicePrincipal,
    [pscredential]$ServicePrincipalCredential,
    [string]$TenantId,
    [string]$PfxOutDir = (Join-Path ([IO.Path]::GetTempPath()) 'rds-appproxy'),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Assert-Tool {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required tool '$Name' was not found in PATH."
    }
}

function New-RandomPfxPassword {
    # 32 alphanumeric chars; only ever lives in memory and inside the staged PFX.
    $pool = (48..57) + (65..90) + (97..122)
    -join ($pool | Get-Random -Count 32 | ForEach-Object { [char]$_ })
}

Assert-Tool az

# 1. Posh-ACME ------------------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name Posh-ACME)) {
    Write-Host 'Installing Posh-ACME (CurrentUser scope)...' -ForegroundColor DarkGray
    if ((Get-PSRepository -Name PSGallery).InstallationPolicy -ne 'Trusted') {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    }
    Install-Module -Name Posh-ACME -Scope CurrentUser -Force -AllowClobber
}
Import-Module Posh-ACME -ErrorAction Stop

$server = if ($Staging) { 'LE_STAGE' } else { 'LE_PROD' }
Set-PAServer -DirectoryUrl $server
Write-Host "ACME server: $server" -ForegroundColor Cyan

# 2. Subscription for the Azure DNS plugin --------------------------------------
if (-not $SubscriptionId) {
    $SubscriptionId = az account show --query id -o tsv
    if ($LASTEXITCODE -ne 0 -or -not $SubscriptionId) {
        throw 'Could not resolve a subscription. Run az login or pass -SubscriptionId.'
    }
}

# 3. Azure DNS plugin auth ------------------------------------------------------
if ($UseServicePrincipal) {
    if (-not $ServicePrincipalCredential) {
        throw '-UseServicePrincipal requires -ServicePrincipalCredential (AppId as username, secret as password).'
    }
    if (-not $TenantId) { throw '-UseServicePrincipal requires -TenantId.' }
    $pluginArgs = @{
        AZSubscriptionId = $SubscriptionId
        AZTenantId       = $TenantId
        AZAppCred        = $ServicePrincipalCredential
    }
}
else {
    # Managed identity via IMDS (default): run on an Azure VM whose identity has
    # DNS TXT write rights on the alias zone's resource group.
    $pluginArgs = @{
        AZSubscriptionId = $SubscriptionId
        AZUseIMDS        = $true
    }
}

# 4. Issue / renew --------------------------------------------------------------
$pfxPassPlain = New-RandomPfxPassword
$certParams = @{
    Domain     = $Fqdn
    Plugin     = 'Azure'
    PluginArgs = $pluginArgs
    DnsAlias   = $DnsAlias
    AcceptTOS  = $true
    Contact    = $Contact
    PfxPass    = $pfxPassPlain
    Force      = [bool]$Force
}
Write-Host "Requesting certificate for $Fqdn (challenge alias $DnsAlias)..." -ForegroundColor Cyan
$cert = New-PACertificate @certParams
if (-not $cert) { throw 'Posh-ACME did not return a certificate.' }
$newThumb = $cert.Thumbprint
Write-Host "Issued: subject=$($cert.Subject) thumbprint=$newThumb notAfter=$($cert.NotAfter)" -ForegroundColor Green

# 5. Import to Key Vault only when the thumbprint changed (avoid version churn) --
$kvThumb = az keyvault certificate show --vault-name $KeyVaultName --name $CertName --query 'x509ThumbprintHex' -o tsv 2>$null
$kvThumbNorm = if ($kvThumb) { ($kvThumb -replace ':', '').ToUpperInvariant() } else { '' }
if ($Force -or $kvThumbNorm -ne $newThumb.ToUpperInvariant()) {
    Write-Host "Importing into Key Vault '$KeyVaultName' as certificate '$CertName'..." -ForegroundColor Cyan
    az keyvault certificate import --vault-name $KeyVaultName --name $CertName --file $cert.PfxFullChain --password $pfxPassPlain -o none
    if ($LASTEXITCODE -ne 0) {
        throw "Key Vault import failed. Are you on an in-VNet host with data-plane access to $KeyVaultName?"
    }
    Write-Host '[OK] Key Vault updated. DSC binds the new cert on the next farm deploy.' -ForegroundColor Green
}
else {
    Write-Host '[skip] Key Vault already holds this thumbprint; no import needed.' -ForegroundColor DarkGray
}

# 6. Stage the PFX for the App Proxy upload step --------------------------------
New-Item -ItemType Directory -Path $PfxOutDir -Force | Out-Null
$pfxOut = Join-Path $PfxOutDir ("{0}.pfx" -f ($Fqdn -replace '[^a-zA-Z0-9.-]', '_'))
Copy-Item -LiteralPath $cert.PfxFullChain -Destination $pfxOut -Force
Write-Host "[OK] App Proxy PFX staged at $pfxOut" -ForegroundColor Green

# Hand off to Configure-AppProxy.ps1 (PfxPassword is a SecureString).
[pscustomobject]@{
    Fqdn        = $Fqdn
    Thumbprint  = $newThumb
    NotAfter    = $cert.NotAfter
    KeyVaultId  = "https://$KeyVaultName.vault.azure.net/secrets/$CertName"
    PfxPath     = $pfxOut
    PfxPassword = (ConvertTo-SecureString $pfxPassPlain -AsPlainText -Force)
}
