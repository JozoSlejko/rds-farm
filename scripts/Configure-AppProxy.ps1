<#
.SYNOPSIS
    Publish the RDS farm (RD Web + RD Gateway) through Microsoft Entra application
    proxy via Microsoft Graph: create/configure the app with Entra pre-auth, upload
    the custom-domain cert, assign a connector group, and assign the access group.

.DESCRIPTION
    Phase 1 of docs/app-proxy.md. Drives Microsoft Graph with `az rest` (the app
    proxy operations live on the BETA endpoint). Sign in with `az login` as a
    Cloud Application Administrator (or higher) first.

    Mirrors learn.microsoft.com/graph/application-proxy-configure-api:
      1. Instantiate the custom application template (8adf8e6e-...) -> app + SP.
      2. Set identifierUris + web redirect/home URLs.
      3. Configure onPremisesPublishing for RDS: Entra pre-auth, internal == external
         URL (rds.slejco.com), HTTP-only cookie OFF, header/body translation OFF,
         plus the custom-domain cert from New-LetsEncryptRdsCertificate.ps1.
      4. Create/find the connector group and assign the app to it.
      5. Assign the RDS access group to the app.

    Pipe the output object of New-LetsEncryptRdsCertificate.ps1 in for -PfxPath and
    -PfxPassword. App Proxy can't pull the cert from Key Vault, so it is uploaded
    directly to the app registration here.

    After this script:
      * Create the GoDaddy CNAME  rds.slejco.com -> <app>.msappproxy.net
        (the target is shown in the Entra portal -> the app -> Application Proxy).
      * Point RDS at the proxy (Set-RDDeploymentGatewayConfiguration + the per-
        collection pre-auth CustomRdpProperty - handled by the DSC change).
      * Remove the public load balancer (Phase 2).

.PARAMETER DisplayName
    Enterprise application display name. Default: 'RDS Farm (Entra App Proxy)'.

.PARAMETER Fqdn
    Vanity hostname; becomes both the internal and external URL host. Default: rds.slejco.com.

.PARAMETER PfxPath
    Path to the full-chain PFX for the custom domain (from the cert script).

.PARAMETER PfxPassword
    PFX password as a SecureString (the cert script returns this).

.PARAMETER ConnectorGroupName
    Connector group to create/find and assign the app to. Default: 'RDS Connectors'.

.PARAMETER AssignGroupObjectId
    Object id of the Entra group whose members may reach RD Web. Takes precedence
    over -AssignGroupName.

.PARAMETER AssignGroupName
    Display name of the access group (resolved to an object id via `az ad group show`).

.PARAMETER ConnectorId
    Optional connector id to move into the connector group. If omitted, the script
    lists available connectors and you assign one in the portal.

.PARAMETER ExistingApplicationObjectId
    Re-configure an existing app instead of instantiating a new one (re-runnable).

.EXAMPLE
    $cert = ./New-LetsEncryptRdsCertificate.ps1 -Contact admin@slejco.com
    ./Configure-AppProxy.ps1 -PfxPath $cert.PfxPath -PfxPassword $cert.PfxPassword -AssignGroupName 'RDS-Users'
#>
[CmdletBinding()]
param(
    [string]$DisplayName = 'RDS Farm (Entra App Proxy)',
    [string]$Fqdn = 'rds.slejco.com',
    [Parameter(Mandatory)][string]$PfxPath,
    [Parameter(Mandatory)][securestring]$PfxPassword,
    [string]$ConnectorGroupName = 'RDS Connectors',
    [string]$AssignGroupObjectId,
    [string]$AssignGroupName,
    [string]$ConnectorId,
    [string]$ExistingApplicationObjectId
)

$ErrorActionPreference = 'Stop'
$customAppTemplateId = '8adf8e6e-67b2-4cf2-a259-e3dc5476c621'
$defaultUserAppRoleId = '18d14569-c3bd-439b-9a66-3a2aee01d14f'  # well-known default access role
$graph = 'https://graph.microsoft.com'

function Assert-Tool {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required tool '$Name' was not found in PATH."
    }
}

function Invoke-Graph {
    # Thin wrapper over `az rest` for Microsoft Graph. Returns parsed JSON (or $null
    # for 204). Bodies are written to a temp file to avoid cross-shell quoting issues.
    param(
        [Parameter(Mandatory)][ValidateSet('get', 'post', 'patch', 'put', 'delete')][string]$Method,
        [Parameter(Mandatory)][string]$Url,
        [object]$Body
    )
    $azArgs = @('rest', '--method', $Method, '--url', $Url, '--headers', 'Content-Type=application/json')
    $tmp = $null
    if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) {
        $tmp = (New-TemporaryFile).FullName
        ($Body | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $tmp -Encoding utf8
        $azArgs += @('--body', "@$tmp")
    }
    try {
        $out = az @azArgs 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Graph $Method $Url failed:`n$out" }
        if ($out) { return ($out | Out-String | ConvertFrom-Json -ErrorAction SilentlyContinue) }
        return $null
    }
    finally {
        if ($tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

Assert-Tool az
az account show -o none
if ($LASTEXITCODE -ne 0) { throw 'Not signed in. Run az login as a Cloud Application Administrator.' }
if (-not (Test-Path -LiteralPath $PfxPath)) { throw "PFX not found at '$PfxPath'." }

# Resolve the access group object id ------------------------------------------
if (-not $AssignGroupObjectId -and $AssignGroupName) {
    $AssignGroupObjectId = az ad group show --group $AssignGroupName --query id -o tsv
    if ($LASTEXITCODE -ne 0 -or -not $AssignGroupObjectId) { throw "Could not resolve group '$AssignGroupName'." }
}

# 1. Create or reuse the application ------------------------------------------
if ($ExistingApplicationObjectId) {
    $appObjId = $ExistingApplicationObjectId
    $app = Invoke-Graph get "$graph/v1.0/applications/$appObjId"
    $appId = $app.appId
    $sp = Invoke-Graph get "$graph/v1.0/servicePrincipals(appId='$appId')"
    $spObjId = $sp.id
    Write-Host "Reusing application $appObjId (appId $appId)" -ForegroundColor Cyan
}
else {
    Write-Host "Instantiating custom application '$DisplayName'..." -ForegroundColor Cyan
    $inst = Invoke-Graph post "$graph/v1.0/applicationTemplates/$customAppTemplateId/instantiate" @{ displayName = $DisplayName }
    $appObjId = $inst.application.id
    $appId = $inst.application.appId
    $spObjId = $inst.servicePrincipal.id
    Write-Host "Created app $appObjId (appId $appId), SP $spObjId" -ForegroundColor Green

    # Instantiation propagates asynchronously - wait until the app is gettable.
    $ready = $false
    foreach ($i in 1..12) {
        Start-Sleep -Seconds 5
        try {
            if (Invoke-Graph get "$graph/v1.0/applications/$appObjId") { $ready = $true; break }
        }
        catch {
            Write-Host "  waiting for app propagation ($i/12)..." -ForegroundColor DarkGray
        }
    }
    if (-not $ready) { throw 'Timed out waiting for the new application to propagate.' }
}

# 2. Identifier + web URIs ----------------------------------------------------
Write-Host 'Setting identifierUris + web URLs...' -ForegroundColor Cyan
Invoke-Graph patch "$graph/v1.0/applications/$appObjId" @{
    identifierUris = @("api://$appId")
    web            = @{
        redirectUris = @("https://$Fqdn/")
        homePageUrl  = "https://$Fqdn/RDWeb"
    }
} | Out-Null

# 3. onPremisesPublishing (RDS) + custom-domain cert --------------------------
$pfxB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($PfxPath))
$pfxPwPlain = [Net.NetworkCredential]::new('', $PfxPassword).Password
Write-Host 'Configuring onPremisesPublishing (Entra pre-auth, RDS settings) + cert...' -ForegroundColor Cyan
Invoke-Graph patch "$graph/beta/applications/$appObjId" @{
    onPremisesPublishing = @{
        externalAuthenticationType             = 'aadPreAuthentication'
        internalUrl                            = "https://$Fqdn/"
        externalUrl                            = "https://$Fqdn/"
        isOnPremPublishingEnabled              = $true
        isHttpOnlyCookieEnabled                = $false   # RDS requires this OFF
        isTranslateHostHeaderEnabled           = $false   # RDS: do not translate
        isTranslateLinksInBodyEnabled          = $false   # RDS: do not translate
        isSecureCookieEnabled                  = $true
        isStateSessionEnabled                  = $true
        isPersistentCookieEnabled              = $false
        verifiedCustomDomainKeyCredential      = @{ type = 'X509CertAndPassword'; usage = 'Verify'; key = $pfxB64 }
        verifiedCustomDomainPasswordCredential = @{ secretText = $pfxPwPlain }
    }
} | Out-Null
Write-Host '[OK] Application proxy configured with the custom domain cert.' -ForegroundColor Green

# 4. Connector group ----------------------------------------------------------
$groups = Invoke-Graph get "$graph/beta/onPremisesPublishingProfiles/applicationProxy/connectorGroups"
$group = $groups.value | Where-Object { $_.name -eq $ConnectorGroupName } | Select-Object -First 1
if (-not $group) {
    Write-Host "Creating connector group '$ConnectorGroupName'..." -ForegroundColor Cyan
    $group = Invoke-Graph post "$graph/beta/onPremisesPublishingProfiles/applicationProxy/connectorGroups" @{ name = $ConnectorGroupName }
}
Invoke-Graph put "$graph/beta/applications/$appObjId/connectorGroup/`$ref" @{
    '@odata.id' = "$graph/beta/onPremisesPublishingProfiles/applicationProxy/connectorGroups/$($group.id)"
} | Out-Null
Write-Host "[OK] App assigned to connector group '$ConnectorGroupName' ($($group.id))." -ForegroundColor Green

if ($ConnectorId) {
    Invoke-Graph put "$graph/beta/onPremisesPublishingProfiles/applicationProxy/connectors/$ConnectorId/memberOf/`$ref" @{
        '@odata.id' = "$graph/beta/onPremisesPublishingProfiles/applicationProxy/connectorGroups/$($group.id)"
    } | Out-Null
    Write-Host "[OK] Connector $ConnectorId moved into the group." -ForegroundColor Green
}
else {
    $connectors = Invoke-Graph get "$graph/beta/onPremisesPublishingProfiles/applicationProxy/connectors"
    Write-Host 'Connectors found (assign at least one to this group, in the portal or via -ConnectorId):' -ForegroundColor Yellow
    $connectors.value | ForEach-Object { Write-Host "  $($_.id)  $($_.machineName)  $($_.status)" -ForegroundColor Yellow }
}

# 5. Assign the access group --------------------------------------------------
if ($AssignGroupObjectId) {
    Write-Host "Assigning group $AssignGroupObjectId to the app..." -ForegroundColor Cyan
    Invoke-Graph post "$graph/beta/servicePrincipals/$spObjId/appRoleAssignments" @{
        principalId   = $AssignGroupObjectId
        principalType = 'Group'
        appRoleId     = $defaultUserAppRoleId
        resourceId    = $spObjId
    } | Out-Null
    Write-Host '[OK] Access group assigned.' -ForegroundColor Green
}
else {
    Write-Host 'No -AssignGroupObjectId/-AssignGroupName given; assign the RDS access group manually.' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '================ NEXT STEPS ================' -ForegroundColor Cyan
Write-Host "1. GoDaddy: CNAME $Fqdn -> <app>.msappproxy.net (target is in the portal: the app -> Application Proxy)."
Write-Host "2. Internal split-horizon DNS: A record $Fqdn -> RD Gateway private IP."
Write-Host '3. Apply the DSC change (GatewayExternalFqdn + pre-auth CustomRdpProperty) and redeploy.'
Write-Host '4. Verify, then remove the public load balancer (Phase 2).'

[pscustomobject]@{
    ApplicationObjectId = $appObjId
    AppId               = $appId
    ServicePrincipalId  = $spObjId
    ExternalUrl         = "https://$Fqdn/"
    ConnectorGroupId    = $group.id
}
