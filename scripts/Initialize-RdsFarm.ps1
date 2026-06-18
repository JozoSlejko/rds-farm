<#
.SYNOPSIS
    Single-command Tier-0 bootstrap for the RDS farm.

.DESCRIPTION
    Replaces the four-step Tier-0 ritual (cert + bicepparam edits + prereq
    Bicep + CI bootstrap) with one orchestrator. After this script succeeds,
    you push to `main` and the GitHub Actions pipeline takes over.

    What it does, in order:
      1. Pre-flight (az + gh signed-in, subscription set, az bicep present).
      2. Asks for any required input you didn't pass as a parameter
         (passwords are read with Read-Host -AsSecureString and stored only
         as GitHub repo secrets — never written to disk).
      3. Runs scripts/Initialize-CiPrerequisites.ps1 to create the Entra
         app + federated credentials + RBAC + GitHub secrets/environments.
      4. Deploys prereqs/tier0.bicep to provision the artifacts storage
         account and the Key Vault, with adminPrincipals = [you, the CI SP].
      5. Issues / imports the TLS cert into the new Key Vault and patches the
         cert-related params in main.bicepparam. For -CertMode Csr/ImportPfx/
         SelfSigned this runs scripts/New-RdsCertificate.ps1; for -CertMode
         LetsEncrypt it creates the Azure DNS challenge zone, prints the records
         to add at your registrar, issues a Let's Encrypt DV cert via DNS-01
         (scripts/New-LetsEncryptRdsCertificate.ps1), and publishes the Entra
         application proxy app (scripts/Configure-AppProxy.ps1).
      6. Patches the remaining values in main.bicepparam (VNet, AD, gateway
         FQDN, allowed CIDRs, artifactsLocation, ...).
      7. Sets the ARTIFACTS_STORAGE_ACCOUNT repo variable to the SA the
         prereqs deployment just produced.
      8. Validates main.bicepparam compiles with az bicep build-params.
      9. Prints next steps (Invoke-ManualDeploy.ps1 to deploy the farm from a
         laptop/jumpbox with VNet line-of-sight).

    The cert step (5) does a Key Vault data-plane import (and the App Proxy
    publish reads the staged PFX), so run Tier 0 from a host with VNet
    line-of-sight to the private Key Vault (laptop on VPN or in-VNet jumpbox) -
    the same requirement as Tier 1. The CI wiring and prereqs deploy are
    control-plane only and work from anywhere.

    Idempotent: re-running keeps existing resources and just rewrites the
    bicepparam values.

    Step 1 answers persist: at the end of Step 1 every collected value is
    written to a .psd1 config file (default: <repo>/.rds-farm-init.config.psd1).
    The next run loads it as defaults so you can press Enter through every
    prompt. CLI parameters always override the file. Secrets
    (DOMAIN_JOIN_PASSWORD, LOCAL_ADMIN_PASSWORD, cert passwords) are never
    written there.

    Out of scope (you still do these by hand because they live outside Azure
    or outside this repo):
      * Creating the AD domain-join service account and the RDS access group.
      * Pre-creating the target VNet + subnet.
      * Creating the public CNAME after the first deploy (Tier 2 —
         scripts/Set-GatewayCname.ps1 helps if you use Azure DNS).
      * Activating RDS CALs on the broker (Tier 2 — manual MMC step).
      * (App Proxy / -CertMode LetsEncrypt) Adding the NS + CNAME records this
         script prints at your registrar, the public CNAME to <app>.msappproxy.net,
         the internal split-horizon A record (gateway private IP), and registering
         the connector software (interactive Entra sign-in). See docs/app-proxy.md.

.PARAMETER GitHubRepo
    <org-or-user>/<repo>, e.g. 'contoso/rds-farm'. If omitted, taken from the
    config file (see -ConfigFile) or prompted for interactively.

.PARAMETER SubscriptionId
    Optional. Defaults to the subscription `az account show` returns.

.PARAMETER Location
    Azure region for the prereq RGs / KV / SA and the farm deployment.
    **Required, no default** - pass `-Location <region>` (e.g.
    `-Location italynorth`). Interactive mode (the default) prompts for it; a
    `-NonInteractive` run must pass it explicitly. The value flows into the
    bicepparam, the prereqs deploy, and the CI repo variable.

.PARAMETER AdDomainName
    The AD domain to join (e.g. 'contoso.local'). Required.

.PARAMETER AdDnsServerIp
    IP of a DC the new VMs can reach for DNS. Required.

.PARAMETER DomainJoinUserName
    sAMAccountName of the pre-created service account that has delegated
    rights to join machines to the target OU. Default: 'svc-domainjoin'.

.PARAMETER DomainJoinOuPath
    Optional. Distinguished Name of the OU to drop the new RDS VM computer
    objects into, e.g. 'OU=RDS,OU=Servers,DC=contoso,DC=local'. The
    -DomainJoinUserName account must have 'Create Computer Objects'
    delegated on that OU. Leave empty (default) to use the domain's default
    Computers container.

.PARAMETER LocalAdminUserName
    Local administrator username for the new VMs. Default: 'rdsadmin'.

.PARAMETER RdsAccessGroup
    Pre-existing AD security group whose members may sign in via RD Web +
    RD Gateway. Use 'Domain Users' for a quick lab. Default: 'Domain Users'.

.PARAMETER ExistingVnetName
    Pre-existing VNet that hosts the RDS subnet. Required.

.PARAMETER ExistingVnetResourceGroup
    Resource group of the existing VNet. Required.

.PARAMETER ExistingRdsSubnetName
    Subnet inside the VNet that will host the RDS VMs. Required.

.PARAMETER AllowedClientSourceAddressPrefixes
    String[] of CIDRs allowed to reach TCP 443 / UDP 3391. Office / VPN
    egress IPs only — NEVER '0.0.0.0/0'. Required.

.PARAMETER SubnetNsgName
    Optional. Name of the governance NSG already attached to the RDS subnet
    (landing-zone / Azure Policy managed), co-located in the VNet resource
    group. The farm writes its client allow-list (TCP 443 / UDP 3391) as named
    rules on this NSG instead of attaching its own NIC NSG. When omitted, the
    script auto-discovers it from the live subnet in Step 6. If the subnet has
    no NSG, no allow-list is written and the gateway stays unreachable.

.PARAMETER PublicGatewayFqdn
    Public hostname clients will type. Required for -CertMode Csr / ImportPfx
    (a vanity FQDN you own, e.g. 'rds.contoso.com' — must match the cert
    Subject / SAN). Optional for -CertMode SelfSigned: leave it empty and the
    script derives the Azure-managed LB hostname
    '<GatewayDnsLabelPrefix>.<Location>.cloudapp.azure.com' for you. Public
    CAs cannot sign for 'cloudapp.azure.com' (Microsoft owns it) so a vanity
    FQDN is still required outside the self-signed lab path.

.PARAMETER GatewayDnsLabelPrefix
    Globally unique DNS label for the Azure-managed PIP hostname
    (<label>.<region>.cloudapp.azure.com). Defaults to a sanitised version
    of -PublicGatewayFqdn.

.PARAMETER DeployBastion
    Whether the farm template deploys an Azure Bastion (Standard SKU; needs an
    AzureBastionSubnet in the VNet). Default $true. Pass -DeployBastion:$false
    when you reach the VMs another way - a Developer-SKU bastion you created
    yourself, a jumpbox, etc. The value is written into main.bicepparam so
    deploys are deterministic and don't rely on the template default.

.PARAMETER UseAppProxy
    Publish through Microsoft Entra application proxy instead of a public load
    balancer. When $true the farm skips the public IP + LB and internet inbound
    NSG rules, deploys a connector VM, and configures the gateway for
    -PublicGatewayFqdn with Entra pre-authentication. Default $false (implied by
    -CertMode LetsEncrypt). Written to main.bicepparam (useAppProxy). See
    docs/app-proxy.md.

.PARAMETER ArtifactsStorageAccount
    Globally unique storage account name (3-24 chars, lowercase
    alphanumeric) that will be created to hold Configuration.zip. Required.

.PARAMETER KeyVaultName
    Globally unique Key Vault name (3-24 chars) that will be created to hold
    the TLS cert. Required.

.PARAMETER ArtifactsResourceGroup
    Resource group for the artifacts SA. Default: 'rds-artifacts-rg'.

.PARAMETER KeyVaultResourceGroup
    Resource group for the Key Vault. Default: 'rds-security-rg'.

.PARAMETER CertMode
    'Csr', 'ImportPfx', 'SelfSigned', or 'LetsEncrypt'. Required. 'LetsEncrypt'
    issues a publicly-trusted DV cert via DNS-01 for the App Proxy FQDN and
    implies -UseAppProxy (see docs/app-proxy.md).

.PARAMETER PfxPath
    Path to the .pfx file. Required only when -CertMode ImportPfx.

.PARAMETER CertName
    Name of the cert object in Key Vault. Default: 'rds-tls'.

.PARAMETER AcmeContactEmail
    Email for the Let's Encrypt account (expiry notices). Required when
    -CertMode LetsEncrypt.

.PARAMETER AcmeDnsZoneName
    Azure DNS public zone that holds the ACME challenge TXT, delegated from your
    registrar. Only for -CertMode LetsEncrypt. Defaults to 'acme.<parent of the
    App Proxy FQDN>' (e.g. acme.contoso.com for rds.contoso.com).

.PARAMETER AcmeDnsResourceGroup
    Resource group that holds the Azure DNS challenge zone (created if missing).
    Only for -CertMode LetsEncrypt. Default: 'rds-dns-rg'.

.PARAMETER GhAppDisplayName
    Display name for the Entra app the GitHub pipeline uses. Default:
    'gh-rds-farm-deploy'.

.PARAMETER GhRequireProductionApproval
    Switch. Mark the 'production' GitHub environment as requiring approval
    from the current GitHub user. Requires GH Pro/Team/Enterprise on private
    repos.

.PARAMETER BicepParamFile
    Path to main.bicepparam to patch. Default: <repo>/main.bicepparam.

.PARAMETER GhSkipCiBootstrap
    Skip step 3 (Entra app + federated creds + GitHub secrets). Use only if
    you've already run scripts/Initialize-CiPrerequisites.ps1 successfully
    against this repo.

.PARAMETER SkipPrereqsDeploy
    Skip step 4 (prereqs Bicep). Use only when you already have the
    artifacts SA + Key Vault and pass their names via -ArtifactsStorageAccount
    and -KeyVaultName.

.PARAMETER NonInteractive
    Switch. By DEFAULT the script is interactive: it prompts for every parameter
    (required and optional), pre-filling the current value as the bracketed
    default - press Enter to keep each. Pass -NonInteractive to skip the optional
    prompts and only ask for missing REQUIRED values, silently using defaults for
    the rest (CI/CD-friendly).

.PARAMETER ConfigFile
    Path to the .psd1 file used to persist Step 1 answers between runs.
    Default: <repo>/.rds-farm-init.config.psd1. Loaded at startup as defaults
    (CLI params still win) and rewritten at the end of Step 1 with the values
    you just confirmed. Hand-editable PowerShell data file.

.PARAMETER NoSaveConfig
    Switch. Do not (re)write the config file at the end of Step 1. Use when
    you want a one-off run that does not pollute your saved defaults.

.EXAMPLE
    # Fully scripted (CI/CD-friendly, prompts only for passwords)
    .\scripts\Initialize-RdsFarm.ps1 -NonInteractive `
        -GitHubRepo 'contoso/rds-farm' `
        -Location italynorth `
        -AdDomainName contoso.local -AdDnsServerIp 10.10.0.4 `
        -RdsAccessGroup 'RDS-Users' `
        -ExistingVnetName corp-vnet `
        -ExistingVnetResourceGroup network-rg `
        -ExistingRdsSubnetName snet-rds `
        -AllowedClientSourceAddressPrefixes '203.0.113.0/24','198.51.100.10/32' `
        -PublicGatewayFqdn rds.contoso.com `
        -ArtifactsStorageAccount contosordsart01 `
        -KeyVaultName contoso-rds-kv01 `
        -CertMode Csr `
        -GhRequireProductionApproval

.EXAMPLE
    # Interactive lab setup — script prompts for every missing required value.
    .\scripts\Initialize-RdsFarm.ps1 -GitHubRepo 'me/rds-farm-lab' -CertMode SelfSigned

.EXAMPLE
    # App Proxy + free Let's Encrypt cert. -CertMode LetsEncrypt implies -UseAppProxy.
    # First run creates the Azure DNS challenge zone and prints the registrar records;
    # after you delegate, re-run to issue the cert and publish the proxy app.
    .\scripts\Initialize-RdsFarm.ps1 -GitHubRepo 'contoso/rds-farm' `
        -CertMode LetsEncrypt -PublicGatewayFqdn rds.contoso.com `
        -AcmeContactEmail admin@contoso.com -RdsAccessGroup 'RDS-Users' `
        -AdDomainName contoso.local -AdDnsServerIp 10.10.0.4 `
        -ExistingVnetName corp-vnet -ExistingVnetResourceGroup network-rg -ExistingRdsSubnetName snet-rds `
        -AllowedClientSourceAddressPrefixes '203.0.113.0/24' `
        -ArtifactsStorageAccount contosordsart01 -KeyVaultName contoso-rds-kv01

.EXAMPLE
    # Guided tour — interactive by default: prompts for every value (defaults pre-filled).
    .\scripts\Initialize-RdsFarm.ps1 -GitHubRepo 'me/rds-farm-lab'

.NOTES
    Required tooling on the machine running this script:
      * Azure CLI ('az') signed in: `az login` (use --tenant <id> if needed).
      * GitHub CLI ('gh')   signed in: `gh auth login` with `repo` scope.
      * PowerShell 7+.
      * Permission to create app registrations in the Entra tenant
        ('Application Developer' minimum) and Owner on the target subscription
        (to assign 'Role Based Access Control Administrator').
#>
[CmdletBinding()]
param(
    # GitHub
    [ValidatePattern('^[^/]+/[^/]+$')]
    [string]$GitHubRepo,

    # Azure scope
    [string]$SubscriptionId,
    [string]$Location = '',

    # AD
    [string]$AdDomainName,
    [string]$AdDnsServerIp,
    [string]$DomainJoinUserName = 'svc-domainjoin',
    [string]$DomainJoinOuPath   = '',
    [string]$LocalAdminUserName = 'rdsadmin',
    [string]$RdsAccessGroup     = 'Domain Users',

    # Existing network
    [string]$ExistingVnetName,
    [string]$ExistingVnetResourceGroup,
    [string]$ExistingRdsSubnetName,
    [string[]]$AllowedClientSourceAddressPrefixes,
    [string]$SubnetNsgName,

    # Gateway hostname
    [string]$PublicGatewayFqdn,
    [string]$GatewayDnsLabelPrefix,

    # Bastion (admin access). Default $true matches main.bicep. Set $false when
    # you reach the VMs another way (a Developer-SKU bastion you manage out of
    # band, a jumpbox, etc.). Written to main.bicepparam in Step 6 so the
    # script owns the value instead of leaving the template default.
    [bool]$DeployBastion = $true,

    # Microsoft Entra application proxy. When -UseAppProxy the farm skips the
    # public IP + load balancer and internet inbound NSG rules, deploys a
    # connector VM, and configures the gateway for -PublicGatewayFqdn (the single
    # external FQDN used by both modes) with Entra pre-authentication. Written to
    # main.bicepparam in Step 6. See docs/app-proxy.md.
    [bool]$UseAppProxy = $false,

    # Prereqs
    [string]$ArtifactsStorageAccount,
    [string]$KeyVaultName,
    [string]$ArtifactsResourceGroup = 'rds-artifacts-rg',
    [string]$KeyVaultResourceGroup  = 'rds-security-rg',
    [string]$FarmResourceGroup      = 'rds-farm-rg',

    # Prereqs — Private Endpoint + DNS plumbing.
    # The KV and SA both deploy with publicNetworkAccess=Disabled (subscription
    # policy enforces this). Reachability for the farm VMs depends on PEs in
    # the spoke 'pe' subnet, plus privatelink.* zones linked to the right VNets.
    #
    # PeSubnetId    : full resource ID of an already-existing subnet (with
    #                 privateEndpointNetworkPolicies=Disabled) where the PEs go.
    # DnsZoneVnetLinks : full VNet resource IDs that should resolve the BLOB
    #                 privatelink zone. At minimum the spoke VNet; add the hub
    #                 if uploads / cert mgmt happen from a hub jump box.
    # UseExistingKvZone / ExistingKvZoneResourceId / ExistingKvZoneAdditionalVnetLinks :
    #                 set when a central privatelink.vaultcore.azure.net zone
    #                 already exists (e.g. one your platform team manages and
    #                 the hub is linked to). The template will skip creating
    #                 its own vault zone, point the KV PE's zone group at the
    #                 existing zone, and add the listed VNet links to it.
    [string]$PeSubnetId,
    [string[]]$DnsZoneVnetLinks,
    [switch]$UseExistingKvZone,
    [string]$ExistingKvZoneResourceId,
    [string[]]$ExistingKvZoneAdditionalVnetLinks,

    # TLS cert
    [ValidateSet('Csr','ImportPfx','SelfSigned','LetsEncrypt')]
    [string]$CertMode,
    [string]$PfxPath,
    [string]$CertName = 'rds-tls',

    # Let's Encrypt (only when -CertMode LetsEncrypt; implies -UseAppProxy). The
    # cert is issued for -PublicGatewayFqdn via DNS-01, with the challenge TXT
    # written to an Azure DNS zone delegated from your registrar.
    [string]$AcmeContactEmail,
    [string]$AcmeDnsZoneName,
    [string]$AcmeDnsResourceGroup = 'rds-dns-rg',

    # CI bootstrap
    [string]$GhAppDisplayName = 'gh-rds-farm-deploy',
    [switch]$GhRequireProductionApproval,

    # File + skip toggles
    [string]$BicepParamFile = (Join-Path $PSScriptRoot '..' 'main.bicepparam'),
    [switch]$GhSkipCiBootstrap,
    [switch]$SkipPrereqsDeploy,

    # UX
    [switch]$NonInteractive,

    # Persisted Step 1 answers
    [string]$ConfigFile = (Join-Path $PSScriptRoot '..' '.rds-farm-init.config.psd1'),
    [switch]$NoSaveConfig
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Interactive prompting is the default. -NonInteractive opts out: it only asks for
# missing REQUIRED values and silently uses defaults for the optional ones.
$Interactive = -not $NonInteractive

# -Location is required with no default (a hardcoded region silently lands the
# prereq RGs/KV/SA in the wrong place). Interactive mode prompts for it; a
# -NonInteractive run must pass it explicitly.
if (-not $Location -and -not $Interactive) {
    throw "No -Location provided. Pass -Location <region> (e.g. -Location italynorth), or omit -NonInteractive to be prompted."
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Assert-Tool {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required tool '$Name' was not found in PATH."
    }
}

function Assert-KeyVaultReachable {
    # Fast-fail when this host can't reach the private Key Vault DATA plane: if the
    # vault FQDN resolves to a PUBLIC IP we're not on an in-VNet host, and the cert
    # import would 403 (publicNetworkAccess=Disabled). .NET resolution is used (not
    # Resolve-DnsName) so this also catches running Tier 0 from a Mac/laptop.
    # Ambiguous results (no / failed resolution) only warn - the cert step's own
    # error covers those.
    param([Parameter(Mandatory)][string]$VaultName)

    $kvHost = "$VaultName.vault.azure.net"
    # RFC 1918 + CGNAT (100.64/10), the same ranges as Publish-DscArtifact.ps1.
    $privatePattern = '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)'
    try {
        $ips = @([System.Net.Dns]::GetHostAddresses($kvHost) |
                Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
                ForEach-Object { $_.IPAddressToString })
    }
    catch {
        Write-Warning "Could not resolve $kvHost ($($_.Exception.Message)); skipping the in-VNet host pre-check. The cert step will surface any access error."
        return
    }
    if (-not $ips) {
        Write-Warning "No IPv4 resolved for $kvHost; skipping the in-VNet host pre-check."
        return
    }
    $private = @($ips | Where-Object { $_ -match $privatePattern })
    if (-not $private) {
        throw "$kvHost resolves to PUBLIC IP(s) [$($ips -join ', ')] from this host, so the Key Vault data plane is unreachable and the cert import would fail with HTTP 403 (public network access is disabled). Run Tier 0 from a host INSIDE the VNet - a jumpbox, the DC, or a VM via Bastion - see the 'Where code runs' note in the README."
    }
    Write-Host "    Key Vault data plane reachable ($kvHost -> $($private -join ', ')); host is in-VNet." -ForegroundColor DarkGray
}

function Read-RequiredString {
    param(
        [string]$Prompt,
        [string]$Default,
        [string[]]$Hint
    )
    if ($Hint) {
        Write-Host ''
        foreach ($line in $Hint) { Write-Host "    $line" -ForegroundColor DarkGray }
    }
    $suffix = if ($Default) { " [$Default]" } else { '' }
    while ($true) {
        $value = Read-Host -Prompt "  $Prompt$suffix"
        if (-not $value -and $Default) { return $Default }
        if ($value)                    { return $value }
        Write-Host "    Value required." -ForegroundColor Yellow
    }
}

function Read-RequiredStringArray {
    <#
        Prompt for one-or-more comma/space-separated tokens. Returns a string[].
        Pass -Default to pre-fill (in interactive re-prompt mode): the
        bracketed default is shown joined by commas; pressing Enter accepts it.
    #>
    param(
        [string]$Prompt,
        [string[]]$Default,
        [string[]]$Hint
    )
    if ($Hint) {
        Write-Host ''
        foreach ($line in $Hint) { Write-Host "    $line" -ForegroundColor DarkGray }
    }
    $defShown = if ($Default -and $Default.Count) { ' [' + ($Default -join ',') + ']' } else { '' }
    while ($true) {
        $raw = Read-Host -Prompt "  $Prompt (comma- or space-separated)$defShown"
        if ([string]::IsNullOrWhiteSpace($raw) -and $Default -and $Default.Count) {
            return ,$Default
        }
        $items = $raw -split '[,\s]+' | Where-Object { $_ }
        if ($items) { return ,$items }
        Write-Host "    At least one value required." -ForegroundColor Yellow
    }
}

function Read-OptionalString {
    <#
        Used by interactive mode for parameters that already have a default
        (or that legitimately may be empty, e.g. DomainJoinOuPath). Press Enter
        to keep $Default; type a new value to override. Always returns a string
        (never $null), so '' is a valid "keep empty" answer.
    #>
    param(
        [string]$Prompt,
        [string]$Default,
        [string[]]$Hint
    )
    if ($Hint) {
        Write-Host ''
        foreach ($line in $Hint) { Write-Host "    $line" -ForegroundColor DarkGray }
    }
    $suffix = if ($Default) { " [$Default]" } else { ' [empty]' }
    $value  = Read-Host -Prompt "  $Prompt$suffix"
    if ([string]::IsNullOrEmpty($value)) { return $Default }
    return $value
}

function Read-OptionalSwitch {
    <#
        Yes/no prompt for interactive mode. Pressing Enter keeps $Default.
        Accepts y/yes/true/1 and n/no/false/0 (case-insensitive). The capital
        letter in the [Y/n] / [y/N] hint indicates the current default.
    #>
    param(
        [string]$Prompt,
        [bool]$Default,
        [string[]]$Hint
    )
    if ($Hint) {
        Write-Host ''
        foreach ($line in $Hint) { Write-Host "    $line" -ForegroundColor DarkGray }
    }
    $defLabel = if ($Default) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $value = Read-Host -Prompt "  $Prompt [$defLabel]"
        if ([string]::IsNullOrEmpty($value)) { return $Default }
        if ($value -match '^(y|yes|true|1)$')  { return $true }
        if ($value -match '^(n|no|false|0)$')  { return $false }
        Write-Host "    Please answer y or n." -ForegroundColor Yellow
    }
}

function Get-DefaultDnsLabel {
    param([string]$Fqdn)
    # Lowercase first, THEN strip invalid chars - otherwise an uppercase first
    # label (e.g. 'RDS.contoso.com') would have all its letters stripped to ''.
    $first = ($Fqdn -split '\.')[0].ToLowerInvariant()
    return ($first -replace '[^a-z0-9-]', '' -replace '^-+','' -replace '-+$','')
}

function Test-FqdnFormat {
    <#
        Returns $true when $Fqdn looks like a real DNS hostname clients can
        actually type and a public CA can sign for. Rejects bare hostnames,
        underscores, leading/trailing hyphens, and labels > 63 chars.
    #>
    param([string]$Fqdn)
    if (-not $Fqdn) { return $false }
    if ($Fqdn.Length -gt 253) { return $false }
    # Per RFC 1035 + 5890: labels of 1-63 chars, letters/digits/hyphens, no leading/trailing hyphen.
    # Require at least one dot (no bare hostnames) and a 2+ char TLD.
    $pattern = '^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'
    return ($Fqdn.ToLowerInvariant() -match $pattern)
}

function Test-VCpuQuota {
    <#
        Best-effort vCPU quota precheck for the chosen VM size + region. Returns
        a PSCustomObject with .Sufficient (bool), .Needed (int), .Available (int)
        and a printable .Detail. Treats CLI failure as "skip" (returns
        Sufficient = $true with Detail explaining why) - this is a soft guard,
        not a hard gate.
    #>
    param(
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string]$VmSize,
        [Parameter(Mandatory)][int]$VmCount
    )
    # Map common D-series SKUs -> vCPUs. Anything not in this list falls back
    # to a parse of the suffix digit (Standard_D4s_v5 -> 4); on any failure
    # we return Sufficient=$true with a Detail noting the skip.
    $vCpusPerVm = $null
    if ($VmSize -match '^Standard_[A-Z]+(\d+)') { $vCpusPerVm = [int]$Matches[1] }
    if (-not $vCpusPerVm) {
        return [pscustomobject]@{
            Sufficient = $true; Needed = 0; Available = 0
            Detail = "could not parse vCPU count from VM size '$VmSize' - skipping quota check"
        }
    }

    $needed = $VmCount * $vCpusPerVm

    # `az vm list-usage` returns the regional CPU quotas. The family name we
    # care about for D*s_v5 is 'standardDSv5Family'; rather than guess, we sum
    # 'Total Regional vCPUs' as a conservative upper bound the deploy will run
    # against. If the CLI call fails (offline, no perms), skip the check.
    $raw = az vm list-usage -l $Location -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) {
        return [pscustomobject]@{
            Sufficient = $true; Needed = $needed; Available = 0
            Detail = "az vm list-usage failed for '$Location' - skipping quota check"
        }
    }
    $usage = $raw | ConvertFrom-Json
    $regional = $usage | Where-Object { $_.name.value -eq 'cores' } | Select-Object -First 1
    if (-not $regional) {
        return [pscustomobject]@{
            Sufficient = $true; Needed = $needed; Available = 0
            Detail = "regional vCPU quota not returned for '$Location' - skipping quota check"
        }
    }
    $available = [int]$regional.limit - [int]$regional.currentValue
    return [pscustomobject]@{
        Sufficient = ($available -ge $needed)
        Needed     = $needed
        Available  = $available
        Detail     = "regional vCPUs in $Location : used=$([int]$regional.currentValue) limit=$([int]$regional.limit) free=$available need=$needed"
    }
}

function Update-BicepParamString {
    param(
        [Parameter(Mandatory)][string]$Body,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )
    $pattern = "(?m)^(?<lead>\s*param\s+$([regex]::Escape($Name))\s*=\s*)'[^']*'"
    if ($Body -notmatch $pattern) {
        throw "param '$Name' not found in $BicepParamFile (expected '$Name = ''...''' on a single line)."
    }
    return [regex]::Replace($Body, $pattern, "`${lead}'$Value'")
}

function Update-BicepParamBool {
    param(
        [Parameter(Mandatory)][string]$Body,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Value
    )
    $literal = if ($Value) { 'true' } else { 'false' }
    $pattern = "(?m)^(?<lead>\s*param\s+$([regex]::Escape($Name))\s*=\s*)(?:true|false)"
    if ($Body -notmatch $pattern) {
        throw "param '$Name' (bool) not found in $BicepParamFile (expected '$Name = true|false' on a single line)."
    }
    return [regex]::Replace($Body, $pattern, "`${lead}$literal")
}

function Update-BicepParamArray {
    param(
        [Parameter(Mandatory)][string]$Body,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$Values
    )
    # Match a multi-line array literal: param <name> = [ \n  '...' \n  '...' \n ]
    $pattern = "(?ms)^(?<lead>\s*param\s+$([regex]::Escape($Name))\s*=\s*\[)\s*.*?\]"
    if ($Body -notmatch $pattern) {
        throw "param '$Name' (array) not found in $BicepParamFile."
    }
    $lines = ($Values | ForEach-Object { "  '$_'" }) -join "`n"
    $replacement = "`${lead}`n$lines`n]"
    return [regex]::Replace($Body, $pattern, $replacement)
}

function Get-MyObjectId {
    $oid = az ad signed-in-user show --query id -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $oid) { throw "Could not resolve current Entra user object id." }
    return $oid.Trim()
}

# ---------------------------------------------------------------------------
# Persisted Step 1 answers (.psd1 config file)
# ---------------------------------------------------------------------------
# Ordered list of (sectionTitle, paramNames) used by BOTH the loader (to know
# which variables to overlay) and the writer (to control section grouping and
# write order). Anything NOT in this list is never persisted - in particular
# UX/meta params like -NonInteractive, -ConfigFile, -NoSaveConfig.
$script:RdsFarmInitConfigSections = @(
    @{ Title = 'GitHub & Azure scope'; Params = @('GitHubRepo','SubscriptionId','Location') }
    @{ Title = 'Active Directory'    ; Params = @('AdDomainName','AdDnsServerIp','DomainJoinUserName','DomainJoinOuPath','LocalAdminUserName','RdsAccessGroup') }
    @{ Title = 'Existing network'    ; Params = @('ExistingVnetName','ExistingVnetResourceGroup','ExistingRdsSubnetName','AllowedClientSourceAddressPrefixes','SubnetNsgName') }
    @{ Title = 'Gateway hostname'    ; Params = @('PublicGatewayFqdn','GatewayDnsLabelPrefix') }
    @{ Title = 'Bastion'             ; Params = @('DeployBastion') }
    @{ Title = 'Application proxy'   ; Params = @('UseAppProxy') }
    @{ Title = 'Prereqs (KV + SA)'   ; Params = @('ArtifactsStorageAccount','KeyVaultName','ArtifactsResourceGroup','KeyVaultResourceGroup','FarmResourceGroup') }
    @{ Title = 'TLS cert'            ; Params = @('CertMode','PfxPath','CertName','AcmeContactEmail','AcmeDnsZoneName','AcmeDnsResourceGroup') }
    @{ Title = 'CI bootstrap'        ; Params = @('GhAppDisplayName','GhRequireProductionApproval') }
    @{ Title = 'File + skip toggles' ; Params = @('BicepParamFile','GhSkipCiBootstrap','SkipPrereqsDeploy') }
)

function Get-AllowedConfigParams {
    return $script:RdsFarmInitConfigSections | ForEach-Object { $_.Params } | ForEach-Object { $_ }
}

function Format-RdsFarmInitPsd1Value {
    <#
        Serialize a single value into a literal a .psd1 file can hold.
        Strings: single-quoted with internal ' doubled.
        Bools/switches: $true / $false.
        IEnumerable: @('a','b') (empty arrays as @()).
        Null / anything else: empty string literal.
    #>
    param($Value)
    if ($null -eq $Value) { return "''" }
    if ($Value -is [bool] -or $Value -is [System.Management.Automation.SwitchParameter]) {
        return $(if ([bool]$Value) { '$true' } else { '$false' })
    }
    if ($Value -is [string]) {
        $escaped = $Value -replace "'", "''"
        return "'$escaped'"
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @($Value | ForEach-Object {
            $s = ([string]$_) -replace "'", "''"
            "'$s'"
        })
        if ($items.Count -eq 0) { return '@()' }
        return "@($($items -join ', '))"
    }
    $escaped = ([string]$Value) -replace "'", "''"
    return "'$escaped'"
}

function Import-RdsFarmInitConfig {
    <#
        Load saved Step 1 answers from $Path and overlay them onto the
        currently-bound parameter variables in the caller's scope. CLI
        parameters (anything present in $PSBoundParameters) are NEVER
        overwritten. Returns the number of values applied. No-op if the file
        does not exist. Warns and continues on parse errors.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$BoundParameters
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 0 }
    try {
        $loaded = Import-PowerShellDataFile -LiteralPath $Path
    } catch {
        Write-Warning "Could not parse config file '$Path' - ignoring. ($($_.Exception.Message))"
        return 0
    }
    $applied = 0
    foreach ($name in Get-AllowedConfigParams) {
        if ($BoundParameters.ContainsKey($name)) { continue }   # CLI wins
        if (-not $loaded.ContainsKey($name))     { continue }
        try {
            Set-Variable -Name $name -Scope 1 -Value $loaded[$name]
            $applied++
        } catch {
            Write-Warning "Could not apply saved value for '$name': $($_.Exception.Message)"
        }
    }
    return $applied
}

function Save-RdsFarmInitConfig {
    <#
        Write current Step 1 answers to $Path as a tidy, hand-editable .psd1.
        Reads each value from the caller's scope via Get-Variable -Scope 1.
        Creates the parent directory if needed. Atomic-ish: writes to .tmp
        then renames so a half-written file never replaces a good one.
    #>
    param(
        [Parameter(Mandatory)][string]$Path
    )
    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.AppendLine('@{')
    $null = $sb.AppendLine("    # Generated by Initialize-RdsFarm.ps1 on $((Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')).")
    $null = $sb.AppendLine('    # Hand-edit values to change defaults on the next interactive run.')
    $null = $sb.AppendLine('    # CLI parameters ALWAYS override values stored here.')
    $null = $sb.AppendLine('    # Secrets (DOMAIN_JOIN_PASSWORD, LOCAL_ADMIN_PASSWORD, cert passwords) are')
    $null = $sb.AppendLine('    # never persisted in this file.')
    $null = $sb.AppendLine('')

    foreach ($section in $script:RdsFarmInitConfigSections) {
        $dashes = '-' * [Math]::Max(1, 60 - $section.Title.Length)
        $null = $sb.AppendLine("    # --- $($section.Title) $dashes")
        $maxLen = ($section.Params | Measure-Object -Property Length -Maximum).Maximum
        foreach ($name in $section.Params) {
            $val = Get-Variable -Name $name -Scope 1 -ValueOnly -ErrorAction SilentlyContinue
            $formatted = Format-RdsFarmInitPsd1Value $val
            $padded = $name.PadRight($maxLen)
            $null = $sb.AppendLine("    $padded = $formatted")
        }
        $null = $sb.AppendLine('')
    }
    $null = $sb.AppendLine('}')

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $tmp = "$Path.tmp"
    Set-Content -LiteralPath $tmp -Value $sb.ToString() -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

# ---------------------------------------------------------------------------
# 0. Pre-flight
# ---------------------------------------------------------------------------
Write-Host "==> Pre-flight" -ForegroundColor Cyan
Assert-Tool 'az'
Assert-Tool 'gh'

# Load persisted Step 1 answers from $ConfigFile BEFORE we use $SubscriptionId
# / $BicepParamFile / etc. CLI params (anything bound by the caller) always win.
if (-not [System.IO.Path]::IsPathRooted($ConfigFile)) {
    $ConfigFile = Join-Path (Get-Location).Path $ConfigFile
}
$ConfigFile = [System.IO.Path]::GetFullPath($ConfigFile)
if (Test-Path -LiteralPath $ConfigFile -PathType Leaf) {
    $applied = Import-RdsFarmInitConfig -Path $ConfigFile -BoundParameters $PSBoundParameters
    Write-Host "    Config file  : $ConfigFile (loaded $applied saved value$(if ($applied -ne 1) { 's' }))"
} else {
    Write-Host "    Config file  : $ConfigFile (will be created at end of Step 1)"
}

az bicep version 1>$null 2>$null
if ($LASTEXITCODE -ne 0) { throw "az bicep is not available. Run 'az bicep install' first." }

$ctx = az account show -o json 2>$null | ConvertFrom-Json
if (-not $ctx) { throw "Not signed in to Azure. Run 'az login' first." }
if ($SubscriptionId) {
    az account set --subscription $SubscriptionId | Out-Null
    $ctx = az account show -o json | ConvertFrom-Json
}
$SubscriptionId = $ctx.id
$TenantId       = $ctx.tenantId
Write-Host "    Subscription : $($ctx.name) ($SubscriptionId)"
Write-Host "    Tenant       : $TenantId"

gh auth status 1>$null 2>$null
if ($LASTEXITCODE -ne 0) { throw "GitHub CLI not signed in. Run 'gh auth login' first." }

$BicepParamFile = (Resolve-Path -LiteralPath $BicepParamFile).Path
if (-not (Test-Path -LiteralPath $BicepParamFile -PathType Leaf)) {
    throw "BicepParamFile not found: $BicepParamFile"
}
Write-Host "    Bicepparam   : $BicepParamFile"

$repoRoot = Split-Path -Parent $PSScriptRoot
$initCi   = Join-Path $PSScriptRoot 'Initialize-CiPrerequisites.ps1'
$newCert  = Join-Path $PSScriptRoot 'New-RdsCertificate.ps1'
$prereqs  = Join-Path $repoRoot 'prereqs\tier0.bicep'
foreach ($p in @($initCi, $newCert, $prereqs)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "Required file missing: $p" }
}

# ---------------------------------------------------------------------------
# 1. Collect inputs (prompt for anything not passed)
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "==> Step 1: Collect inputs" -ForegroundColor Green
if ($Interactive) {
    Write-Host "    Prompting for every parameter (saved/CLI values pre-filled)." -ForegroundColor Yellow
    Write-Host "    (Tip: pass -NonInteractive to only be asked for required values you didn't supply.)"
} else {
    Write-Host "    -NonInteractive mode: only asking for required values you didn't pass on the command line."
}
Write-Host "    Press Enter to accept the bracketed default. Required fields keep asking until filled."
Write-Host ""

# -------------------------------------------------------------------------
# Interactive optionals — every parameter with a built-in default. Each
# prompt pre-fills the current value as the [bracketed] default, so a
# pure 'Enter, Enter, Enter…' run is equivalent to a non-interactive
# call. Skipped entirely under -NonInteractive.
# -------------------------------------------------------------------------
if ($Interactive) {
    Write-Host "    --- Optional values (press Enter to keep default) -------------" -ForegroundColor DarkGray

    # Subscription / region. The currently-signed-in subscription is the
    # default; entering a different ID or name re-runs `az account set`
    # and refreshes $ctx so the rest of the script targets the new sub.
    $subAnswer = Read-OptionalString `
        -Prompt 'Subscription (ID or name)' `
        -Default $ctx.name `
        -Hint 'Target Azure subscription. Default is the one az is currently signed into.'
    if ($subAnswer -and $subAnswer -ne $ctx.name -and $subAnswer -ne $ctx.id) {
        az account set --subscription $subAnswer | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Failed to switch to subscription '$subAnswer'." }
        $ctx            = az account show -o json | ConvertFrom-Json
        $SubscriptionId = $ctx.id
        $TenantId       = $ctx.tenantId
        Write-Host "    Switched subscription: $($ctx.name) ($SubscriptionId)" -ForegroundColor DarkGray
    }

    $Location = Read-RequiredString `
        -Prompt 'Azure region' `
        -Default $Location `
        -Hint 'Region for the prereq RGs (KV + storage) and the farm RG.'

    # AD identity defaults
    $DomainJoinUserName = Read-OptionalString `
        -Prompt 'Domain-join service account (sAMAccountName)' `
        -Default $DomainJoinUserName `
        -Hint 'Pre-created AD account used by the JoinDomain DSC resource. The password is collected in Step 2 (CI bootstrap) and stored as the DOMAIN_JOIN_PASSWORD GitHub secret.'

    $DomainJoinOuPath = Read-OptionalString `
        -Prompt 'Domain-join target OU (DN, empty = default Computers container)' `
        -Default $DomainJoinOuPath `
        -Hint @(
            "Distinguished Name of the OU the new VM computer objects land in.",
            "Empty = AD's default Computers container. Example: OU=RDS,OU=Servers,DC=contoso,DC=local.",
            'The domain-join account needs Create Computer Objects on that OU.'
        )

    $LocalAdminUserName = Read-OptionalString `
        -Prompt 'Local admin username (on every RDS VM)' `
        -Default $LocalAdminUserName `
        -Hint 'Local administrator account baked into every VM. The password is collected in Step 2 (CI bootstrap) and stored as the LOCAL_ADMIN_PASSWORD GitHub secret.'

    $RdsAccessGroup = Read-OptionalString `
        -Prompt 'AD group allowed to use RD Web + RD Gateway' `
        -Default $RdsAccessGroup `
        -Hint 'Members of this AD security group may sign in to the farm. "Domain Users" works for labs.'

    # Prereqs RG names
    $ArtifactsResourceGroup = Read-OptionalString `
        -Prompt 'Artifacts resource group' `
        -Default $ArtifactsResourceGroup `
        -Hint 'RG that holds the artifacts storage account (Configuration.zip).'

    $KeyVaultResourceGroup = Read-OptionalString `
        -Prompt 'Key Vault resource group' `
        -Default $KeyVaultResourceGroup `
        -Hint 'RG that holds the Key Vault storing the TLS cert.'

    $FarmResourceGroup = Read-OptionalString `
        -Prompt 'Farm resource group (where the workflow deploys VMs/LB/NSG)' `
        -Default $FarmResourceGroup `
        -Hint 'RG the GitHub Actions workflow creates and runs main.bicep into. Written to GitHub as the AZURE_RESOURCE_GROUP repo variable.'

    # Cert + CI bootstrap
    $CertName = Read-OptionalString `
        -Prompt 'TLS cert name in Key Vault' `
        -Default $CertName `
        -Hint 'Name of the cert object inside KV. Reused on re-runs to update an existing cert.'

    $GhAppDisplayName = Read-OptionalString `
        -Prompt 'Entra app display name (for GitHub OIDC)' `
        -Default $GhAppDisplayName `
        -Hint 'Display name of the Entra app the GitHub Actions workflow logs in as via federated credentials.'

    $GhRequireProductionApproval = [bool] (Read-OptionalSwitch `
        -Prompt 'Require approval on the production GitHub environment?' `
        -Default $GhRequireProductionApproval.IsPresent `
        -Hint 'Adds yourself as the required reviewer for deploys to production. Needs GH Pro/Team/Enterprise on private repos.')

    # File + skip toggles
    $BicepParamFile = Read-OptionalString `
        -Prompt 'Path to main.bicepparam to patch' `
        -Default $BicepParamFile `
        -Hint 'The script patches network/AD/gateway values into this file. Defaults to <repo>/main.bicepparam.'

    $GhSkipCiBootstrap = [bool] (Read-OptionalSwitch `
        -Prompt 'Skip CI bootstrap (Entra app + federated creds + GitHub secrets)?' `
        -Default $GhSkipCiBootstrap.IsPresent `
        -Hint 'Set Y when Initialize-CiPrerequisites.ps1 has already run successfully against this repo.')

    $SkipPrereqsDeploy = [bool] (Read-OptionalSwitch `
        -Prompt 'Skip prereqs Bicep (KV + storage account creation)?' `
        -Default $SkipPrereqsDeploy.IsPresent `
        -Hint 'Set Y only when KV + SA already exist and you pass -ArtifactsStorageAccount / -KeyVaultName.')

    Write-Host "    --- End optional values ---------------------------------------" -ForegroundColor DarkGray
    Write-Host ''
}

# GitHubRepo can come from CLI, config file, or this prompt. CLI values are
# validated by [ValidatePattern] at bind time; config / prompt values are not,
# so re-validate manually and re-prompt on a bad value. In interactive mode we
# also re-prompt with the loaded value as the default so users can edit it
# without retyping (and so the prompt sequence matches a fresh first-run).
if ($GitHubRepo -and -not ($GitHubRepo -match '^[^/]+/[^/]+$')) {
    Write-Warning "Loaded GitHubRepo '$GitHubRepo' is not in <owner>/<repo> form - will re-prompt."
    $GitHubRepo = ''
}
if ($Interactive -or -not $GitHubRepo) {
    while ($true) {
        $GitHubRepo = Read-RequiredString `
            -Prompt 'GitHub repository (<owner>/<repo>)' `
            -Default $GitHubRepo `
            -Hint @(
                'Used to store GitHub repo secrets/variables and to federate Azure access for CI.',
                "Example: 'contoso/rds-farm'."
            )
        if ($GitHubRepo -match '^[^/]+/[^/]+$') { break }
        Write-Host "    '$GitHubRepo' is not in <owner>/<repo> form. Try again." -ForegroundColor Yellow
        $GitHubRepo = ''
    }
}

if ($Interactive -or -not $AdDomainName) {
    $AdDomainName = Read-RequiredString `
        -Prompt 'AD domain name (e.g. contoso.local)' `
        -Default $AdDomainName `
        -Hint @(
            'Existing Active Directory forest/domain the new VMs will join.',
            'Use the FQDN your DCs report (e.g. contoso.local, ad.contoso.com).'
        )
}
if ($Interactive -or -not $AdDnsServerIp) {
    $AdDnsServerIp = Read-RequiredString `
        -Prompt 'AD DNS server IP (e.g. 10.10.0.4)' `
        -Default $AdDnsServerIp `
        -Hint @(
            'IP of a Domain Controller the new VMs can reach for DNS resolution.',
            'Set as the subnet DNS so domain-join works during VM bootstrap.'
        )
}
if ($Interactive -or -not $ExistingVnetName) {
    $ExistingVnetName = Read-RequiredString `
        -Prompt 'Existing VNet name' `
        -Default $ExistingVnetName `
        -Hint 'Name of the pre-existing VNet that hosts the RDS subnet (this script never creates it).'
}
if ($Interactive -or -not $ExistingVnetResourceGroup) {
    $ExistingVnetResourceGroup = Read-RequiredString `
        -Prompt 'Resource group of the VNet' `
        -Default $ExistingVnetResourceGroup `
        -Hint 'Resource group where the existing VNet lives (often different from the farm RG).'
}
if ($Interactive -or -not $ExistingRdsSubnetName) {
    $ExistingRdsSubnetName = Read-RequiredString `
        -Prompt 'Subnet name for RDS VMs' `
        -Default $ExistingRdsSubnetName `
        -Hint @(
            'Subnet inside the VNet above where the gateway + session-host VMs will land.',
            'Must have line-of-sight to the DC and outbound internet for the DSC extension.'
        )
}
if ($Interactive -or -not $AllowedClientSourceAddressPrefixes) {
    $AllowedClientSourceAddressPrefixes = Read-RequiredStringArray `
        -Prompt 'Allowed client source CIDRs (NEVER 0.0.0.0/0)' `
        -Default $AllowedClientSourceAddressPrefixes `
        -Hint @(
            'CIDRs allowed to reach the public LB on TCP 443 (RD Web / Gateway) and UDP 3391 (RDP UDP).',
            'Use your office / VPN egress ranges. Open internet (0.0.0.0/0) is rejected.'
        )
}

if ($Interactive) {
    $DeployBastion = [bool] (Read-OptionalSwitch `
        -Prompt 'Deploy an Azure Bastion for admin access?' `
        -Default $DeployBastion `
        -Hint @(
            'Adds a Standard-SKU Azure Bastion. Requires an AzureBastionSubnet (/26+) in the VNet above.',
            'Answer n if you reach the VMs another way - a Developer-SKU bastion you created yourself, or a jumpbox.'
        ))
}

# Cert mode is gathered BEFORE the FQDN so the FQDN prompt can branch on it:
# SelfSigned lets you skip -PublicGatewayFqdn entirely and use the Azure-
# managed LB hostname; Csr / ImportPfx require a vanity FQDN you own (public
# CAs cannot sign for cloudapp.azure.com).
if ($Interactive -or -not $CertMode) {
    $modeDefault = if ($CertMode) { $CertMode } else { 'SelfSigned' }
    $modeRaw = Read-RequiredString `
        -Prompt 'Cert mode (Csr / ImportPfx / SelfSigned / LetsEncrypt)' `
        -Default $modeDefault `
        -Hint @(
            'Csr        = production. Script emits a CSR; you submit to your CA; re-run to merge the signed cert.',
            'ImportPfx  = production. You supply an existing .pfx already issued by a publicly-trusted CA.',
            'SelfSigned = lab/dev only. Script generates the cert in Key Vault. Clients will see a trust warning.',
            'LetsEncrypt= App Proxy. Free DV cert via DNS-01 for your App Proxy FQDN; implies -UseAppProxy.'
        )
    if ($modeRaw -notin @('Csr','ImportPfx','SelfSigned','LetsEncrypt')) { throw "Invalid -CertMode '$modeRaw'." }
    $CertMode = $modeRaw
}
if ($CertMode -eq 'ImportPfx' -and ($Interactive -or -not $PfxPath)) {
    $PfxPath = Read-RequiredString `
        -Prompt 'Path to .pfx file' `
        -Default $PfxPath `
        -Hint 'Full path to the existing .pfx. The cert password is prompted separately as a SecureString.'
}

# LetsEncrypt is the App Proxy path: the cert FQDN is the App Proxy external FQDN,
# there is no public LB, and the challenge zone/alias derive from the FQDN. Resolve
# all of that here so the SelfSigned / vanity FQDN prompts below can be skipped.
if ($CertMode -eq 'LetsEncrypt') {
    $UseAppProxy = $true
    if ($Interactive -or -not $PublicGatewayFqdn) {
        $PublicGatewayFqdn = Read-RequiredString `
            -Prompt 'Public gateway FQDN (e.g. rds.contoso.com)' `
            -Default $PublicGatewayFqdn `
            -Hint @(
                'Vanity hostname users type. Becomes the cert Subject/SAN and the App Proxy external URL.',
                'Must be a DNS name you own; its public DNS is hosted at your registrar.'
            )
    }
    if (-not (Test-FqdnFormat $PublicGatewayFqdn)) {
        throw "PublicGatewayFqdn '$PublicGatewayFqdn' is not a valid DNS name. Expect 'rds.contoso.com'."
    }
    if (-not $GatewayDnsLabelPrefix) { $GatewayDnsLabelPrefix = Get-DefaultDnsLabel $PublicGatewayFqdn }
    if (-not $AcmeDnsZoneName) { $AcmeDnsZoneName = 'acme.' + ($PublicGatewayFqdn -split '\.', 2)[1] }
    if ($Interactive -or -not $AcmeContactEmail) {
        $AcmeContactEmail = Read-RequiredString `
            -Prompt "Let's Encrypt contact email" `
            -Default $AcmeContactEmail `
            -Hint 'Let''s Encrypt sends certificate-expiry notices here.'
    }
}

if ($CertMode -eq 'LetsEncrypt') {
    # FQDN already resolved above (= App Proxy external FQDN); nothing more to prompt.
}
elseif ($CertMode -eq 'SelfSigned' -and ($Interactive -or -not $PublicGatewayFqdn)) {
    # Lab path: derive the FQDN from the Azure-managed LB hostname. The DNS
    # label has to come first because there's no vanity FQDN to default it
    # from. Pre-fill from the GitHub repo name as a hint, or from a previously
    # derived label/FQDN if we have one in the config.
    if ($Interactive -or -not $GatewayDnsLabelPrefix) {
        $labelHint = if ($GatewayDnsLabelPrefix) {
            $GatewayDnsLabelPrefix
        } elseif ($PublicGatewayFqdn) {
            Get-DefaultDnsLabel $PublicGatewayFqdn
        } else {
            Get-DefaultDnsLabel ($GitHubRepo -split '/')[-1]
        }
        $GatewayDnsLabelPrefix = Read-RequiredString `
            -Prompt 'Gateway DNS label (Azure PIP, globally unique)' `
            -Default $labelHint `
            -Hint @(
                "Globally-unique label for the Azure-managed public IP. Final hostname will be:",
                "  <label>.$Location.cloudapp.azure.com",
                'SelfSigned lab path: this hostname is also written as the cert subject (no vanity FQDN needed).'
            )
    }
    $PublicGatewayFqdn = "$GatewayDnsLabelPrefix.$Location.cloudapp.azure.com".ToLowerInvariant()
    Write-Host "    Using Azure-managed LB FQDN  : $PublicGatewayFqdn" -ForegroundColor DarkGray
} else {
    # Vanity FQDN path (Csr / ImportPfx, or SelfSigned with a vanity FQDN
    # explicitly passed in).
    if ($Interactive -or -not $PublicGatewayFqdn) {
        $PublicGatewayFqdn = Read-RequiredString `
            -Prompt 'Public gateway FQDN (e.g. rds.contoso.com)' `
            -Default $PublicGatewayFqdn `
            -Hint @(
                'Vanity hostname your users will type into the RD client / browser.',
                'Must be a DNS name you own. Will become the cert Subject/SAN and the CNAME target after deploy.'
            )
    }
    if (-not (Test-FqdnFormat $PublicGatewayFqdn)) {
        throw "PublicGatewayFqdn '$PublicGatewayFqdn' is not a valid DNS name. Expect 'rds.contoso.com', not bare hostnames, underscores, or labels longer than 63 chars."
    }
    if ($Interactive -or -not $GatewayDnsLabelPrefix) {
        $GatewayDnsLabelPrefix = Read-RequiredString `
            -Prompt 'Gateway DNS label (Azure PIP, globally unique)' `
            -Default ($(if ($GatewayDnsLabelPrefix) { $GatewayDnsLabelPrefix } else { Get-DefaultDnsLabel $PublicGatewayFqdn })) `
            -Hint @(
                "Label for the Azure-managed public IP. Your vanity FQDN will CNAME to:",
                "  <label>.$Location.cloudapp.azure.com",
                'Must be globally unique within the region. Default is derived from your vanity FQDN.'
            )
    }
}

if ($Interactive -or -not $ArtifactsStorageAccount) {
    $ArtifactsStorageAccount = Read-RequiredString `
        -Prompt 'Artifacts storage account name (3-24 chars, lowercase, globally unique)' `
        -Default $ArtifactsStorageAccount `
        -Hint @(
            'Storage account that hosts Configuration.zip (the DSC artifact) for the VM extension.',
            'Created by the prereqs Bicep if it does not already exist. Reused on re-runs.'
        )
}
if ($Interactive -or -not $KeyVaultName) {
    $KeyVaultName = Read-RequiredString `
        -Prompt 'Key Vault name (3-24 chars, globally unique)' `
        -Default $KeyVaultName `
        -Hint @(
            'Key Vault that stores the TLS cert. VMs read it at boot via their managed identity.',
            'Created by the prereqs Bicep if it does not already exist. Reused on re-runs.'
        )
}

$certificateSubject = "CN=$PublicGatewayFqdn"

# Show summary + confirm
Write-Host ""
Write-Host "    --- Summary --------------------------------------------------" -ForegroundColor Cyan
Write-Host "    GitHub repo                  : $GitHubRepo"
Write-Host "    Subscription                 : $($ctx.name)"
Write-Host "    Location                     : $Location"
Write-Host "    AD domain / DNS              : $AdDomainName / $AdDnsServerIp"
Write-Host "    Domain-join account          : $DomainJoinUserName"
Write-Host "    Domain-join target OU        : $(if ($DomainJoinOuPath) { $DomainJoinOuPath } else { '(default: Computers container)' })"
Write-Host "    Local admin                  : $LocalAdminUserName"
Write-Host "    RDS access group             : $RdsAccessGroup"
Write-Host "    Existing VNet/subnet         : $ExistingVnetResourceGroup/$ExistingVnetName/$ExistingRdsSubnetName"
Write-Host "    Subnet governance NSG        : $(if ($SubnetNsgName) { $SubnetNsgName } else { '(auto-discovered from subnet in Step 6)' })"
Write-Host "    Allowed client CIDRs         : $($AllowedClientSourceAddressPrefixes -join ', ')"
Write-Host "    Public gateway FQDN          : $PublicGatewayFqdn"
Write-Host "    Cert subject                 : $certificateSubject"
Write-Host "    Azure PIP DNS label          : $GatewayDnsLabelPrefix.$Location.cloudapp.azure.com"
Write-Host "    Deploy Azure Bastion         : $DeployBastion"
Write-Host "    Artifacts SA                 : $ArtifactsStorageAccount (RG $ArtifactsResourceGroup)"
Write-Host "    Key Vault                    : $KeyVaultName (RG $KeyVaultResourceGroup)"
Write-Host "    Farm RG (deploy target)      : $FarmResourceGroup ($Location)"
Write-Host "    Cert mode                    : $CertMode$(if ($PfxPath) { "  (pfx=$PfxPath)" })"
if ($CertMode -eq 'LetsEncrypt') {
    Write-Host "    ACME challenge zone (AzDNS)  : $AcmeDnsZoneName (RG $AcmeDnsResourceGroup)"
    Write-Host "    Let's Encrypt contact        : $AcmeContactEmail"
}
Write-Host "    Entra app display name       : $GhAppDisplayName"
Write-Host "    Production approval required : $([bool]$GhRequireProductionApproval)"
Write-Host "    Skip CI bootstrap            : $([bool]$GhSkipCiBootstrap)"
Write-Host "    Skip prereqs Bicep deploy    : $([bool]$SkipPrereqsDeploy)"
Write-Host "    --------------------------------------------------------------"
Write-Host ""

# Best-effort vCPU quota precheck. Reads vmSize + sessionHostCount from the
# current bicepparam (they default to Standard_D4s_v5 / 2 = 4 VMs / 16 vCPUs).
# Failures here are warnings only - a wrong VM family won't block Tier 0.
try {
    $paramText = Get-Content -LiteralPath $BicepParamFile -Raw
    $vmSizeM   = [regex]::Match($paramText, "(?m)^\s*param\s+vmSize\s*=\s*'([^']+)'")
    $countM    = [regex]::Match($paramText, "(?m)^\s*param\s+sessionHostCount\s*=\s*(\d+)")
    if ($vmSizeM.Success -and $countM.Success) {
        # Need: 1 gateway + 1 broker + N session hosts.
        $vmCount = 2 + [int]$countM.Groups[1].Value
        $quota   = Test-VCpuQuota -Location $Location -VmSize $vmSizeM.Groups[1].Value -VmCount $vmCount
        Write-Host "    Quota check ($($vmSizeM.Groups[1].Value) x $vmCount): $($quota.Detail)"
        if (-not $quota.Sufficient) {
            Write-Host ""
            Write-Host "    WARNING: subscription regional vCPU quota in $Location appears insufficient." -ForegroundColor Yellow
            Write-Host "    Need $($quota.Needed) vCPUs, $($quota.Available) free. Request an increase before Tier 1 runs:" -ForegroundColor Yellow
            Write-Host "      az vm list-usage -l $Location --query `"[?name.value=='cores']`"" -ForegroundColor Yellow
            Write-Host "      https://learn.microsoft.com/azure/azure-portal/supportability/regional-quota-requests" -ForegroundColor Yellow
            Write-Host ""
        }
    }
} catch {
    Write-Host "    Quota check skipped: $($_.Exception.Message)" -ForegroundColor DarkGray
}

# Persist Step 1 answers BEFORE the proceed prompt so an abort here still
# leaves the user's just-typed values saved for the next run.
if (-not $NoSaveConfig) {
    try {
        Save-RdsFarmInitConfig -Path $ConfigFile
        Write-Host "    Step 1 answers saved to: $ConfigFile" -ForegroundColor DarkGray
    } catch {
        Write-Warning "Could not save config to '$ConfigFile': $($_.Exception.Message)"
    }
}

$confirm = Read-Host -Prompt 'Proceed? (y/N)'
if ($confirm -notmatch '^(y|yes)$') {
    Write-Host "Aborted by user." -ForegroundColor Yellow
    return
}

# ---------------------------------------------------------------------------
# 2. CI bootstrap (Entra app, federated creds, GH secrets/envs)
# ---------------------------------------------------------------------------
if (-not $GhSkipCiBootstrap) {
    Write-Host ""
    Write-Host "==> Step 2: CI bootstrap (Initialize-CiPrerequisites.ps1)" -ForegroundColor Green
    Write-Host "    You will be prompted ONCE for DOMAIN_JOIN_PASSWORD and LOCAL_ADMIN_PASSWORD."
    Write-Host "    Both are stored only as GitHub repo secrets — never written to disk."

    $ciArgs = @{
        GitHubRepo       = $GitHubRepo
        GhAppDisplayName = $GhAppDisplayName
        # Skip the inner self-check: the storage account it verifies doesn't
        # exist yet (Step 4 creates it). Test-RdsFarmInit.ps1 at the end
        # checks everything once everything actually exists.
        SkipSelfCheck  = $true
    }
    if ($SubscriptionId)          { $ciArgs['SubscriptionId']          = $SubscriptionId }
    # Pass the SA name through so the GH repo variable is set in this step
    # instead of leaving the self-check to warn that it's missing.
    # Step 7 below still calls 'gh variable set' to keep things idempotent
    # (and to update the value if the prereqs deploy renames the SA).
    if ($ArtifactsStorageAccount) { $ciArgs['ArtifactsStorageAccount'] = $ArtifactsStorageAccount }
    # Push Location + FarmResourceGroup to GitHub repo variables so the
    # workflow's env: block picks them up (otherwise main.bicep deploys into
    # the workflow's hard-coded defaults, not the region you chose here).
    if ($Location)                { $ciArgs['Location']                = $Location }
    if ($FarmResourceGroup)       { $ciArgs['FarmResourceGroup']       = $FarmResourceGroup }
    if ($GhRequireProductionApproval) { $ciArgs['GhRequireProductionApproval'] = $true }

    & $initCi @ciArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Initialize-CiPrerequisites.ps1 exited with code $LASTEXITCODE."
    }
} else {
    Write-Host ""
    Write-Host "==> Step 2: CI bootstrap SKIPPED (per -GhSkipCiBootstrap)" -ForegroundColor Yellow
}

# Resolve the CI service principal object ID (created by step 2 or already there).
Write-Host ""
Write-Host "==> Step 3: Resolve principals for adminPrincipals" -ForegroundColor Green
$ciApp = az ad app list --display-name $GhAppDisplayName --query '[0]' -o json | ConvertFrom-Json
if (-not $ciApp) { throw "Entra app '$GhAppDisplayName' not found. Run without -GhSkipCiBootstrap first." }
$ciSp  = az ad sp list --filter "appId eq '$($ciApp.appId)'" --query '[0]' -o json | ConvertFrom-Json
if (-not $ciSp) { throw "Service principal for app '$GhAppDisplayName' not found." }
$ciSpObjectId = $ciSp.id
$myObjectId   = Get-MyObjectId
Write-Host "    Current user object id : $myObjectId"
Write-Host "    CI SP object id        : $ciSpObjectId"

# ---------------------------------------------------------------------------
# 4. Prereqs Bicep (Key Vault + storage SA)
# ---------------------------------------------------------------------------
$artifactsLocationUrl = "https://$ArtifactsStorageAccount.blob.core.windows.net/dsc/"

if (-not $SkipPrereqsDeploy) {
    Write-Host ""
    Write-Host "==> Step 4: Provision prereqs (prereqs/tier0.bicep)" -ForegroundColor Green

    $adminPrincipals = @(
        @{ id = $myObjectId;   type = 'User'             }
        @{ id = $ciSpObjectId; type = 'ServicePrincipal' }
    )

    # Validate the PE / DNS inputs up front so the failure shows here, not 4
    # minutes into the deploy. PeSubnetId and DnsZoneVnetLinks are mandatory
    # because publicNetworkAccess is enforced off; without a PE the farm VMs
    # cannot reach KV or the SA.
    if ([string]::IsNullOrWhiteSpace($PeSubnetId)) {
        throw "PeSubnetId is required. Pre-create a /28 'pe' subnet in the spoke VNet (privateEndpointNetworkPolicies=Disabled) and pass its full resource ID."
    }
    if (-not $DnsZoneVnetLinks -or $DnsZoneVnetLinks.Count -eq 0) {
        throw "DnsZoneVnetLinks is required (at minimum the spoke VNet that owns PeSubnetId). Pass an array of full VNet resource IDs."
    }
    if ($UseExistingKvZone -and [string]::IsNullOrWhiteSpace($ExistingKvZoneResourceId)) {
        throw "UseExistingKvZone was specified but ExistingKvZoneResourceId is empty. Provide the full resource ID of the existing privatelink.vaultcore.azure.net zone (e.g. .../rg-j-dns-01/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net)."
    }

    # We can't pass adminPrincipals inline as 'name=<json>' because PowerShell
    # mangles embedded double quotes when handing argv to az.cmd, producing
    # '[{id:..,type:User}...]' which the CLI then fails to parse as JSON.
    # Same applies to dnsZoneVnetLinks and existingKvZoneAdditionalVnetLinks
    # (string arrays with quoting). Workaround: write a single ARM parameters
    # file that carries every value the deploy needs and pass it with
    # --parameters @file.
    $paramFile = New-TemporaryFile
    try {
        $armParamValues = @{
            adminPrincipals  = @{ value = $adminPrincipals }
            peSubnetId       = @{ value = $PeSubnetId }
            dnsZoneVnetLinks = @{ value = $DnsZoneVnetLinks }
            useExistingKvZone = @{ value = [bool]$UseExistingKvZone }
            existingKvZoneResourceId = @{ value = ($ExistingKvZoneResourceId ?? '') }
            existingKvZoneAdditionalVnetLinks = @{
                value = (@($ExistingKvZoneAdditionalVnetLinks) | Where-Object { $_ })
            }
        }
        $armParams = @{
            '$schema'       = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
            contentVersion = '1.0.0.0'
            parameters     = $armParamValues
        }
        ($armParams | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $paramFile -Encoding utf8

        $deployName = "rds-prereqs-$(Get-Date -Format yyyyMMdd-HHmmss)"
        az deployment sub create `
            --name              $deployName `
            --location          $Location `
            --template-file     $prereqs `
            --parameters        "@$($paramFile.FullName)" `
                                location=$Location `
                                storageResourceGroupName=$ArtifactsResourceGroup `
                                keyVaultResourceGroupName=$KeyVaultResourceGroup `
                                storageAccountName=$ArtifactsStorageAccount `
                                keyVaultName=$KeyVaultName `
            --output            none
        if ($LASTEXITCODE -ne 0) { throw "Prereqs deployment failed." }
    } finally {
        Remove-Item -LiteralPath $paramFile.FullName -Force -ErrorAction SilentlyContinue
    }

    # Read the storage account name back from outputs (lets caller mistype safely).
    $outSa = az deployment sub show --name $deployName --query 'properties.outputs.storageAccountName.value' -o tsv
    if ($outSa -and $outSa -ne $ArtifactsStorageAccount) {
        Write-Host "    NOTE: prereqs output storageAccountName='$outSa' (using this from now on)." -ForegroundColor Yellow
        $ArtifactsStorageAccount = $outSa
        $artifactsLocationUrl    = "https://$ArtifactsStorageAccount.blob.core.windows.net/dsc/"
    }
    Write-Host "    Prereqs deployed. SA=$ArtifactsStorageAccount  KV=$KeyVaultName"
} else {
    Write-Host ""
    Write-Host "==> Step 4: Prereqs deploy SKIPPED (per -SkipPrereqsDeploy)" -ForegroundColor Yellow
    Write-Host "    Using existing SA=$ArtifactsStorageAccount  KV=$KeyVaultName"
}

# ---------------------------------------------------------------------------
# 5. Create / import TLS cert + patch cert-related bicepparam values
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "==> Step 5: TLS certificate ($CertMode)" -ForegroundColor Green

# Fast-fail if this host can't reach the private Key Vault data plane. Every cert
# mode imports into the PE-only vault, so a wrong host (e.g. a plain laptop) would
# otherwise 403 partway through - catch it here with a clear message.
Assert-KeyVaultReachable -VaultName $KeyVaultName

$setCertUri = Join-Path $PSScriptRoot 'Set-BicepParamCertUri.ps1'

if ($CertMode -eq 'LetsEncrypt') {
    # ===== App Proxy: Let's Encrypt DNS-01 cert + publish the proxy app =====
    $newLeCert         = Join-Path $PSScriptRoot 'New-LetsEncryptRdsCertificate.ps1'
    $configureAppProxy = Join-Path $PSScriptRoot 'Configure-AppProxy.ps1'

    # 5a. Ensure the Azure DNS challenge zone exists (delegated from your registrar).
    Write-Host "    Ensuring Azure DNS challenge zone '$AcmeDnsZoneName' (RG $AcmeDnsResourceGroup)..."
    az group create -n $AcmeDnsResourceGroup -l $Location -o none
    if ($LASTEXITCODE -ne 0) { throw "Failed to ensure resource group '$AcmeDnsResourceGroup'." }
    az network dns zone show -g $AcmeDnsResourceGroup -n $AcmeDnsZoneName -o none 2>$null
    $zoneExisted = ($LASTEXITCODE -eq 0)
    if (-not $zoneExisted) {
        az network dns zone create -g $AcmeDnsResourceGroup -n $AcmeDnsZoneName -o none
        if ($LASTEXITCODE -ne 0) { throw "Failed to create Azure DNS zone '$AcmeDnsZoneName'." }
    }
    $nsServers = az network dns zone show -g $AcmeDnsResourceGroup -n $AcmeDnsZoneName --query nameServers -o tsv
    if ($LASTEXITCODE -ne 0) { throw "Failed to read name servers for '$AcmeDnsZoneName'." }
    $fqdnLabel       = ($PublicGatewayFqdn -split '\.', 2)[0]
    $registrarDomain = ($PublicGatewayFqdn -split '\.', 2)[1]
    $dnsAlias        = "$fqdnLabel.$AcmeDnsZoneName"

    Write-Host ""
    Write-Host "    One-time records to publish at your DNS host for '$registrarDomain':" -ForegroundColor Yellow
    Write-Host "      Host: acme                        Type: NS     Value: (each name server below)" -ForegroundColor Yellow
    foreach ($ns in @($nsServers)) { if ($ns) { Write-Host "                                                   $ns" -ForegroundColor Yellow } }
    Write-Host "      Host: _acme-challenge.$fqdnLabel   Type: CNAME  Value: $dnsAlias" -ForegroundColor Yellow
    Write-Host ""

    if (-not $zoneExisted) {
        throw "Created the Azure DNS challenge zone '$AcmeDnsZoneName'. Add the NS + CNAME records above at your DNS host, wait for propagation, then re-run Initialize-RdsFarm.ps1 to issue the certificate and publish the app."
    }

    # 5b. Issue / renew the cert via DNS-01 using the current az login (no IMDS).
    Write-Host "    Issuing Let's Encrypt certificate for $PublicGatewayFqdn..." -ForegroundColor Green
    $cert = & $newLeCert `
        -Fqdn            $PublicGatewayFqdn `
        -AcmeDnsZoneName $AcmeDnsZoneName `
        -KeyVaultName    $KeyVaultName `
        -CertName        $CertName `
        -Contact         $AcmeContactEmail `
        -UseAzAccessToken
    if (-not $cert) { throw "New-LetsEncryptRdsCertificate.ps1 did not return a certificate (issuance failed)." }

    # 5c. Patch the cert-related bicepparam values (the LE script does not do this).
    & $setCertUri `
        -ParamFile                $BicepParamFile `
        -KeyVaultName             $KeyVaultName `
        -KeyVaultResourceGroup    $KeyVaultResourceGroup `
        -KeyVaultCertSecretUri    "https://$KeyVaultName.vault.azure.net/secrets/$CertName" `
        -CertificateSubject       "CN=$PublicGatewayFqdn" `
        -PublicGatewayFqdn        $PublicGatewayFqdn `
        -EnableCertificateBinding $true `
        -NoBackup | Out-Host

    # 5d. Publish the Entra application proxy app (needs Cloud Application Administrator).
    Write-Host ""
    Write-Host "==> Step 5b: Publish Entra application proxy app (Configure-AppProxy.ps1)" -ForegroundColor Green
    Write-Host "    This needs the Cloud Application Administrator role in Entra ID." -ForegroundColor DarkGray
    & $configureAppProxy `
        -Fqdn            $PublicGatewayFqdn `
        -PfxPath         $cert.PfxPath `
        -PfxPassword     $cert.PfxPassword `
        -AssignGroupName $RdsAccessGroup `
        -BicepParamFile  $BicepParamFile | Out-Host
}
else {
    # ===== Csr / ImportPfx / SelfSigned via New-RdsCertificate.ps1 =====
    $certArgs = @{
        VaultName        = $KeyVaultName
        CertName         = $CertName
        Fqdn             = $PublicGatewayFqdn
        Mode             = $CertMode
        OutputBicepParam = $BicepParamFile
    }
    if ($CertMode -eq 'ImportPfx') { $certArgs['PfxPath'] = $PfxPath }

    & $newCert @certArgs
    if ($LASTEXITCODE -ne 0) {
        if ($CertMode -eq 'Csr') {
            Write-Host ""
            Write-Host "    Csr mode: a .csr file was written. Submit it to your CA, then re-run:" -ForegroundColor Yellow
            Write-Host "      ./scripts/New-RdsCertificate.ps1 -VaultName $KeyVaultName -CertName $CertName -Fqdn $PublicGatewayFqdn -MergeSignedCert <signed.cer> -OutputBicepParam $BicepParamFile" -ForegroundColor Yellow
            Write-Host "    Re-running Initialize-RdsFarm.ps1 after the merge will patch the bicepparam." -ForegroundColor Yellow
            throw "Cert is pending CA signature. Halting before main.bicepparam is overwritten with incomplete cert URI."
        }
        throw "New-RdsCertificate.ps1 failed (exit $LASTEXITCODE)."
    }

    # Also ensure the keyVaultResourceGroup is set in bicepparam — New-RdsCertificate
    # only updates it when it sees the param; we KNOW the RG so set it explicitly.
    & $setCertUri `
        -ParamFile             $BicepParamFile `
        -KeyVaultResourceGroup $KeyVaultResourceGroup `
        -EnableCertificateBinding $true `
        -NoBackup | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Failed to patch keyVaultResourceGroup in $BicepParamFile." }
}

# ---------------------------------------------------------------------------
# 6. Patch the remaining (non-cert) values in main.bicepparam
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "==> Step 6: Patch main.bicepparam (network, AD, gateway, artifactsLocation)" -ForegroundColor Green

$backup = "$BicepParamFile.bak"
Copy-Item -LiteralPath $BicepParamFile -Destination $backup -Force
Write-Host "    Backup written: $backup"

$content = Get-Content -LiteralPath $BicepParamFile -Raw
$origLen = $content.Length

# Discover the subnet's governance NSG so the farm can write its client allow-list
# there. The farm no longer attaches its own NIC NSG; modules/network.bicep adds
# the 443/3391 allow rules to this NSG. Bicep can't read the subnet's NSG at
# deploy start, so we resolve it here and pass the name through the bicepparam.
if ([string]::IsNullOrWhiteSpace($SubnetNsgName)) {
    $snNsgId = az network vnet subnet show -g $ExistingVnetResourceGroup --vnet-name $ExistingVnetName -n $ExistingRdsSubnetName --query 'networkSecurityGroup.id' -o tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and $snNsgId) {
        $SubnetNsgName = ($snNsgId -split '/')[-1]
        Write-Host "    Discovered subnet governance NSG: $SubnetNsgName" -ForegroundColor DarkGray
    } else {
        Write-Host "    WARNING: subnet '$ExistingRdsSubnetName' has no associated NSG. The farm will NOT write a client allow-list, so the gateway will be unreachable from the internet. Attach a governance NSG to the subnet (or set -SubnetNsgName)." -ForegroundColor Yellow
    }
}

$stringPatches = [ordered]@{
    existingVnetName                       = $ExistingVnetName
    existingVnetResourceGroup              = $ExistingVnetResourceGroup
    existingRdsSubnetName                  = $ExistingRdsSubnetName
    # Governance NSG the farm writes its 443/3391 allow-list to (discovered above).
    subnetNsgName                          = $SubnetNsgName
    adDomainName                           = $AdDomainName
    adDnsServerIp                          = $AdDnsServerIp
    domainJoinUserName                     = $DomainJoinUserName
    domainJoinOuPath                       = $DomainJoinOuPath
    localAdminUserName                     = $LocalAdminUserName
    gatewayDnsLabelPrefix                  = $GatewayDnsLabelPrefix
    # Write the FQDN derived/validated in Step 1 back to the param so it can't
    # drift from certificateSubject (which New-RdsCertificate.ps1 sets from the
    # same $PublicGatewayFqdn). Without this the committed placeholder
    # (rds.contoso.com) survives, GatewayExternalFqdn != cert subject, and RDS
    # mints a competing self-signed gateway cert.
    publicGatewayFqdn                      = $PublicGatewayFqdn
    rdsAccessGroup                         = $RdsAccessGroup
    artifactsLocation                      = $artifactsLocationUrl
    artifactsStorageAccountName            = $ArtifactsStorageAccount
    artifactsStorageAccountResourceGroup   = $ArtifactsResourceGroup
}

foreach ($name in $stringPatches.Keys) {
    $content = Update-BicepParamString -Body $content -Name $name -Value $stringPatches[$name]
}
$content = Update-BicepParamArray -Body $content -Name 'allowedClientSourceAddressPrefixes' -Values $AllowedClientSourceAddressPrefixes
$content = Update-BicepParamBool  -Body $content -Name 'deployBastion' -Value $DeployBastion
$content = Update-BicepParamBool  -Body $content -Name 'useAppProxy'   -Value $UseAppProxy

Set-Content -LiteralPath $BicepParamFile -Value $content -Encoding utf8 -NoNewline
$newLen = (Get-Item -LiteralPath $BicepParamFile).Length
Write-Host "    Patched $($stringPatches.Count + 2) param(s). ($origLen -> $newLen bytes)"

# Compile-check
Write-Host "    Validating with 'az bicep build-params'..."
foreach ($v in 'DOMAIN_JOIN_PASSWORD','LOCAL_ADMIN_PASSWORD') {
    if (-not [Environment]::GetEnvironmentVariable($v)) {
        [Environment]::SetEnvironmentVariable($v, 'placeholder-for-validation-only', 'Process')
    }
}
$tmp = New-TemporaryFile
try {
    & az bicep build-params --file $BicepParamFile --outfile $tmp.FullName 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Copy-Item -LiteralPath $backup -Destination $BicepParamFile -Force
        throw "Updated $BicepParamFile no longer compiles. Original restored from $backup."
    }
    Write-Host "    OK — main.bicepparam compiles." -ForegroundColor Green
} finally {
    Remove-Item -LiteralPath $tmp.FullName -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# 7. Set GitHub repo variables consumed by .github/workflows/deploy.yml.
# ---------------------------------------------------------------------------
# These are the ONLY way the orchestrator's -Location / -FarmResourceGroup
# choices reach the CI workflow — deploy.yml's env: block reads vars.* with
# hard-coded fallbacks. Repeat the writes here (Step 2 already did them) so
# rerunning the orchestrator after editing the saved config updates them.
Write-Host ""
Write-Host "==> Step 7: GitHub repo variables" -ForegroundColor Green
function Set-RepoVar {
    param([string]$Name, [string]$Value)
    Write-Host "    Setting $Name=$Value"
    gh variable set $Name --repo $GitHubRepo --body $Value
    if ($LASTEXITCODE -ne 0) { throw "Failed to set repo variable $Name." }
}
Set-RepoVar 'ARTIFACTS_STORAGE_ACCOUNT' $ArtifactsStorageAccount
Set-RepoVar 'AZURE_LOCATION'            $Location
Set-RepoVar 'AZURE_RESOURCE_GROUP'      $FarmResourceGroup

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "==================== Tier 0 complete ====================" -ForegroundColor Green
Write-Host "  Prereqs RGs       : $ArtifactsResourceGroup / $KeyVaultResourceGroup"
Write-Host "  Farm RG / region  : $FarmResourceGroup / $Location"
Write-Host "  Artifacts SA      : $ArtifactsStorageAccount"
Write-Host "  Key Vault         : $KeyVaultName"
Write-Host "  TLS cert          : $CertName (Subject=$certificateSubject)"
Write-Host "  Bicepparam        : $BicepParamFile (compiles)"
Write-Host "  GitHub repo       : $GitHubRepo (secrets + variable set, envs created)"
Write-Host ""
Write-Host "Verify Tier 0 (one command, read-only):" -ForegroundColor Cyan
Write-Host "  ./tests/Test-RdsFarmInit.ps1 -GitHubRepo $GitHubRepo"
Write-Host ""
Write-Host "Next steps (Tier 1 — deploy from this same in-VNet host):" -ForegroundColor Cyan
Write-Host "  ./scripts/Invoke-ManualDeploy.ps1 -Action what-if -StorageAccount $ArtifactsStorageAccount"
Write-Host "  ./scripts/Invoke-ManualDeploy.ps1 -Action deploy  -StorageAccount $ArtifactsStorageAccount"
Write-Host ""
Write-Host "  Commit the config too (version control):" -ForegroundColor DarkGray
Write-Host "    git add main.bicepparam && git commit -m 'Initialize farm config'" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Note: the GitHub Actions pipeline can't deploy from a GitHub-hosted runner" -ForegroundColor DarkGray
Write-Host "  (artifacts SA + Key Vault are private-endpoint-only). It needs a self-hosted" -ForegroundColor DarkGray
Write-Host "  runner inside the VNet. Until then, run the commands above from this in-VNet host." -ForegroundColor DarkGray
Write-Host ""
Write-Host "After the first successful deploy (Tier 2 — once):" -ForegroundColor Cyan
Write-Host "  1. Public DNS: CNAME $PublicGatewayFqdn -> <gatewayFqdn output>"
Write-Host "     (Azure DNS shortcut: ./scripts/Set-GatewayCname.ps1)"
Write-Host "  2. Activate RDS license server on the broker; install CALs."
Write-Host "  3. Add the broker computer to AD 'Terminal Server License Servers' group."
Write-Host "  4. Run docs/testing.md sections 2-4 for end-to-end smoke tests."
