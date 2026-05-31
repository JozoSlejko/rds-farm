param namePrefix string
param location string
param gatewayDnsLabelPrefix string
param availabilityZones array
param tags object

var lbName = '${namePrefix}-gw-lb'

resource publicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: '${namePrefix}-gw-pip'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  zones: availabilityZones
  properties: {
    publicIPAddressVersion: 'IPv4'
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: gatewayDnsLabelPrefix
    }
  }
}

resource lb 'Microsoft.Network/loadBalancers@2024-05-01' = {
  name: lbName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    frontendIPConfigurations: [
      {
        name: 'LBFE'
        properties: {
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'gateway-pool'
      }
    ]
    probes: [
      {
        name: 'httpsProbe'
        properties: {
          protocol: 'Tcp'
          port: 443
          intervalInSeconds: 5
          numberOfProbes: 2
        }
      }
    ]
    loadBalancingRules: [
      {
        name: 'https'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', lbName, 'LBFE')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', lbName, 'gateway-pool')
          }
          protocol: 'Tcp'
          frontendPort: 443
          backendPort: 443
          idleTimeoutInMinutes: 5
          loadDistribution: 'SourceIPProtocol'
          enableTcpReset: true
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', lbName, 'httpsProbe')
          }
        }
      }
      {
        name: 'udp'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', lbName, 'LBFE')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', lbName, 'gateway-pool')
          }
          protocol: 'Udp'
          frontendPort: 3391
          backendPort: 3391
          idleTimeoutInMinutes: 5
          loadDistribution: 'SourceIPProtocol'
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', lbName, 'httpsProbe')
          }
        }
      }
    ]
  }
}

output backendPoolId string = lb.properties.backendAddressPools[0].id
output gatewayFqdn string = publicIp.properties.dnsSettings.fqdn
