targetScope = 'resourceGroup'

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Existing VNet name where the RDS VMs will be deployed.')
param existingVnetName string

@description('Resource group containing the existing VNet.')
param existingVnetResourceGroup string

@description('Existing subnet name for RDS VMs (must be reachable to your AD DCs).')
param existingRdsSubnetName string

@description('Existing AD domain FQDN, e.g. contoso.com.')
param adDomainName string

@description('Private IP of one of your AD DNS servers.')
param adDnsServerIp string

@description('Domain-join admin username (must already exist in AD with rights to join VMs).')
param domainJoinUserName string

@secure()
@description('Domain-join admin password.')
param domainJoinPassword string

@description('Optional. Distinguished Name of the OU to join the RDS VMs into (e.g. "OU=RDS,OU=Servers,DC=contoso,DC=local"). The domain-join service account needs delegated rights to create/join machine objects in that OU. Leave empty to use the default Computers container.')
param domainJoinOuPath string = ''

@description('Local admin username for the VMs.')
param localAdminUserName string

@secure()
@description('Local admin password for the VMs.')
param localAdminPassword string

@description('Number of RD Session Host VMs to deploy.')
@minValue(1)
@maxValue(20)
param sessionHostCount int = 2

@description('VM size for all RDS role VMs.')
param vmSize string = 'Standard_D4s_v5'

@description('Windows Server image SKU.')
@allowed([
  '2022-datacenter-azure-edition'
  '2025-datacenter-azure-edition'
])
param windowsSku string = '2022-datacenter-azure-edition'

@description('CIDR(s) allowed to reach RD Gateway from the internet (HTTPS/UDP 3391). Use your office/VPN egress IPs only.')
param allowedClientSourceAddressPrefixes array

@description('Name of the governance NSG already attached to the RDS subnet (landing-zone / Azure Policy managed), co-located in existingVnetResourceGroup. The farm writes the client allow-list (TCP 443 / UDP 3391) as named rules on this NSG instead of attaching its own NIC NSG. Tier 0 discovers and sets this. Leave empty to skip writing rules.')
param subnetNsgName string = ''

@description('DNS label prefix for the gateway public IP. Final FQDN: <prefix>.<region>.cloudapp.azure.com')
param gatewayDnsLabelPrefix string

@description('Deploy an Azure Bastion host for admin access. Requires an AzureBastionSubnet in the VNet.')
param deployBastion bool = true

@description('Name of the AzureBastionSubnet (only used when deployBastion = true).')
param bastionSubnetName string = 'AzureBastionSubnet'

@description('Availability zones to spread VMs across.')
param availabilityZones array = ['1', '2', '3']

@description('Base URL of the storage container holding Configuration.zip (no trailing file name).')
param artifactsLocation string

@description('Name of the artifacts storage account (used by the identity module to grant Storage Blob Data Reader on the SA so the DSC extension can pull the blob with managed-identity auth).')
param artifactsStorageAccountName string

@description('Resource group of the artifacts storage account.')
param artifactsStorageAccountResourceGroup string

@description('Naming prefix for session host VMs (must match what the broker DSC will look up).')
param sessionHostNamingPrefix string = 'rds-sh-'

@description('RDS session collection name.')
param collectionName string = 'DesktopCollection'

@description('AD security group (sAMAccountName) allowed to sign in to the session collection and connect through the RD Gateway. Defaults to Domain Users for quick testing.')
param rdsAccessGroup string = 'Domain Users'

@description('Set to true to enable Key Vault cert binding for RDS roles.')
param enableCertificateBinding bool = false

@description('Name of the existing Key Vault containing the RDS certificate.')
param keyVaultName string = ''

@description('Resource group of the existing Key Vault.')
param keyVaultResourceGroup string = ''

@description('Full Key Vault secret URI for the certificate, e.g. https://myvault.vault.azure.net/secrets/rdscert. The cert policy MUST have exportable=true.')
param keyVaultCertSecretUri string = ''

@description('Subject (or substring) used by the broker DSC to locate the cert in LocalMachine\\My, e.g. "CN=rdsgw.contoso.com".')
param certificateSubject string = ''

@description('Opaque marker forwarded to every CSE/DSC extension as properties.forceUpdateTag. Causes the platform to re-run Bootstrap.ps1 (and therefore re-apply whatever Configuration.zip is currently in the artifacts SA) on every deploy. Defaults to utcNow() so each `az deployment group create` mutates the value; pass a stable string (e.g. a release tag) only if you explicitly want CSE to stay quiescent.')
param dscRevision string = utcNow()

@description('Public FQDN clients type into Remote Desktop / RD Web (and what the cert Subject/SAN must match). Leave empty to use the LB DNS-label hostname (`<dnsLabel>.<region>.cloudapp.azure.com`) — only viable with a self-signed cert because a public CA will refuse to issue for `cloudapp.azure.com`. For production set this to a hostname you control, e.g. `rds.contoso.com`, and create a CNAME from that hostname to the LB FQDN after the first deploy.')
param publicGatewayFqdn string = ''

@description('Publish through Microsoft Entra application proxy instead of a public load balancer. When true the template skips the public IP + load balancer, omits the internet-facing inbound NSG rules, deploys an application proxy connector VM, and configures the gateway for the App Proxy external FQDN with Entra pre-authentication.')
param useAppProxy bool = false

@description('External FQDN published by Entra application proxy (the gateway external FQDN and pre-auth URL when useAppProxy = true), e.g. rds.slejco.com. Required when useAppProxy = true.')
param appProxyExternalFqdn string = ''

var namePrefix = 'rds'
var tags = {
  workload: 'RemoteDesktopServices'
  environment: 'prod'
}

module network 'modules/network.bicep' = {
  name: 'network-core'
  scope: resourceGroup(existingVnetResourceGroup)
  params: {
    vnetName: existingVnetName
    rdsSubnetName: existingRdsSubnetName
    allowedClientSourceAddressPrefixes: allowedClientSourceAddressPrefixes
    subnetNsgName: subnetNsgName
    // No internet-facing inbound rules when behind application proxy.
    writeInternetInboundRules: !useAppProxy
  }
}

// Public ingress (public IP + Standard LB). Skipped when publishing through
// Entra application proxy - the connector dials out, so there is no public LB.
module loadbalancer 'modules/loadbalancer.bicep' = if (!useAppProxy) {
  name: 'loadbalancer-core'
  params: {
    namePrefix: namePrefix
    location: location
    gatewayDnsLabelPrefix: gatewayDnsLabelPrefix
    availabilityZones: availabilityZones
    tags: tags
  }
}

module bastion 'modules/bastion.bicep' = if (deployBastion) {
  name: 'bastion-core'
  params: {
    namePrefix: namePrefix
    location: location
    vnetName: existingVnetName
    vnetResourceGroup: existingVnetResourceGroup
    bastionSubnetName: bastionSubnetName
    tags: tags
  }
}

module identity 'modules/identity.bicep' = {
  name: 'identity-core'
  params: {
    namePrefix: namePrefix
    location: location
    tags: tags
    artifactsStorageAccountName: artifactsStorageAccountName
    artifactsStorageAccountResourceGroup: artifactsStorageAccountResourceGroup
    enableKeyVaultRole: enableCertificateBinding
    keyVaultName: keyVaultName
    keyVaultResourceGroup: keyVaultResourceGroup
  }
}

// Every VM gets the UAMI (used at minimum for blob auth in the DSC extension).
var identityIdForVms = identity.outputs.identityId
var identityClientIdForVms = identity.outputs.identityClientId

// Public hostname users type and the cert validates against. With application
// proxy it's the external FQDN; otherwise the vanity FQDN or the LB hostname.
var effectiveGatewayFqdn = useAppProxy
  ? appProxyExternalFqdn
  : (empty(publicGatewayFqdn) ? loadbalancer!.outputs.gatewayFqdn : publicGatewayFqdn)

module gatewayVm 'modules/vm.bicep' = {
  name: 'vm-gateway-01'
  params: {
    vmName: '${namePrefix}-gw-01'
    location: location
    vmSize: vmSize
    windowsSku: windowsSku
    subnetId: network.outputs.rdsSubnetId
    backendPoolId: useAppProxy ? '' : loadbalancer!.outputs.backendPoolId
    adDnsServerIp: adDnsServerIp
    localAdminUserName: localAdminUserName
    localAdminPassword: localAdminPassword
    domainJoinUserName: domainJoinUserName
    domainJoinPassword: domainJoinPassword
    domainJoinOuPath: domainJoinOuPath
    adDomainName: adDomainName
    zone: availabilityZones[0]
    tags: tags
    userAssignedIdentityId: identityIdForVms
    userAssignedIdentityClientId: identityClientIdForVms
    installCertFromKeyVault: enableCertificateBinding
    keyVaultCertSecretUri: keyVaultCertSecretUri
  }
}

module brokerVm 'modules/vm.bicep' = {
  name: 'vm-broker-01'
  params: {
    vmName: '${namePrefix}-cb-01'
    location: location
    vmSize: vmSize
    windowsSku: windowsSku
    subnetId: network.outputs.rdsSubnetId
    adDnsServerIp: adDnsServerIp
    localAdminUserName: localAdminUserName
    localAdminPassword: localAdminPassword
    domainJoinUserName: domainJoinUserName
    domainJoinPassword: domainJoinPassword
    domainJoinOuPath: domainJoinOuPath
    adDomainName: adDomainName
    zone: availabilityZones[1]
    tags: tags
    userAssignedIdentityId: identityIdForVms
    userAssignedIdentityClientId: identityClientIdForVms
    installCertFromKeyVault: enableCertificateBinding
    keyVaultCertSecretUri: keyVaultCertSecretUri
  }
}

module sessionHosts 'modules/vm.bicep' = [
  for i in range(0, sessionHostCount): {
    name: 'deploy-rdsh-${i}'
    params: {
      vmName: '${sessionHostNamingPrefix}${padLeft(i + 1, 2, '0')}'
      location: location
      vmSize: vmSize
      windowsSku: windowsSku
      subnetId: network.outputs.rdsSubnetId
      adDnsServerIp: adDnsServerIp
      localAdminUserName: localAdminUserName
      localAdminPassword: localAdminPassword
      domainJoinUserName: domainJoinUserName
      domainJoinPassword: domainJoinPassword
      domainJoinOuPath: domainJoinOuPath
      adDomainName: adDomainName
      zone: availabilityZones[i % length(availabilityZones)]
      tags: tags
      userAssignedIdentityId: identityIdForVms
      userAssignedIdentityClientId: identityClientIdForVms
    }
  }
]

// Entra application proxy connector VM (outbound-only). Deployed only in App
// Proxy mode. The connector MSI install + registration is an admin step (it
// needs an interactive Entra token) - see docs/app-proxy.md.
module connectorVm 'modules/vm.bicep' = if (useAppProxy) {
  name: 'vm-connector-01'
  params: {
    vmName: '${namePrefix}-apc-01'
    location: location
    vmSize: vmSize
    windowsSku: windowsSku
    subnetId: network.outputs.rdsSubnetId
    backendPoolId: ''
    adDnsServerIp: adDnsServerIp
    localAdminUserName: localAdminUserName
    localAdminPassword: localAdminPassword
    domainJoinUserName: domainJoinUserName
    domainJoinPassword: domainJoinPassword
    domainJoinOuPath: domainJoinOuPath
    adDomainName: adDomainName
    zone: availabilityZones[0]
    tags: tags
    userAssignedIdentityId: identityIdForVms
    userAssignedIdentityClientId: identityClientIdForVms
    installCertFromKeyVault: false
  }
}

module gatewayDsc 'modules/dsc.bicep' = {
  name: 'dsc-gateway-01'
  params: {
    vmName: gatewayVm.outputs.vmName
    location: location
    configurationFunction: 'Configuration.ps1\\Gateway'
    configurationProperties: {
      DomainName: adDomainName
      RDUserGroup: rdsAccessGroup
      CertificateSubject: certificateSubject
      DomainJoinUserName: domainJoinUserName
    }
    protectedItems: {
      AdminCreds: {
        UserName: '${adDomainName}\\${domainJoinUserName}'
        Password: domainJoinPassword
      }
    }
    artifactsLocation: artifactsLocation
    userAssignedIdentityClientId: identityClientIdForVms
    forceUpdateTag: dscRevision
  }
}

module sessionHostDsc 'modules/dsc.bicep' = [
  for i in range(0, sessionHostCount): {
    name: 'dsc-rdsh-${i}'
    params: {
      vmName: sessionHosts[i].outputs.vmName
      location: location
      configurationFunction: 'Configuration.ps1\\SessionHost'
      configurationProperties: {
        DomainName: adDomainName
        DomainJoinUserName: domainJoinUserName
      }
      artifactsLocation: artifactsLocation
      userAssignedIdentityClientId: identityClientIdForVms
      forceUpdateTag: dscRevision
    }
  }
]

module brokerDsc 'modules/dsc.bicep' = {
  name: 'dsc-broker-01'
  dependsOn: [
    gatewayDsc
    sessionHostDsc
  ]
  params: {
    vmName: brokerVm.outputs.vmName
    location: location
    configurationFunction: 'Configuration.ps1\\RDSDeployment'
    configurationProperties: {
      ConnectionBroker: '${brokerVm.outputs.vmName}.${adDomainName}'
      WebAccessServer: '${gatewayVm.outputs.vmName}.${adDomainName}'
      GatewayExternalFqdn: effectiveGatewayFqdn
      DomainName: adDomainName
      NumberOfRdshInstances: sessionHostCount
      SessionHostNamingPrefix: sessionHostNamingPrefix
      CollectionName: collectionName
      CertificateSubject: certificateSubject
      RDUserGroup: rdsAccessGroup
      DomainJoinUserName: domainJoinUserName
      // Lets BindRDSCertificates fetch the still-exportable PFX straight from
      // Key Vault via the VM's UAMI. The KV VM extension v4.0+ installs the
      // local private key as non-exportable, so export-from-store fails.
      KeyVaultCertSecretUri: keyVaultCertSecretUri
      IdentityClientId: identityClientIdForVms
      // Activates the gated Rds07 pre-auth step only in App Proxy mode.
      PreAuthServerUrl: useAppProxy ? 'https://${appProxyExternalFqdn}/' : ''
    }
    protectedItems: {
      AdminCreds: {
        UserName: '${adDomainName}\\${domainJoinUserName}'
        Password: domainJoinPassword
      }
    }
    artifactsLocation: artifactsLocation
    userAssignedIdentityClientId: identityClientIdForVms
    forceUpdateTag: dscRevision
  }
}

output gatewayFqdn string = useAppProxy ? '' : loadbalancer!.outputs.gatewayFqdn
output publicGatewayFqdn string = effectiveGatewayFqdn
output rdWebUrl string = 'https://${effectiveGatewayFqdn}/RDWeb'
output bastionName string = deployBastion ? bastion!.outputs.bastionName : ''
output connectorVmName string = useAppProxy ? connectorVm!.outputs.vmName : ''
