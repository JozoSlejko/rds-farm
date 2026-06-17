configuration SessionHost {
    param (
        # DomainName / DomainJoinUserName are used to add the deployment
        # service account to the local Administrators group, so the broker
        # can remote-execute New-RDSessionDeployment against this host.
        # Both are optional so the config is backwards-compatible with prior
        # bicep wiring that didn't pass them (the Group resource simply
        # skips when either value is empty).
        [string] $DomainName           = '',
        [string] $DomainJoinUserName   = ''
    )

    Import-DscResource -ModuleName PSDesiredStateConfiguration

    Node localhost {
        WindowsFeature RDS-RD-Server {
            Ensure = 'Present'
            Name   = 'RDS-RD-Server'
        }

        # The broker's `New-RDSessionDeployment -SessionHost <fqdn>` call
        # remotes into this VM as the calling user (svc-domainjoin in our
        # deployment) and needs local admin to install RDS roles, configure
        # services, and write to the registry. svc-domainjoin is a plain
        # domain user with only "Create Computer Objects" delegated on the
        # target OU, so without this step the broker's cross-machine RDS
        # operations silently fail.
        if (-not [string]::IsNullOrEmpty($DomainJoinUserName) -and -not [string]::IsNullOrEmpty($DomainName)) {
            $netbios = ($DomainName -split '\.')[0]
            $principal = '{0}\{1}' -f $netbios, $DomainJoinUserName

            Group AddDeployAccountToAdmins {
                GroupName        = 'Administrators'
                Ensure           = 'Present'
                MembersToInclude = @($principal)
                DependsOn        = '[WindowsFeature]RDS-RD-Server'
            }
        }

        LocalConfigurationManager {
            RebootNodeIfNeeded = $true
            ActionAfterReboot  = 'ContinueConfiguration'
            ConfigurationMode  = 'ApplyOnly'
        }
    }
}

configuration Gateway {
    param (
        # $AdminCreds is accepted for backwards-compatibility with the bicep
        # wiring, but the gateway config now runs every Script resource as the
        # default DSC LCM identity (NT AUTHORITY\SYSTEM). LocalSystem has full
        # local admin rights and is also implicitly a member of the local
        # "RDS Management Servers" group, so it can write to the RDS:\
        # GatewayServer PSDrive. A non-admin domain account (the previous
        # default of svc-domainjoin) cannot, and CAP/RAP creation silently
        # failed with "PermissionDenied" on every prior run.
        [Parameter(Mandatory)] [PSCredential] $AdminCreds,
        [Parameter(Mandatory)] [string]       $DomainName,
        [string] $RDUserGroup         = 'Domain Users',
        [string] $CertificateSubject  = '',
        [string] $DomainJoinUserName  = ''
    )

    Import-DscResource -ModuleName PSDesiredStateConfiguration

    Node localhost {
        WindowsFeature RDS-Gateway {
            Ensure = 'Present'
            Name   = 'RDS-Gateway'
        }

        WindowsFeature RDS-Web-Access {
            Ensure = 'Present'
            Name   = 'RDS-Web-Access'
        }

        WindowsFeature RPC-over-HTTP-Proxy {
            Ensure = 'Present'
            Name   = 'RPC-over-HTTP-Proxy'
        }

        WindowsFeature RSAT-RDS-Gateway {
            Ensure = 'Present'
            Name   = 'RSAT-RDS-Gateway'
        }

        # The broker's `Add-RDServer -Server <gateway> -Role RDS-GATEWAY`
        # call remotes into this VM as the calling user (svc-domainjoin) and
        # needs local admin to register the gateway role. Without this step
        # the cross-machine call fails with "Access denied" and the gateway
        # never appears in the deployment.
        if (-not [string]::IsNullOrEmpty($DomainJoinUserName)) {
            $netbios = ($DomainName -split '\.')[0]
            $principal = '{0}\{1}' -f $netbios, $DomainJoinUserName

            Group AddDeployAccountToAdmins {
                GroupName        = 'Administrators'
                Ensure           = 'Present'
                MembersToInclude = @($principal)
                DependsOn        = '[WindowsFeature]RDS-Gateway'
            }
        }

        # Without a CAP and a RAP the RD Gateway is installed but rejects every
        # incoming session ("Your computer can't connect to the Remote Desktop
        # Gateway server"). We create one of each, scoped to $RDUserGroup, so
        # the test user can connect through the gateway out of the box.
        #
        # NOTE: No PsDscRunAsCredential -> runs as NT AUTHORITY\SYSTEM, which
        # is what the RDS:\GatewayServer PSDrive needs to allow New-Item.
        Script ConfigureRDGatewayPolicies {
            GetScript = { @{ Result = '' } }

            TestScript = {
                try {
                    Import-Module RemoteDesktopServices -ErrorAction Stop
                    $cap = Get-Item -Path 'RDS:\GatewayServer\CAP\Default-CAP' -ErrorAction SilentlyContinue
                    $rap = Get-Item -Path 'RDS:\GatewayServer\RAP\Default-RAP' -ErrorAction SilentlyContinue
                    return ($null -ne $cap -and $null -ne $rap)
                } catch {
                    return $false
                }
            }

            SetScript = {
                Import-Module RemoteDesktopServices

                # RemoteDesktopServices PSDrive wants group in UPN form: <group>@<dnsDomain>
                $userGroupQualified = '{0}@{1}' -f $using:RDUserGroup, $using:DomainName

                if (-not (Test-Path 'RDS:\GatewayServer\CAP\Default-CAP')) {
                    New-Item -Path 'RDS:\GatewayServer\CAP' `
                        -Name 'Default-CAP' `
                        -UserGroups @($userGroupQualified) `
                        -AuthMethod 1 | Out-Null   # 1 = password
                    Write-Verbose "Created RD CAP 'Default-CAP' for $userGroupQualified"
                }

                if (-not (Test-Path 'RDS:\GatewayServer\RAP\Default-RAP')) {
                    New-Item -Path 'RDS:\GatewayServer\RAP' `
                        -Name 'Default-RAP' `
                        -UserGroups        @($userGroupQualified) `
                        -ComputerGroupType 2 | Out-Null   # 2 = allow access to any network resource
                    Write-Verbose "Created RD RAP 'Default-RAP' for $userGroupQualified"
                }
            }

            DependsOn = '[WindowsFeature]RDS-Gateway'
        }

        # Bind the Key Vault-delivered TLS cert to (a) the IIS HTTPS binding,
        # (b) the HTTP.SYS sslcert table on 0.0.0.0:443, and (c) the
        # RDS:\GatewayServer\SSLCertificate\Thumbprint slot. RDS-Web-Access
        # installs an IIS binding with a self-signed cert that has
        # CN=<computer>.<domain>; without this step browsers see that cert
        # instead of the public-FQDN cert and TSGateway has no cert at all
        # (Thumbprint = NULL), so the gateway role can't service RDP-over-HTTPS.
        #
        # No-op if $CertificateSubject is empty or the cert isn't on disk yet
        # (the Key Vault VM extension may not have polled yet on first boot).
        Script BindGatewayLocalCerts {
            GetScript = { @{ Result = '' } }

            TestScript = {
                $subject = $using:CertificateSubject
                if ([string]::IsNullOrEmpty($subject)) { return $true }

                $cert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
                    Where-Object { $_.Subject -like "*$subject*" -and $_.HasPrivateKey } |
                    Sort-Object NotAfter -Descending |
                    Select-Object -First 1
                if ($null -eq $cert) { return $false }  # cert not delivered yet -> retry next consistency pass
                $hash = $cert.Thumbprint

                # IIS HTTPS binding
                try {
                    Import-Module WebAdministration -ErrorAction Stop
                    $iisOk = $false
                    foreach ($b in (Get-WebBinding -Protocol https -ErrorAction SilentlyContinue)) {
                        if (([string]$b.certificateHash) -ieq $hash) { $iisOk = $true }
                    }
                    if (-not $iisOk) { return $false }
                } catch { return $false }

                # RDS Gateway SSL cert thumbprint
                try {
                    Import-Module RemoteDesktopServices -ErrorAction Stop
                    $current = (Get-Item 'RDS:\GatewayServer\SSLCertificate\Thumbprint' -ErrorAction Stop).CurrentValue
                    if (([string]$current) -ine $hash) { return $false }
                } catch { return $false }

                return $true
            }

            SetScript = {
                $subject = $using:CertificateSubject
                if ([string]::IsNullOrEmpty($subject)) {
                    Write-Verbose 'BindGatewayLocalCerts: no CertificateSubject supplied, skipping.'
                    return
                }

                $cert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
                    Where-Object { $_.Subject -like "*$subject*" -and $_.HasPrivateKey } |
                    Sort-Object NotAfter -Descending |
                    Select-Object -First 1
                if ($null -eq $cert) {
                    Write-Warning "BindGatewayLocalCerts: no cert matching '$subject' found in LocalMachine\My. Key Vault extension may not have polled yet; will retry."
                    return
                }
                $hash = $cert.Thumbprint
                Write-Verbose "BindGatewayLocalCerts: using cert $($cert.Subject) ($hash)"

                # 1) IIS HTTPS binding -> our cert
                Import-Module WebAdministration -ErrorAction Stop
                $bindings = @(Get-WebBinding -Protocol https -ErrorAction SilentlyContinue)
                if ($bindings.Count -eq 0) {
                    # Create a default *:443 binding on Default Web Site if RDS-Web-Access install didn't.
                    New-WebBinding -Name 'Default Web Site' -Protocol https -Port 443 -ErrorAction SilentlyContinue
                    $bindings = @(Get-WebBinding -Protocol https -ErrorAction SilentlyContinue)
                }
                foreach ($b in $bindings) {
                    $b.AddSslCertificate($hash, 'My')
                    Write-Verbose "Bound cert $hash to IIS binding $($b.bindingInformation)"
                }

                # 2) HTTP.SYS sslcert table on 0.0.0.0:443 (belt+braces; AddSslCertificate usually covers this)
                $appid = '{4dc3e181-e14b-4a21-b022-59fc669b0914}'  # IIS application id
                & netsh http delete sslcert ipport=0.0.0.0:443 2>$null | Out-Null
                & netsh http add    sslcert ipport=0.0.0.0:443 certhash=$hash appid=$appid certstorename=MY | Out-Null

                # 3) TSGateway SSL cert (RDS:\ provider)
                Import-Module RemoteDesktopServices -ErrorAction Stop
                Set-Item 'RDS:\GatewayServer\SSLCertificate\Thumbprint' -Value $hash -Force

                # 4) Restart services so the new cert is picked up immediately
                Restart-Service W3SVC -Force -ErrorAction SilentlyContinue
                Restart-Service TSGateway -Force -ErrorAction SilentlyContinue
            }

            DependsOn = '[WindowsFeature]RDS-Gateway', '[WindowsFeature]RDS-Web-Access'
        }

        LocalConfigurationManager {
            RebootNodeIfNeeded = $true
            ActionAfterReboot  = 'ContinueConfiguration'
            ConfigurationMode  = 'ApplyOnly'
        }
    }
}

configuration RDSDeployment {
    param (
        [Parameter(Mandatory)] [PSCredential] $AdminCreds,
        [Parameter(Mandatory)] [string]       $ConnectionBroker,
        [Parameter(Mandatory)] [string]       $WebAccessServer,
        [Parameter(Mandatory)] [string]       $GatewayExternalFqdn,
        [Parameter(Mandatory)] [string]       $DomainName,
        [Parameter(Mandatory)] [int]          $NumberOfRdshInstances,
        [Parameter(Mandatory)] [string]       $SessionHostNamingPrefix,
        [string] $CollectionName     = 'DesktopCollection',
        [string] $CertificateSubject = '',
        [string] $RDUserGroup        = 'Domain Users',
        [string] $DomainJoinUserName = '',
        [string] $KeyVaultCertSecretUri = '',
        [string] $IdentityClientId      = '',
        # App Proxy external URL for Entra pre-authentication. Empty = the
        # public-LB path (no pre-auth); set by Tier 0 only when useAppProxy.
        [string] $PreAuthServerUrl      = ''
    )

    Import-DscResource -ModuleName PSDesiredStateConfiguration

    $sessionHostFqdns = @()
    for ($i = 1; $i -le $NumberOfRdshInstances; $i++) {
        $sessionHostFqdns += "{0}{1:D2}.{2}" -f $SessionHostNamingPrefix, $i, $DomainName
    }

    Node localhost {
        WindowsFeature RDS-Connection-Broker {
            Ensure = 'Present'
            Name   = 'RDS-Connection-Broker'
        }

        WindowsFeature RDS-Licensing {
            Ensure = 'Present'
            Name   = 'RDS-Licensing'
        }

        # Base RSAT-RDS-Tools only - it provides the RemoteDesktop PowerShell
        # module that every RDS Script resource below relies on. Do NOT set
        # IncludeAllSubFeature: that pulls in GUI snap-ins (RSAT-RDS-Gateway,
        # licensing-diagnosis UI) which need IIS UI packages that fail to
        # install with 0x800f0922 on the Azure-Edition image. Those consoles
        # are admin-only tooling the headless broker never uses, and forcing
        # them made the whole broker DSC apply fail.
        WindowsFeature RSAT-RDS-Tools {
            Ensure = 'Present'
            Name   = 'RSAT-RDS-Tools'
        }

        # The RDS Script resources below all run as $AdminCreds
        # (svc-domainjoin), which is a plain domain user. RDS deployment
        # cmdlets (New-RDSessionDeployment, Add-RDServer, Set-RDCertificate,
        # etc.) require local admin on every targeted machine. Make
        # svc-domainjoin a local admin on the broker first; the SessionHost
        # and Gateway configs do the same on their respective VMs.
        if (-not [string]::IsNullOrEmpty($DomainJoinUserName)) {
            $netbios   = ($DomainName -split '\.')[0]
            $principal = '{0}\{1}' -f $netbios, $DomainJoinUserName

            Group AddDeployAccountToAdmins {
                GroupName        = 'Administrators'
                Ensure           = 'Present'
                MembersToInclude = @($principal)
                DependsOn        = '[WindowsFeature]RDS-Connection-Broker'
            }
        }

        # ---------- RDS deployment (split into idempotent sub-steps) -----
        #
        # The old monolithic CreateRDSDeployment resource short-circuited on
        # the first call to Get-RDServer (which returns the broker after
        # New-RDSessionDeployment), so subsequent passes never added missing
        # roles or fixed collection settings. Worse, any transient failure
        # (e.g. a session host still rebooting) marked the whole resource
        # failed and BindRDSCertificates was skipped. Splitting each step
        # into its own resource with a precise TestScript means:
        #   - each step is independently retried on the next consistency pass
        #   - BindRDSCertificates only depends on step 1 (deployment exists)
        #   - the test condition for each step actually verifies *that step*
        # ------------------------------------------------------------------

        # Step 1: bootstrap the deployment (broker + web access + session hosts)
        Script Rds01_BootstrapDeployment {
            GetScript = { @{ Result = '' } }

            TestScript = {
                try {
                    Import-Module RemoteDesktop -ErrorAction Stop
                    $brokers = Get-RDServer -ConnectionBroker $using:ConnectionBroker -Role 'RDS-CONNECTION-BROKER' -ErrorAction SilentlyContinue
                    return ($null -ne $brokers -and $brokers.Count -gt 0)
                } catch {
                    return $false
                }
            }

            SetScript = {
                Import-Module RemoteDesktop
                New-RDSessionDeployment `
                    -ConnectionBroker $using:ConnectionBroker `
                    -WebAccessServer  $using:WebAccessServer `
                    -SessionHost      $using:sessionHostFqdns `
                    -Verbose
            }

            DependsOn            = '[WindowsFeature]RDS-Connection-Broker', '[WindowsFeature]RDS-Licensing'
            PsDscRunAsCredential = $AdminCreds
        }

        # Step 2: add the gateway role (also sets deployment.GatewayMode = Custom)
        Script Rds02_AddGatewayRole {
            GetScript = { @{ Result = '' } }

            TestScript = {
                try {
                    Import-Module RemoteDesktop -ErrorAction Stop
                    $gws = Get-RDServer -ConnectionBroker $using:ConnectionBroker -Role 'RDS-GATEWAY' -ErrorAction SilentlyContinue
                    return ($null -ne $gws -and $gws.Count -gt 0)
                } catch {
                    return $false
                }
            }

            SetScript = {
                Import-Module RemoteDesktop
                Add-RDServer `
                    -Server              $using:WebAccessServer `
                    -Role                'RDS-GATEWAY' `
                    -ConnectionBroker    $using:ConnectionBroker `
                    -GatewayExternalFqdn $using:GatewayExternalFqdn
            }

            DependsOn            = '[Script]Rds01_BootstrapDeployment'
            PsDscRunAsCredential = $AdminCreds
        }

        # Step 3: add the licensing role + set Per-User CALs (120-day grace
        # until the broker computer object is added to AD group
        # 'Terminal Server License Servers').
        Script Rds03_AddLicensingRole {
            GetScript = { @{ Result = '' } }

            TestScript = {
                try {
                    Import-Module RemoteDesktop -ErrorAction Stop
                    $ls = Get-RDServer -ConnectionBroker $using:ConnectionBroker -Role 'RDS-LICENSING' -ErrorAction SilentlyContinue
                    if ($null -eq $ls -or $ls.Count -eq 0) { return $false }
                    $cfg = Get-RDLicenseConfiguration -ConnectionBroker $using:ConnectionBroker -ErrorAction SilentlyContinue
                    return ($null -ne $cfg -and $cfg.Mode -eq 'PerUser')
                } catch {
                    return $false
                }
            }

            SetScript = {
                Import-Module RemoteDesktop
                $ls = Get-RDServer -ConnectionBroker $using:ConnectionBroker -Role 'RDS-LICENSING' -ErrorAction SilentlyContinue
                if ($null -eq $ls -or $ls.Count -eq 0) {
                    Add-RDServer `
                        -Server           $using:ConnectionBroker `
                        -Role             'RDS-LICENSING' `
                        -ConnectionBroker $using:ConnectionBroker
                }
                Set-RDLicenseConfiguration `
                    -LicenseServer    @($using:ConnectionBroker) `
                    -Mode             PerUser `
                    -ConnectionBroker $using:ConnectionBroker `
                    -Force
            }

            DependsOn            = '[Script]Rds01_BootstrapDeployment'
            PsDscRunAsCredential = $AdminCreds
        }

        # Step 4: route deployment through the gateway and cache credentials
        # so RD Web users aren't prompted for their password twice.
        Script Rds04_GatewayConfig {
            GetScript = { @{ Result = '' } }

            TestScript = {
                try {
                    Import-Module RemoteDesktop -ErrorAction Stop
                    $cfg = Get-RDDeploymentGatewayConfiguration -ConnectionBroker $using:ConnectionBroker -ErrorAction SilentlyContinue
                    if ($null -eq $cfg) { return $false }
                    return ($cfg.GatewayMode -eq 'Custom' -and $cfg.GatewayExternalFqdn -eq $using:GatewayExternalFqdn)
                } catch {
                    return $false
                }
            }

            SetScript = {
                Import-Module RemoteDesktop
                Set-RDDeploymentGatewayConfiguration `
                    -GatewayMode          Custom `
                    -GatewayExternalFqdn  $using:GatewayExternalFqdn `
                    -LogonMethod          Password `
                    -UseCachedCredentials $true `
                    -BypassLocal          $false `
                    -ConnectionBroker     $using:ConnectionBroker `
                    -Force
            }

            DependsOn            = '[Script]Rds02_AddGatewayRole'
            PsDscRunAsCredential = $AdminCreds
        }

        # Step 5: create the session collection.
        Script Rds05_CreateCollection {
            GetScript = { @{ Result = '' } }

            TestScript = {
                try {
                    Import-Module RemoteDesktop -ErrorAction Stop
                    $coll = Get-RDSessionCollection -CollectionName $using:CollectionName -ConnectionBroker $using:ConnectionBroker -ErrorAction SilentlyContinue
                    return ($null -ne $coll)
                } catch {
                    return $false
                }
            }

            SetScript = {
                Import-Module RemoteDesktop
                New-RDSessionCollection `
                    -CollectionName        $using:CollectionName `
                    -SessionHost           $using:sessionHostFqdns `
                    -CollectionDescription 'RDS Session Collection' `
                    -ConnectionBroker      $using:ConnectionBroker
            }

            DependsOn            = '[Script]Rds01_BootstrapDeployment'
            PsDscRunAsCredential = $AdminCreds
        }

        # Step 6: restrict the collection to a specific AD group.
        # Set-RDSessionCollectionConfiguration accepts DOMAIN\group.
        Script Rds06_RestrictCollectionUsers {
            GetScript = { @{ Result = '' } }

            TestScript = {
                if ([string]::IsNullOrEmpty($using:RDUserGroup)) { return $true }
                try {
                    Import-Module RemoteDesktop -ErrorAction Stop
                    $netbios            = ($using:DomainName -split '\.')[0]
                    $userGroupDownLevel = '{0}\{1}' -f $netbios, $using:RDUserGroup
                    $cfg = Get-RDSessionCollectionConfiguration -CollectionName $using:CollectionName -ConnectionBroker $using:ConnectionBroker -UserGroup -ErrorAction SilentlyContinue
                    if ($null -eq $cfg -or $null -eq $cfg.UserGroup) { return $false }
                    return ($cfg.UserGroup -contains $userGroupDownLevel)
                } catch {
                    return $false
                }
            }

            SetScript = {
                Import-Module RemoteDesktop
                $netbios            = ($using:DomainName -split '\.')[0]
                $userGroupDownLevel = '{0}\{1}' -f $netbios, $using:RDUserGroup

                Set-RDSessionCollectionConfiguration `
                    -CollectionName   $using:CollectionName `
                    -UserGroup        @($userGroupDownLevel) `
                    -ConnectionBroker $using:ConnectionBroker
            }

            DependsOn            = '[Script]Rds05_CreateCollection'
            PsDscRunAsCredential = $AdminCreds
        }

        # Step 7 (App Proxy only): require Microsoft Entra pre-authentication on
        # the collection, so the RD Web Client / native clients authenticate at
        # the application proxy external URL (Conditional Access + MFA) before
        # reaching the gateway. No-op while $PreAuthServerUrl is empty (the
        # default public-LB path), so this is safe to ship before cutover.
        Script Rds07_PreAuthCustomRdp {
            GetScript = { @{ Result = '' } }

            TestScript = {
                if ([string]::IsNullOrEmpty($using:PreAuthServerUrl)) { return $true }
                try {
                    Import-Module RemoteDesktop -ErrorAction Stop
                    $cfg = Get-RDSessionCollectionConfiguration -CollectionName $using:CollectionName -ConnectionBroker $using:ConnectionBroker -CustomRdpProperty -ErrorAction SilentlyContinue
                    if ($null -eq $cfg -or [string]::IsNullOrEmpty($cfg.CustomRdpProperty)) { return $false }
                    return ($cfg.CustomRdpProperty -match 'require pre-authentication:i:1')
                } catch {
                    return $false
                }
            }

            SetScript = {
                Import-Module RemoteDesktop
                $rdp = "pre-authentication server address:s:{0}`nrequire pre-authentication:i:1" -f $using:PreAuthServerUrl
                Set-RDSessionCollectionConfiguration `
                    -CollectionName    $using:CollectionName `
                    -CustomRdpProperty $rdp `
                    -ConnectionBroker  $using:ConnectionBroker
            }

            DependsOn            = '[Script]Rds05_CreateCollection'
            PsDscRunAsCredential = $AdminCreds
        }

        # Bind the KV-delivered TLS cert to all four RDS roles
        # (RDGateway, RDWebAccess, RDPublishing, RDRedirector). Only depends
        # on step 1: even if some downstream step transiently fails, the cert
        # binding still gets attempted on the next consistency pass.
        Script BindRDSCertificates {
            GetScript = { @{ Result = '' } }

            TestScript = {
                if ([string]::IsNullOrEmpty($using:CertificateSubject)) { return $true }
                try {
                    Import-Module RemoteDesktop -ErrorAction Stop
                    $current = Get-RDCertificate -ConnectionBroker $using:ConnectionBroker -ErrorAction SilentlyContinue
                    if ($null -eq $current) { return $false }
                    # Match on Subject only - NOT Level. A self-signed cert binds
                    # as Level='NotTrusted', so requiring 'Trusted' would mean the
                    # resource never reports converged and re-runs every pass.
                    # Roles still NotConfigured have an empty Subject and won't
                    # match, so subject + count>=4 is the correct convergence test.
                    $matched = @($current | Where-Object {
                        $_.Subject -like "*$using:CertificateSubject*"
                    })
                    return ($matched.Count -ge 4)
                } catch {
                    return $false
                }
            }

            SetScript = {
                Import-Module RemoteDesktop

                $subject  = $using:CertificateSubject
                $kvUri    = $using:KeyVaultCertSecretUri
                $clientId = $using:IdentityClientId

                $pfxPath    = Join-Path $env:TEMP ("rds-cert-{0}.pfx" -f ([guid]::NewGuid().ToString('N')))
                $pfxPwdText = [guid]::NewGuid().ToString('N') + 'A1!'
                $pfxPwd     = ConvertTo-SecureString -String $pfxPwdText -Force -AsPlainText

                try {
                    if (-not [string]::IsNullOrEmpty($kvUri)) {
                        # Preferred path: pull the cert straight from Key Vault via
                        # the VM's user-assigned managed identity. The Key Vault VM
                        # extension v4.0+ installs the LOCAL private key as
                        # NON-exportable (CNG), so Export-PfxCertificate from
                        # LocalMachine\My fails with "Cannot export non-exportable
                        # private key". The copy in Key Vault is still exportable,
                        # so fetch the PKCS12 secret from there and re-wrap it with
                        # a transient password (Set-RDCertificate needs a PFX file
                        # plus password).
                        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

                        $tokenUri = 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net'
                        if (-not [string]::IsNullOrEmpty($clientId)) { $tokenUri += "&client_id=$clientId" }
                        $token = (Invoke-RestMethod -Headers @{ Metadata = 'true' } -Uri $tokenUri).access_token

                        $sep    = if ($kvUri -match '\?') { '&' } else { '?' }
                        $secUri = "$kvUri$($sep)api-version=7.4"
                        $secret = (Invoke-RestMethod -Headers @{ Authorization = "Bearer $token" } -Uri $secUri).value
                        if ([string]::IsNullOrEmpty($secret)) {
                            throw "Key Vault returned an empty secret for '$kvUri'."
                        }

                        $bytes = [Convert]::FromBase64String($secret)
                        $col   = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
                        $col.Import($bytes, $null, [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)
                        [IO.File]::WriteAllBytes($pfxPath, $col.Export('Pkcs12', $pfxPwdText))
                        Write-Verbose "BindRDSCertificates: fetched cert from Key Vault ($kvUri)."
                    } else {
                        # Legacy fallback: export the cert from LocalMachine\My.
                        # Only works when the private key is exportable (Key Vault
                        # VM extension < 4.0). Retained for back-compat.
                        $cert = $null
                        for ($attempt = 1; $attempt -le 5; $attempt++) {
                            $cert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
                                Where-Object { $_.Subject -like "*$subject*" -and $_.HasPrivateKey } |
                                Sort-Object NotAfter -Descending |
                                Select-Object -First 1
                            if ($null -ne $cert) { break }
                            Write-Verbose "BindRDSCertificates: cert not found yet (attempt $attempt/5), waiting 15s."
                            Start-Sleep -Seconds 15
                        }
                        if ($null -eq $cert) {
                            throw "Certificate with subject containing '$subject' not found in LocalMachine\My after 5 attempts, and no KeyVaultCertSecretUri was supplied."
                        }
                        Export-PfxCertificate -Cert $cert.PSPath -FilePath $pfxPath -Password $pfxPwd -Force | Out-Null
                    }

                    $failed = @()
                    foreach ($role in 'RDGateway','RDWebAccess','RDPublishing','RDRedirector') {
                        try {
                            Set-RDCertificate `
                                -Role             $role `
                                -ImportPath       $pfxPath `
                                -Password         $pfxPwd `
                                -ConnectionBroker $using:ConnectionBroker `
                                -Force
                            Write-Verbose "Bound certificate to role: $role"
                        } catch {
                            $failed += $role
                            Write-Warning "Failed to bind certificate to role $role`: $_"
                        }
                    }

                    if ($failed.Count -gt 0) {
                        # Surface the failure to DSC so the resource shows
                        # un-converged; next consistency pass will retry just
                        # this Script resource (steps 1-6 won't re-run if
                        # they've already converged).
                        throw "Set-RDCertificate failed for roles: $($failed -join ', ')"
                    }
                } finally {
                    if (Test-Path $pfxPath) { Remove-Item $pfxPath -Force }
                    [System.GC]::Collect()
                }
            }

            DependsOn            = '[Script]Rds01_BootstrapDeployment'
            PsDscRunAsCredential = $AdminCreds
        }

        LocalConfigurationManager {
            RebootNodeIfNeeded = $true
            ActionAfterReboot  = 'ContinueConfiguration'
            ConfigurationMode  = 'ApplyOnly'
        }
    }
}
