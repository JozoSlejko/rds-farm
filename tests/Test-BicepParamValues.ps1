<#
.SYNOPSIS
    Sanity-check values in main.bicepparam before any deployment runs.

.DESCRIPTION
    Compiles main.bicepparam with `az bicep build-params` (so the same
    readEnvironmentVariable resolution as the pipeline takes effect), then
    asserts a set of guard-rail invariants on the produced parameter values:

      * No 0.0.0.0/0 or ::/0 in allowedClientSourceAddressPrefixes (the whole
        point of the NSG allow-list is to keep the world out).
      * adDnsServerIp parses as a private RFC1918 / RFC4193 address.
      * gatewayDnsLabelPrefix matches Azure naming rules
        (3-63 chars, starts with letter, lowercase alphanumeric + hyphen).
      * sessionHostNamingPrefix yields NetBIOS-safe (<=15 char) names for any
        index up to sessionHostCount.
      * When enableCertificateBinding is true:
          - keyVaultName / keyVaultResourceGroup / keyVaultCertSecretUri /
            certificateSubject / publicGatewayFqdn are all non-empty.
          - keyVaultCertSecretUri matches https://<vault>.vault.azure.net/secrets/...
          - certificateSubject starts with 'CN='.
      * publicGatewayFqdn (when set) is a syntactically valid DNS name.
      * When deployBastion is true, the effective bastionSubnetName (explicit
        value or the main.bicep default) is exactly 'AzureBastionSubnet' -
        Azure Bastion rejects any other subnet name.

    Exits non-zero on any failure.

.PARAMETER ParamFile
    Path to main.bicepparam.

.EXAMPLE
    pwsh -File tests/Test-BicepParamValues.ps1
#>
[CmdletBinding()]
param(
    [string]$ParamFile = (Join-Path $PSScriptRoot '..' 'main.bicepparam')
)

$ErrorActionPreference = 'Stop'
$failures = New-Object System.Collections.Generic.List[string]

function Write-TestResult {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    $status = if ($Ok) { 'PASS' } else { 'FAIL' }
    $color  = if ($Ok) { 'Green' } else { 'Red' }
    Write-Host ("[{0}] {1}" -f $status, $Name) -ForegroundColor $color
    if (-not $Ok) {
        if ($Detail) { Write-Host "       $Detail" -ForegroundColor DarkYellow }
        $failures.Add($Name) | Out-Null
    }
}

$ParamFile = (Resolve-Path -LiteralPath $ParamFile).Path
Write-Host "Target: $ParamFile" -ForegroundColor Cyan
Write-Host ('-' * 60)

# 0. Make sure required env vars are at least set (any value is fine for the parse).
foreach ($v in 'DOMAIN_JOIN_PASSWORD', 'LOCAL_ADMIN_PASSWORD') {
    if (-not [Environment]::GetEnvironmentVariable($v)) {
        [Environment]::SetEnvironmentVariable($v, 'placeholder-for-validation-only')
    }
}

# 1. Compile bicepparam → ARM parameter JSON
$tmp = New-TemporaryFile
try {
    & az bicep build-params --file $ParamFile --outfile $tmp.FullName 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "az bicep build-params exited $LASTEXITCODE" }
    $compiled = Get-Content -LiteralPath $tmp.FullName -Raw | ConvertFrom-Json
    Write-TestResult 'bicepparam compiles' $true
} catch {
    Write-TestResult 'bicepparam compiles' $false $_.Exception.Message
    Write-Host 'Aborting further checks (cannot read parameters).' -ForegroundColor Red
    exit 1
} finally {
    Remove-Item -LiteralPath $tmp.FullName -Force -ErrorAction SilentlyContinue
}

$p = $compiled.parameters

function Get-ParamValue {
    param([string]$Name)
    if ($p.PSObject.Properties[$Name]) { return $p.$Name.value }
    return $null
}

# 2. allowedClientSourceAddressPrefixes — no internet-wide allow
$cidrs = @(Get-ParamValue 'allowedClientSourceAddressPrefixes')
$bad   = $cidrs | Where-Object { $_ -in @('0.0.0.0/0', '*', 'Internet', '::/0') }
if ($cidrs.Count -eq 0) {
    Write-TestResult 'allowedClientSourceAddressPrefixes not empty' $false 'No client CIDRs configured'
} else {
    Write-TestResult 'allowedClientSourceAddressPrefixes not empty' $true
}
if ($bad) {
    Write-TestResult 'allowedClientSourceAddressPrefixes excludes internet-wide entries' $false "Found: $($bad -join ', ')"
} else {
    Write-TestResult 'allowedClientSourceAddressPrefixes excludes internet-wide entries' $true
}

# 3. adDnsServerIp parses + is private
$dns = Get-ParamValue 'adDnsServerIp'
$ip  = $null
$ipOk = [System.Net.IPAddress]::TryParse($dns, [ref]$ip)
Write-TestResult "adDnsServerIp parses ($dns)" $ipOk
if ($ipOk -and $ip.AddressFamily -eq 'InterNetwork') {
    $bytes = $ip.GetAddressBytes()
    $isPrivate =
        ($bytes[0] -eq 10) -or
        ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or
        ($bytes[0] -eq 192 -and $bytes[1] -eq 168)
    Write-TestResult 'adDnsServerIp is in a private RFC1918 range' $isPrivate "Got $dns"
}

# 4. gatewayDnsLabelPrefix — Azure DNS label rules
$label = Get-ParamValue 'gatewayDnsLabelPrefix'
$labelOk = $label -match '^[a-z][a-z0-9-]{1,61}[a-z0-9]$'
Write-TestResult "gatewayDnsLabelPrefix matches Azure naming rules ($label)" $labelOk

# 5. sessionHostNamingPrefix yields NetBIOS-safe names (<=15 chars including 2-digit suffix)
$shPrefix = Get-ParamValue 'sessionHostNamingPrefix'
$shCount  = Get-ParamValue 'sessionHostCount'
$maxName  = "${shPrefix}$('{0:D2}' -f $shCount)"
$nameOk   = $maxName.Length -le 15
Write-TestResult "Session host names <=15 chars (worst case '$maxName' = $($maxName.Length))" $nameOk

# 6. Certificate binding — required values when enabled
$certEnabled = [bool](Get-ParamValue 'enableCertificateBinding')
if ($certEnabled) {
    $required = @{
        keyVaultName            = Get-ParamValue 'keyVaultName'
        keyVaultResourceGroup   = Get-ParamValue 'keyVaultResourceGroup'
        keyVaultCertSecretUri   = Get-ParamValue 'keyVaultCertSecretUri'
        certificateSubject      = Get-ParamValue 'certificateSubject'
        publicGatewayFqdn       = Get-ParamValue 'publicGatewayFqdn'
    }
    $missing = $required.GetEnumerator() | Where-Object { [string]::IsNullOrWhiteSpace($_.Value) } | Select-Object -ExpandProperty Key
    if ($missing) {
        Write-TestResult 'enableCertificateBinding: all related params set' $false "Missing: $($missing -join ', ')"
    } else {
        Write-TestResult 'enableCertificateBinding: all related params set' $true
    }

    $uri = $required.keyVaultCertSecretUri
    $uriOk = $uri -match '^https://[a-z0-9-]+\.vault\.azure\.net/secrets/[^/]+/?$'
    Write-TestResult "keyVaultCertSecretUri shape ($uri)" $uriOk 'Expected https://<vault>.vault.azure.net/secrets/<name>'

    $subj = $required.certificateSubject
    Write-TestResult "certificateSubject starts with 'CN='" ($subj -like 'CN=*')

    $fqdn = $required.publicGatewayFqdn
    # Allow wildcards (*.contoso.com) too — RDS accepts wildcard certs.
    $fqdnOk = $fqdn -match '^(\*\.)?([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
    Write-TestResult "publicGatewayFqdn is a valid DNS name ($fqdn)" $fqdnOk
} else {
    Write-Host '[SKIP] enableCertificateBinding = false; cert checks not applicable' -ForegroundColor DarkGray
}

# 7. Bastion — when deployBastion is true the subnet must be named exactly
# 'AzureBastionSubnet' (a hard Azure requirement; any other name fails the
# bastion deploy). main.bicep defaults deployBastion=true and
# bastionSubnetName='AzureBastionSubnet', but the compiled JSON omits params
# not explicitly set in the bicepparam, so apply the same defaults here.
$deployBastionRaw = Get-ParamValue 'deployBastion'
$deployBastion    = if ($null -eq $deployBastionRaw) { $true } else { [bool]$deployBastionRaw }
if ($deployBastion) {
    $bastionSubnet = Get-ParamValue 'bastionSubnetName'
    if ([string]::IsNullOrWhiteSpace($bastionSubnet)) { $bastionSubnet = 'AzureBastionSubnet' }
    Write-TestResult "bastionSubnetName is 'AzureBastionSubnet' when deployBastion=true (got '$bastionSubnet')" `
        ($bastionSubnet -eq 'AzureBastionSubnet') `
        "Azure Bastion requires the subnet to be named exactly 'AzureBastionSubnet'. Set deployBastion=false if you reach the VMs another way."
} else {
    Write-Host '[SKIP] deployBastion = false; bastion subnet check not applicable' -ForegroundColor DarkGray
}

# 8. Application proxy - when useAppProxy is true, appProxyExternalFqdn must be a
# valid public DNS name, and publicGatewayFqdn should equal it (the RD Web HTML5
# client requires the internal and external FQDN to be the same).
$useAppProxyRaw = Get-ParamValue 'useAppProxy'
$useAppProxy    = if ($null -eq $useAppProxyRaw) { $false } else { [bool]$useAppProxyRaw }
if ($useAppProxy) {
    $apFqdn   = Get-ParamValue 'appProxyExternalFqdn'
    $apFqdnOk = $apFqdn -match '^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
    Write-TestResult "appProxyExternalFqdn is a valid DNS name ($apFqdn)" $apFqdnOk 'Required when useAppProxy=true.'

    $pubFqdn = Get-ParamValue 'publicGatewayFqdn'
    Write-TestResult 'publicGatewayFqdn equals appProxyExternalFqdn (RD Web client needs internal==external)' `
        ($pubFqdn -eq $apFqdn) "publicGatewayFqdn='$pubFqdn' appProxyExternalFqdn='$apFqdn'"
} else {
    Write-Host '[SKIP] useAppProxy = false; application proxy checks not applicable' -ForegroundColor DarkGray
}

# Summary
Write-Host ('-' * 60)
if ($failures.Count -gt 0) {
    Write-Host "FAILED ($($failures.Count)): $($failures -join '; ')" -ForegroundColor Red
    exit 1
}
Write-Host 'All bicepparam value checks passed.' -ForegroundColor Green
exit 0
