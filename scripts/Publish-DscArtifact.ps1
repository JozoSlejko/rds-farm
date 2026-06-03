<#
.SYNOPSIS
    Package dsc/Configuration.ps1 + dsc/Bootstrap.ps1 and upload them to the
    artifacts storage account.

.DESCRIPTION
    Mirrors the `package-dsc` + `upload-artifacts` jobs in
    .github/workflows/deploy.yml for users running deployments by hand.
    Idempotent: re-running just overwrites the blobs.

    Steps (all idempotent):
      1. Compress dsc/Configuration.ps1 into Configuration.zip.
      2. Upload Configuration.zip to <StorageAccount>/<Container>/<BlobName>
         using --auth-mode login (your Entra identity, no account keys).
      3. Upload dsc/Bootstrap.ps1 to the same container (always as
         Bootstrap.ps1) — CSE downloads both blobs side-by-side.
      4. Print the artifacts base URL.

    No SAS is generated. The Custom Script Extension authenticates to blob
    storage with the VM's user-assigned managed identity (Storage Blob Data
    Reader role on the SA, granted by modules/sa-role.bicep). The tenant
    policy on the SA blocks both shared-key and SAS access; managed identity
    is the only viable download path. (The legacy Microsoft.Powershell/DSC
    extension was retired here because it silently ignores managedIdentity
    in protectedSettings and falls back to anonymous downloads.)

    The output object has these properties:
      ArtifactsLocation   # e.g. https://contosordsart01.blob.core.windows.net/dsc/
      BlobUrl             # full URL to Configuration.zip
      BootstrapBlobUrl    # full URL to Bootstrap.ps1

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

.PARAMETER BootstrapPath
    Path to the CSE bootstrap script. Default: <repo>/dsc/Bootstrap.ps1. The
    blob is always uploaded with the name 'Bootstrap.ps1' because the URL is
    baked into the CustomScriptExtension fileUris in modules/dsc.bicep.

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
    [string]$BootstrapPath     = (Join-Path $PSScriptRoot '..' 'dsc' 'Bootstrap.ps1'),
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
$BootstrapPath = (Resolve-Path -LiteralPath $BootstrapPath).Path
if (-not (Test-Path -LiteralPath $BootstrapPath -PathType Leaf)) {
    throw "Bootstrap script not found: $BootstrapPath"
}
Write-Host "    Config    : $ConfigurationPath"
Write-Host "    Bootstrap : $BootstrapPath"

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

# Pre-flight DNS check. The SA runs with publicNetworkAccess=Disabled
# (subscription policy enforces it), so the upload only succeeds from a
# host that resolves the SA FQDN to its Private Endpoint IP (typically
# anything inside the spoke / hub VNet, or a peered network). A laptop on
# the public internet will resolve to a public IP and get HTTP 403
# 'PublicAccessNotPermitted'. Catch this BEFORE the upload so we can give a
# clear message instead of a generic RBAC complaint.
$saHost = "$StorageAccount.blob.core.windows.net"
try {
    $resolved = Resolve-DnsName -Name $saHost -Type A -ErrorAction Stop
} catch {
    Write-Warning "DNS lookup for $saHost failed: $($_.Exception.Message). Continuing anyway — az may still succeed."
    $resolved = $null
}
# Pull every IPv4 the chain resolves to (CNAMEs + A records). Use a generic
# Test-PrivateIp because the actual PE subnet ranges aren't known to this
# script (the prereqs deploy chooses them).
function Test-PrivateIp {
    param([string]$Ip)
    if (-not $Ip) { return $false }
    # RFC 1918 (10/8, 172.16/12, 192.168/16) + CGNAT (100.64/10, used by
    # some Azure landing-zone designs).
    return $Ip -match '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)'
}
$ipv4s = @()
if ($resolved) {
    # Only the Answer section — the Authority/Additional sections sometimes
    # carry root-nameserver glue records when the OS resolver went recursive,
    # and we don't want those false positives in the warning. Also require an
    # actual IPv4 (A record, not AAAA / NS / SOA).
    foreach ($r in $resolved) {
        $hasSection = $r.PSObject.Properties.Name -contains 'Section'
        $hasIp      = $r.PSObject.Properties.Name -contains 'IP4Address'
        if ($hasSection -and $r.Section -eq 'Answer' -and $hasIp -and $r.IP4Address) {
            $ipv4s += $r.IP4Address
        }
    }
}
$privateHits = @($ipv4s | Where-Object { Test-PrivateIp $_ })
if ($ipv4s -and -not $privateHits) {
    Write-Warning "$saHost resolves to PUBLIC IP(s) [$($ipv4s -join ', ')]. The SA almost certainly has publicNetworkAccess=Disabled, so this upload will return HTTP 403. Run this script from inside the VNet (a hub jump box / DC, a spoke VM, or via Bastion to one) instead of your laptop."
} elseif ($privateHits) {
    Write-Host "    DNS : $saHost -> $($privateHits -join ', ') (private — PE path)"
}

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

# Small helper so both upload calls share the same stderr capture + error
# classification. az's exit code is the only signal you get with --output
# none, and a 403 (PNA blocking the data plane) looks identical to a 403
# (missing RBAC) at exit-code level — only the stderr text disambiguates.
function Invoke-AzBlobUpload {
    param(
        [Parameter(Mandatory)] [string]$BlobLabel,
        [Parameter(Mandatory)] [string]$LocalFile,
        [Parameter(Mandatory)] [string]$DestBlobName
    )
    # Capture stderr by redirecting it to stdout, then split out on exit.
    $stderrLines = @()
    & az storage blob upload `
        --account-name   $StorageAccount `
        --container-name $Container `
        --name           $DestBlobName `
        --file           $LocalFile `
        --overwrite `
        --auth-mode      login 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) {
                $stderrLines += $_.ToString()
            }
            # swallow stdout (would have been suppressed by | Out-Null before)
        }
    if ($LASTEXITCODE -eq 0) {
        Write-Host "    Uploaded $BlobLabel."
        return
    }

    $stderr = ($stderrLines -join "`n")
    # Network-level (PE not reachable from this host, DNS pointing at public IP
    # that PNA blocks). az surfaces 403 / PublicAccessNotPermitted /
    # 'public network access is disabled' / sometimes 'AuthorizationFailure'
    # / generic ConnectionError for TLS or routing failures to the PE IP.
    $networkPatterns = @(
        'PublicAccessNotPermitted'
        'Public access is not permitted'
        'public network access is disabled'
        # The CLI's own re-wording when an upload hits the SA's network ACL
        # (which, with PNA=Disabled and no firewall rules, blocks everything
        # off the PE):
        'blocked by network rules of storage account'
        'ConnectionError'
        'Failed to establish a new connection'
        'getaddrinfo failed'
        'No connection could be made'
        'A connection attempt failed'
    )
    foreach ($pattern in $networkPatterns) {
        if ($stderr -match $pattern) {
            throw @"
$BlobLabel upload to $StorageAccount/$Container failed because this host cannot reach the storage account's data plane.

The SA runs with publicNetworkAccess=Disabled, so it is reachable ONLY through its Private Endpoint. Symptoms suggest this host (probably your laptop) is resolving the SA FQDN to its PUBLIC IP and hitting the firewall.

Fix: run this script from a host inside the spoke / hub VNet (or peered to it). The DC at the hub is the usual choice — RDP via Bastion, install az CLI, clone the repo, re-run.

Verify on the target host:
  Resolve-DnsName $StorageAccount.blob.core.windows.net   # should return 172.16.x.x (or your PE subnet)

Underlying az error:
$stderr
"@
        }
    }

    # RBAC / auth issues.
    $authPatterns = @(
        'AuthorizationPermissionMismatch'
        'AuthorizationFailure'
        'not authorized to perform this operation'
        'does not have authorization to perform action'
    )
    foreach ($pattern in $authPatterns) {
        if ($stderr -match $pattern) {
            throw "$BlobLabel upload failed: the signed-in identity is missing 'Storage Blob Data Contributor' on $StorageAccount. Grant it (or have your CI principal grant it) and retry.`n`nUnderlying az error:`n$stderr"
        }
    }

    # Anything else — surface the raw stderr so the user can act on it.
    throw "$BlobLabel upload failed (az exit $LASTEXITCODE).`n`n$stderr"
}

Invoke-AzBlobUpload -BlobLabel $BlobName       -LocalFile $zipPath      -DestBlobName $BlobName

# Bootstrap.ps1 is downloaded by CSE alongside Configuration.zip into the same
# Downloads\<seq> directory. The blob name must stay as 'Bootstrap.ps1' to
# match the fileUris baked into modules/dsc.bicep.
Invoke-AzBlobUpload -BlobLabel 'Bootstrap.ps1' -LocalFile $BootstrapPath -DestBlobName 'Bootstrap.ps1'

$artifactsLocation = "https://$StorageAccount.blob.core.windows.net/$Container/"
$blobUrl           = "$artifactsLocation$BlobName"
$bootstrapBlobUrl  = "${artifactsLocation}Bootstrap.ps1"

# ---------------------------------------------------------------------------
# 3. Result
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "==================== Done ====================" -ForegroundColor Green
Write-Host "ArtifactsLocation : $artifactsLocation"
Write-Host "BlobUrl           : $blobUrl"
Write-Host "BootstrapBlobUrl  : $bootstrapBlobUrl"
Write-Host "Auth              : VM managed identity (Storage Blob Data Reader)"

if ($SetEnvVars) {
    $env:ARTIFACTS_LOCATION = $artifactsLocation
    Write-Host ""
    Write-Host "    Set `$env:ARTIFACTS_LOCATION in this session." -ForegroundColor Cyan
}

[pscustomobject]@{
    ArtifactsLocation = $artifactsLocation
    BlobUrl           = $blobUrl
    BootstrapBlobUrl  = $bootstrapBlobUrl
}
