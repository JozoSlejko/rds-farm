<#
.SYNOPSIS
    Issue/renew a Let's Encrypt (DV) TLS certificate for the RDS farm via DNS-01,
    import it into Key Vault, and stage a PFX for the Entra application proxy upload.

.DESCRIPTION
    Phase 1 of the Entra application proxy migration (see docs/app-proxy.md). Uses
    Posh-ACME with the Azure DNS plugin and a CNAME challenge alias, so the dynamic
    ACME TXT record is written to an Azure DNS zone you control. Your DNS host only
    ever publishes one static CNAME, so this works with any registrar - including
    ones with a gated or absent DNS API, like GoDaddy on the reference farm.

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
      * Azure DNS public zone for the alias parent (e.g. acme.example.com),
        delegated from your DNS host with an NS record.
      * Static CNAME at your DNS host: _acme-challenge.<fqdn> -> <DnsAlias>.
      * The identity running this (managed identity or service principal) can write
        TXT records in that Azure DNS zone (a custom "DNS TXT Contributor" role is
        enough - least privilege).
      * Run from an IN-VNET host: Key Vault is private-endpoint-only.

.PARAMETER Fqdn
    Public vanity hostname the cert is for, e.g. rds.example.com. Defaults to
    appProxyExternalFqdn read from -BicepParamFile (main.bicepparam).

.PARAMETER AcmeDnsZoneName
    Azure DNS public zone that holds the ACME challenge TXT, delegated from your
    DNS host. Defaults to 'acme.<parent of -Fqdn>' (e.g. acme.example.com).

.PARAMETER DnsAlias
    The Azure DNS record Posh-ACME writes the challenge TXT to. The static CNAME
    _acme-challenge.<Fqdn> at your DNS host must point here. Defaults to
    '<first label of -Fqdn>.<AcmeDnsZoneName>' (e.g. rds.acme.example.com).

.PARAMETER KeyVaultName
    Key Vault that holds the RDS cert. Defaults to keyVaultName read from
    -BicepParamFile (main.bicepparam).

.PARAMETER CertName
    Key Vault certificate name. Default: rds-tls (matches keyVaultCertSecretUri).

.PARAMETER BicepParamFile
    Tier 0-owned main.bicepparam used to hydrate -Fqdn / -KeyVaultName when you
    don't pass them. Default: the repo-root main.bicepparam beside scripts/.

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

.PARAMETER UseAzAccessToken
    Authenticate the Azure DNS plugin with an access token from the current
    `az login` context instead of a managed identity. Use this when issuing from
    a host with no managed identity (e.g. a laptop running Tier 0).

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
    ./New-LetsEncryptRdsCertificate.ps1 -Fqdn rds.slejco.com -Contact admin@slejco.com -Staging
    First run against Let's Encrypt STAGING; derives the acme.slejco.com challenge
    zone and the rds.acme.slejco.com alias, using the host's managed identity.

.EXAMPLE
    ./New-LetsEncryptRdsCertificate.ps1 -Contact admin@slejco.com
    Production run with -Fqdn / -KeyVaultName hydrated from main.bicepparam (after
    the Tier 0 App Proxy flip has set appProxyExternalFqdn).
#>
[CmdletBinding()]
param(
    [string]$Fqdn,
    [string]$AcmeDnsZoneName,
    [string]$DnsAlias,
    [string]$KeyVaultName,
    [string]$CertName = 'rds-tls',
    [Parameter(Mandatory)][string]$Contact,
    [string]$BicepParamFile = (Join-Path $PSScriptRoot '..' 'main.bicepparam'),
    [string]$SubscriptionId,
    [switch]$Staging,
    [switch]$UseServicePrincipal,
    [switch]$UseAzAccessToken,
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

function Get-BicepParamValue {
    # Compile a .bicepparam to ARM JSON and return a hashtable of paramName -> value,
    # via the same 'az bicep build-params' path the repo uses to validate the file.
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Bicep param file not found: $Path"
    }
    # readEnvironmentVariable(...) calls in the param file must resolve to compile.
    foreach ($v in 'DOMAIN_JOIN_PASSWORD', 'LOCAL_ADMIN_PASSWORD') {
        if (-not [Environment]::GetEnvironmentVariable($v)) {
            [Environment]::SetEnvironmentVariable($v, 'placeholder-for-read-only', 'Process')
        }
    }
    $tmp = New-TemporaryFile
    try {
        & az bicep build-params --file $Path --outfile $tmp.FullName 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Could not compile '$Path' with 'az bicep build-params' to read its values."
        }
        $parsed = Get-Content -LiteralPath $tmp.FullName -Raw | ConvertFrom-Json
        $values = @{}
        if (($parsed.PSObject.Properties.Name -contains 'parameters') -and $parsed.parameters) {
            foreach ($p in $parsed.parameters.PSObject.Properties) {
                if ($p.Value -and ($p.Value.PSObject.Properties.Name -contains 'value')) {
                    $values[$p.Name] = $p.Value.value
                }
            }
        }
        return $values
    }
    finally {
        Remove-Item -LiteralPath $tmp.FullName -Force -ErrorAction SilentlyContinue
    }
}

Assert-Tool az

# Resolve environment-specific values: anything you pass wins; otherwise hydrate
# -Fqdn / -KeyVaultName from the Tier 0-owned bicepparam so this script carries no
# single farm's values. Then derive the ACME challenge zone + alias from the FQDN.
if ((-not $Fqdn -or -not $KeyVaultName) -and (Test-Path -LiteralPath $BicepParamFile)) {
    Write-Host "Reading defaults from $BicepParamFile..." -ForegroundColor DarkGray
    $bicep = Get-BicepParamValue -Path $BicepParamFile
    if (-not $Fqdn -and $bicep.ContainsKey('appProxyExternalFqdn')) { $Fqdn = $bicep['appProxyExternalFqdn'] }
    if (-not $KeyVaultName -and $bicep.ContainsKey('keyVaultName')) { $KeyVaultName = $bicep['keyVaultName'] }
}
if (-not $Fqdn) {
    throw "No -Fqdn given and 'appProxyExternalFqdn' is empty in $BicepParamFile. Pass -Fqdn rds.example.com, or run Tier 0 with -UseAppProxy -AppProxyExternalFqdn <fqdn> first."
}
if (-not $KeyVaultName) {
    throw "No -KeyVaultName given and 'keyVaultName' is empty in $BicepParamFile. Pass -KeyVaultName <vault>."
}

$fqdnParts = $Fqdn -split '\.', 2
$fqdnLabel = $fqdnParts[0]
$fqdnParent = if ($fqdnParts.Count -gt 1) { $fqdnParts[1] } else { '' }
if (-not $fqdnParent) {
    throw "Fqdn '$Fqdn' must be a full hostname like rds.example.com."
}
if (-not $AcmeDnsZoneName) { $AcmeDnsZoneName = "acme.$fqdnParent" }
if (-not $DnsAlias) { $DnsAlias = "$fqdnLabel.$AcmeDnsZoneName" }

Write-Host "FQDN                 : $Fqdn"
Write-Host "Key Vault            : $KeyVaultName"
Write-Host "ACME challenge zone  : $AcmeDnsZoneName  (Azure DNS public zone, delegated from your DNS host)"
Write-Host "ACME challenge alias : $DnsAlias"
Write-Host 'One-time static record your DNS host must publish (never changes):' -ForegroundColor Yellow
Write-Host "  _acme-challenge.$Fqdn   CNAME   $DnsAlias" -ForegroundColor Yellow

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
elseif ($UseAzAccessToken) {
    # Use the current 'az login' context (no IMDS): fetch an ARM access token and
    # hand it to the posh-acme Azure plugin. Lets Tier 0 issue from a laptop that
    # has no managed identity. The signed-in account needs DNS TXT write rights
    # on the challenge zone's resource group.
    $azToken = az account get-access-token --query accessToken -o tsv
    if ($LASTEXITCODE -ne 0 -or -not $azToken) {
        throw 'Could not get an Azure access token from az. Run az login first.'
    }
    $pluginArgs = @{
        AZSubscriptionId = $SubscriptionId
        AZAccessToken    = $azToken
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
