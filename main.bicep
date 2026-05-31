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

@secure()
@description('SAS token (including leading "?") for artifactsLocation. Leave empty if container is public or uses MSI auth.')
param artifactsLocationSasToken string = ''

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

@description('Public FQDN clients type into Remote Desktop / RD Web (and what the cert Subject/SAN must match). Leave empty to use the LB DNS-label hostname (`<dnsLabel>.<region>.cloudapp.azure.com`) — only viable with a self-signed cert because a public CA will refuse to issue for `cloudapp.azure.com`. For production set this to a hostname you control, e.g. `rds.contoso.com`, and create a CNAME from that hostname to the LB FQDN after the first deploy.')
param publicGatewayFqdn string = ''

var namePrefix = 'rds'
var tags = {
  workload: 'RemoteDesktopServices'
  environment: 'prod'
}

module network 'modules/network.bicep' = {
  scope: resourceGroup(existingVnetResourceGroup)
  params: {
    vnetName: existingVnetName
    rdsSubnetName: existingRdsSubnetName
    allowedClientSourceAddressPrefixes: allowedClientSourceAddressPrefixes
    namePrefix: namePrefix
    location: location
    tags: tags
  }
}

module loadbalancer 'modules/loadbalancer.bicep' = {
  params: {
    namePrefix: namePrefix
    location: location
    gatewayDnsLabelPrefix: gatewayDnsLabelPrefix
    availabilityZones: availabilityZones
    tags: tags
  }
}

module bastion 'modules/bastion.bicep' = if (deployBastion) {
  params: {
    namePrefix: namePrefix
    location: location
    vnetName: existingVnetName
    vnetResourceGroup: existingVnetResourceGroup
    bastionSubnetName: bastionSubnetName
    tags: tags
  }
}

module identity 'modules/identity.bicep' = if (enableCertificateBinding) {
  params: {
    namePrefix: namePrefix
    location: location
    keyVaultName: keyVaultName
    keyVaultResourceGroup: keyVaultResourceGroup
    tags: tags
  }
}

var identityIdForVms = enableCertificateBinding ? identity!.outputs.identityId : ''
var identityClientIdForVms = enableCertificateBinding ? identity!.outputs.identityClientId : ''

// Public hostname users type and the cert validates against. Falls back to the
// Azure-managed LB FQDN for lab/self-signed deployments.
var effectiveGatewayFqdn = empty(publicGatewayFqdn) ? loadbalancer.outputs.gatewayFqdn : publicGatewayFqdn

module gatewayVm 'modules/vm.bicep' = {
  params: {
    vmName: '${namePrefix}-gw-01'
    location: location
    vmSize: vmSize
    windowsSku: windowsSku
    subnetId: network.outputs.rdsSubnetId
    nsgId: network.outputs.nsgId
    backendPoolId: loadbalancer.outputs.backendPoolId
    adDnsServerIp: adDnsServerIp
    localAdminUserName: localAdminUserName
    localAdminPassword: localAdminPassword
    domainJoinUserName: domainJoinUserName
    domainJoinPassword: domainJoinPassword
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
  params: {
    vmName: '${namePrefix}-cb-01'
    location: location
    vmSize: vmSize
    windowsSku: windowsSku
    subnetId: network.outputs.rdsSubnetId
    nsgId: network.outputs.nsgId
    adDnsServerIp: adDnsServerIp
    localAdminUserName: localAdminUserName
    localAdminPassword: localAdminPassword
    domainJoinUserName: domainJoinUserName
    domainJoinPassword: domainJoinPassword
    adDomainName: adDomainName
    zone: availabilityZones[1]
    tags: tags
    userAssignedIdentityId: identityIdForVms
    userAssignedIdentityClientId: identityClientIdForVms
    installCertFromKeyVault: enableCertificateBinding
    keyVaultCertSecretUri: keyVaultCertSecretUri
  }
}

module sessionHosts 'modules/vm.bicep' = [for i in range(0, sessionHostCount): {
  name: 'deploy-rdsh-${i}'
  params: {
    vmName: '${sessionHostNamingPrefix}${padLeft(i + 1, 2, '0')}'
    location: location
    vmSize: vmSize
    windowsSku: windowsSku
    subnetId: network.outputs.rdsSubnetId
    nsgId: network.outputs.nsgId
    adDnsServerIp: adDnsServerIp
    localAdminUserName: localAdminUserName
    localAdminPassword: localAdminPassword
    domainJoinUserName: domainJoinUserName
    domainJoinPassword: domainJoinPassword
    adDomainName: adDomainName
    zone: availabilityZones[i % length(availabilityZones)]
    tags: tags
  }
}]

module gatewayDsc 'modules/dsc.bicep' = {
  params: {
    vmName: gatewayVm.outputs.vmName
    location: location
    configurationFunction: 'Configuration.ps1\\Gateway'
    configurationProperties: {
      DomainName: adDomainName
      RDUserGroup: rdsAccessGroup
    }
    protectedItems: {
      AdminCreds: {
        UserName: '${adDomainName}\\${domainJoinUserName}'
        Password: domainJoinPassword
      }
    }
    artifactsLocation: artifactsLocation
    artifactsLocationSasToken: artifactsLocationSasToken
  }
}

module sessionHostDsc 'modules/dsc.bicep' = [for i in range(0, sessionHostCount): {
  name: 'dsc-rdsh-${i}'
  params: {
    vmName: sessionHosts[i].outputs.vmName
    location: location
    configurationFunction: 'Configuration.ps1\\SessionHost'
    configurationProperties: {}
    artifactsLocation: artifactsLocation
    artifactsLocationSasToken: artifactsLocationSasToken
  }
}]

module brokerDsc 'modules/dsc.bicep' = {
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
    }
    protectedItems: {
      AdminCreds: {
        UserName: '${adDomainName}\\${domainJoinUserName}'
        Password: domainJoinPassword
      }
    }
    artifactsLocation: artifactsLocation
    artifactsLocationSasToken: artifactsLocationSasToken
  }
}

output gatewayFqdn string = loadbalancer.outputs.gatewayFqdn
output publicGatewayFqdn string = effectiveGatewayFqdn
output rdWebUrl string = 'https://${effectiveGatewayFqdn}/RDWeb'
output bastionName string = deployBastion ? bastion!.outputs.bastionName : ''
