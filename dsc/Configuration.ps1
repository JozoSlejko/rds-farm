configuration SessionHost {
    Import-DscResource -ModuleName PSDesiredStateConfiguration

    Node localhost {
        WindowsFeature RDS-RD-Server {
            Ensure = 'Present'
            Name   = 'RDS-RD-Server'
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
        [Parameter(Mandatory)] [PSCredential] $AdminCreds,
        [Parameter(Mandatory)] [string]       $DomainName,
        [string] $RDUserGroup = 'Domain Users'
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

        # Without a CAP and a RAP the RD Gateway is installed but rejects every
        # incoming session ("Your computer can't connect to the Remote Desktop
        # Gateway server"). We create one of each, scoped to $RDUserGroup, so
        # the test user can connect through the gateway out of the box.
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

            DependsOn            = '[WindowsFeature]RDS-Gateway'
            PsDscRunAsCredential = $AdminCreds
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
        [string] $RDUserGroup        = 'Domain Users'
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

        WindowsFeature RSAT-RDS-Tools {
            Ensure               = 'Present'
            Name                 = 'RSAT-RDS-Tools'
            IncludeAllSubFeature = $true
        }

        Script CreateRDSDeployment {
            GetScript = { @{ Result = '' } }

            TestScript = {
                try {
                    Import-Module RemoteDesktop -ErrorAction Stop
                    $servers = Get-RDServer -ConnectionBroker $using:ConnectionBroker -ErrorAction SilentlyContinue
                    return ($null -ne $servers -and $servers.Count -gt 0)
                } catch {
                    return $false
                }
            }

            SetScript = {
                Import-Module RemoteDesktop

                # 1. Create the deployment (broker + web access + session hosts)
                New-RDSessionDeployment `
                    -ConnectionBroker $using:ConnectionBroker `
                    -WebAccessServer  $using:WebAccessServer `
                    -SessionHost      $using:sessionHostFqdns `
                    -Verbose

                # 2. Add the gateway role (also sets deployment.GatewayMode = Custom)
                Add-RDServer `
                    -Server              $using:WebAccessServer `
                    -Role                'RDS-GATEWAY' `
                    -ConnectionBroker    $using:ConnectionBroker `
                    -GatewayExternalFqdn $using:GatewayExternalFqdn

                # 3. Add the licensing role + set Per-User CALs (120-day grace
                #    until the broker computer object is added to AD group
                #    'Terminal Server License Servers').
                Add-RDServer `
                    -Server           $using:ConnectionBroker `
                    -Role             'RDS-LICENSING' `
                    -ConnectionBroker $using:ConnectionBroker

                Set-RDLicenseConfiguration `
                    -LicenseServer    @($using:ConnectionBroker) `
                    -Mode             PerUser `
                    -ConnectionBroker $using:ConnectionBroker `
                    -Force

                # 4. Explicitly configure the deployment to route through the
                #    gateway and cache credentials so RD Web users aren't
                #    prompted for their password twice.
                Set-RDDeploymentGatewayConfiguration `
                    -GatewayMode          Custom `
                    -GatewayExternalFqdn  $using:GatewayExternalFqdn `
                    -LogonMethod          Password `
                    -UseCachedCredentials $true `
                    -BypassLocal          $false `
                    -ConnectionBroker     $using:ConnectionBroker `
                    -Force

                # 5. Create the session collection
                New-RDSessionCollection `
                    -CollectionName        $using:CollectionName `
                    -SessionHost           $using:sessionHostFqdns `
                    -CollectionDescription 'RDS Session Collection' `
                    -ConnectionBroker      $using:ConnectionBroker

                # 6. Restrict the collection to a specific AD group.
                #    Set-RDSessionCollectionConfiguration accepts DOMAIN\group.
                if (-not [string]::IsNullOrEmpty($using:RDUserGroup)) {
                    $netbios            = ($using:DomainName -split '\.')[0]
                    $userGroupDownLevel = '{0}\{1}' -f $netbios, $using:RDUserGroup

                    Set-RDSessionCollectionConfiguration `
                        -CollectionName   $using:CollectionName `
                        -UserGroup        @($userGroupDownLevel) `
                        -ConnectionBroker $using:ConnectionBroker
                }
            }

            DependsOn            = '[WindowsFeature]RDS-Connection-Broker', '[WindowsFeature]RDS-Licensing'
            PsDscRunAsCredential = $AdminCreds
        }

        Script BindRDSCertificates {
            GetScript = { @{ Result = '' } }

            TestScript = {
                if ([string]::IsNullOrEmpty($using:CertificateSubject)) { return $true }
                try {
                    Import-Module RemoteDesktop -ErrorAction Stop
                    $current = Get-RDCertificate -ConnectionBroker $using:ConnectionBroker -ErrorAction SilentlyContinue
                    if ($null -eq $current) { return $false }
                    $matched = @($current | Where-Object {
                        $_.Level -eq 'Trusted' -and $_.Subject -like "*$using:CertificateSubject*"
                    })
                    return ($matched.Count -ge 4)
                } catch {
                    return $false
                }
            }

            SetScript = {
                Import-Module RemoteDesktop

                $subject = $using:CertificateSubject

                $cert = Get-ChildItem Cert:\LocalMachine\My |
                    Where-Object { $_.Subject -like "*$subject*" -and $_.HasPrivateKey } |
                    Sort-Object NotAfter -Descending |
                    Select-Object -First 1

                if ($null -eq $cert) {
                    throw "Certificate with subject containing '$subject' not found in LocalMachine\My. " +
                          "Verify the Key Vault VM extension has run on the broker and that the cert policy has exportable=true."
                }

                $pfxPath    = Join-Path $env:TEMP ("rds-cert-{0}.pfx" -f ([guid]::NewGuid().ToString('N')))
                $pfxPwdText = [guid]::NewGuid().ToString('N') + 'A1!'
                $pfxPwd     = ConvertTo-SecureString -String $pfxPwdText -Force -AsPlainText

                try {
                    Export-PfxCertificate -Cert $cert.PSPath -FilePath $pfxPath -Password $pfxPwd -Force | Out-Null

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
                            Write-Warning "Failed to bind certificate to role $role`: $_"
                        }
                    }
                } finally {
                    if (Test-Path $pfxPath) { Remove-Item $pfxPath -Force }
                    [System.GC]::Collect()
                }
            }

            DependsOn            = '[Script]CreateRDSDeployment'
            PsDscRunAsCredential = $AdminCreds
        }

        LocalConfigurationManager {
            RebootNodeIfNeeded = $true
            ActionAfterReboot  = 'ContinueConfiguration'
            ConfigurationMode  = 'ApplyOnly'
        }
    }
}
