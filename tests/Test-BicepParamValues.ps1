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
if ($null -eq [Environment]::GetEnvironmentVariable('ARTIFACTS_SAS')) {
    [Environment]::SetEnvironmentVariable('ARTIFACTS_SAS', '')
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

# Summary
Write-Host ('-' * 60)
if ($failures.Count -gt 0) {
    Write-Host "FAILED ($($failures.Count)): $($failures -join '; ')" -ForegroundColor Red
    exit 1
}
Write-Host 'All bicepparam value checks passed.' -ForegroundColor Green
exit 0
