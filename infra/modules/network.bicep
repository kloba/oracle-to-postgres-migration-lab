// -----------------------------------------------------------------------------
// network.bicep
//
// The lab network. One VNet, four subnets, one NSG per workload subnet, and the
// private DNS zone that Azure Database for PostgreSQL flexible server needs when
// it is injected into a delegated subnet (private access mode).
//
// Topology:
//
//   snet-oracle   10.42.1.0/24   the "on-premises" Oracle server (no public IP)
//   snet-jumpbox  10.42.2.0/24   Windows jumpbox running VS Code (no public IP)
//   snet-postgres 10.42.3.0/24   delegated to Microsoft.DBforPostgreSQL/flexibleServers
//   AzureBastion  10.42.4.0/26   Azure Bastion, the only way in
//
// Nothing in this network is reachable from the Internet. Every workload subnet
// carries an explicit deny-from-Internet rule at priority 4096 on top of the
// platform default rules, so the intent is visible in the portal rather than
// implied.
// -----------------------------------------------------------------------------

targetScope = 'resourceGroup'

@description('Azure region for all networking resources except the private DNS zone, which is global.')
param location string

@description('Name of the virtual network.')
param vnetName string

@description('Address space of the virtual network in CIDR notation.')
param vnetAddressPrefix string = '10.42.0.0/16'

@description('Address prefix for the Oracle "on-premises" subnet.')
param oracleSubnetPrefix string = '10.42.1.0/24'

@description('Address prefix for the Windows jumpbox subnet.')
param jumpboxSubnetPrefix string = '10.42.2.0/24'

@description('Address prefix for the PostgreSQL flexible server delegated subnet.')
param postgresSubnetPrefix string = '10.42.3.0/24'

@description('Address prefix for AzureBastionSubnet. Must be /26 or larger.')
param bastionSubnetPrefix string = '10.42.4.0/26'

@description('Fully qualified name of the private DNS zone for the PostgreSQL flexible server. Must end with ".private.postgres.database.azure.com".')
param postgresPrivateDnsZoneName string

@description('Port the Oracle listener runs on inside the Oracle subnet.')
param oracleListenerPort string = '1521'

@description('Deploy a NAT gateway to give the Oracle and jumpbox subnets outbound internet access. Leave this true unless you are providing egress another way, such as a UDR to Azure Firewall.')
param deployNatGateway bool = true

@description('Idle timeout in minutes for the NAT gateway. The default of 4 is short for long-running package downloads.')
@minValue(4)
@maxValue(120)
param natGatewayIdleTimeoutMinutes int = 10

@description('Tags applied to every resource in this module.')
param tags object = {}

// Fixed subnet names. The Bastion subnet name is dictated by the platform and
// cannot be changed.
var oracleSubnetName = 'snet-oracle'
var jumpboxSubnetName = 'snet-jumpbox'
var postgresSubnetName = 'snet-postgres'
var bastionSubnetName = 'AzureBastionSubnet'

// -----------------------------------------------------------------------------
// NSG: Oracle subnet
//
// The requirement the lab cares about: the jumpbox subnet and the PostgreSQL
// subnet may reach the Oracle listener on 1521. Everything else inbound from the
// Internet is denied outright.
//
// SSH from Bastion is allowed so a human can actually get onto the box, and SSH
// from the jumpbox is allowed so scripts/*.sh can drive Oracle over ssh.
// -----------------------------------------------------------------------------
resource oracleNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-${oracleSubnetName}'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowOracleListenerFromJumpbox'
        properties: {
          description: 'VS Code and the conversion tooling on the jumpbox read Oracle metadata over 1521.'
          protocol: 'Tcp'
          sourceAddressPrefix: jumpboxSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: oracleSubnetPrefix
          destinationPortRange: oracleListenerPort
          access: 'Allow'
          direction: 'Inbound'
          priority: 100
        }
      }
      {
        name: 'AllowOracleListenerFromPostgres'
        properties: {
          description: 'The PostgreSQL subnet reaches Oracle on 1521 for the separate data-movement step.'
          protocol: 'Tcp'
          sourceAddressPrefix: postgresSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: oracleSubnetPrefix
          destinationPortRange: oracleListenerPort
          access: 'Allow'
          direction: 'Inbound'
          priority: 110
        }
      }
      {
        name: 'AllowSshFromJumpbox'
        properties: {
          description: 'Shell access from the jumpbox so the driver scripts can run against the Oracle host.'
          protocol: 'Tcp'
          sourceAddressPrefix: jumpboxSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: oracleSubnetPrefix
          destinationPortRange: '22'
          access: 'Allow'
          direction: 'Inbound'
          priority: 120
        }
      }
      {
        name: 'AllowSshFromBastion'
        properties: {
          description: 'Interactive SSH brokered by Azure Bastion.'
          protocol: 'Tcp'
          sourceAddressPrefix: bastionSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: oracleSubnetPrefix
          destinationPortRange: '22'
          access: 'Allow'
          direction: 'Inbound'
          priority: 130
        }
      }
      {
        name: 'DenyAllInboundFromInternet'
        properties: {
          description: 'Explicit belt-and-braces deny. The Oracle server is never Internet reachable.'
          protocol: '*'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
          access: 'Deny'
          direction: 'Inbound'
          priority: 4096
        }
      }
    ]
  }
}

// -----------------------------------------------------------------------------
// NSG: jumpbox subnet. RDP only, and only from Bastion.
// -----------------------------------------------------------------------------
resource jumpboxNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-${jumpboxSubnetName}'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowRdpFromBastion'
        properties: {
          description: 'RDP is brokered by Azure Bastion only. There is no public IP on the jumpbox.'
          protocol: 'Tcp'
          sourceAddressPrefix: bastionSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: jumpboxSubnetPrefix
          destinationPortRange: '3389'
          access: 'Allow'
          direction: 'Inbound'
          priority: 100
        }
      }
      {
        name: 'DenyAllInboundFromInternet'
        properties: {
          description: 'Explicit belt-and-braces deny.'
          protocol: '*'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
          access: 'Deny'
          direction: 'Inbound'
          priority: 4096
        }
      }
    ]
  }
}

// -----------------------------------------------------------------------------
// NSG: PostgreSQL delegated subnet. Only 5432 from inside the VNet.
// -----------------------------------------------------------------------------
resource postgresNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-${postgresSubnetName}'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowPostgresFromVnet'
        properties: {
          description: 'psql and the VS Code PostgreSQL extension connect from the jumpbox subnet.'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: postgresSubnetPrefix
          destinationPortRange: '5432'
          access: 'Allow'
          direction: 'Inbound'
          priority: 100
        }
      }
      {
        name: 'DenyAllInboundFromInternet'
        properties: {
          description: 'Explicit belt-and-braces deny. The server is in private access mode with no public endpoint.'
          protocol: '*'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
          access: 'Deny'
          direction: 'Inbound'
          priority: 4096
        }
      }
    ]
  }
}

// -----------------------------------------------------------------------------
// NSG: AzureBastionSubnet.
//
// This rule set is not negotiable - it is the shape the Bastion service
// documents and requires. Deviating from it breaks the service in ways that are
// slow to diagnose, so do not "tighten" it. Note that Bastion genuinely does
// need inbound 443 from the Internet; that is the one place in this lab where
// the deny-from-Internet posture is relaxed, and it terminates on a PaaS
// service rather than on a VM.
// -----------------------------------------------------------------------------
resource bastionNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-${bastionSubnetName}'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowHttpsInbound'
        properties: {
          description: 'Bastion control plane and browser sessions arrive on 443.'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
          access: 'Allow'
          direction: 'Inbound'
          priority: 120
        }
      }
      {
        name: 'AllowGatewayManagerInbound'
        properties: {
          description: 'Required by the Bastion service.'
          protocol: 'Tcp'
          sourceAddressPrefix: 'GatewayManager'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
          access: 'Allow'
          direction: 'Inbound'
          priority: 130
        }
      }
      {
        name: 'AllowAzureLoadBalancerInbound'
        properties: {
          description: 'Health probes.'
          protocol: 'Tcp'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
          access: 'Allow'
          direction: 'Inbound'
          priority: 140
        }
      }
      {
        name: 'AllowBastionHostCommunication'
        properties: {
          description: 'Data plane chatter between Bastion instances.'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: [
            '8080'
            '5701'
          ]
          access: 'Allow'
          direction: 'Inbound'
          priority: 150
        }
      }
      {
        name: 'DenyAllInbound'
        properties: {
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
          access: 'Deny'
          direction: 'Inbound'
          priority: 4096
        }
      }
      {
        name: 'AllowSshRdpOutbound'
        properties: {
          description: 'Bastion reaches the Oracle VM on 22 and the jumpbox on 3389.'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: [
            '22'
            '3389'
          ]
          access: 'Allow'
          direction: 'Outbound'
          priority: 100
        }
      }
      {
        name: 'AllowAzureCloudOutbound'
        properties: {
          description: 'Bastion talks to dependent Azure services on 443.'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureCloud'
          destinationPortRange: '443'
          access: 'Allow'
          direction: 'Outbound'
          priority: 110
        }
      }
      {
        name: 'AllowBastionCommunication'
        properties: {
          description: 'Data plane chatter between Bastion instances.'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: [
            '8080'
            '5701'
          ]
          access: 'Allow'
          direction: 'Outbound'
          priority: 120
        }
      }
      {
        name: 'AllowGetSessionInformation'
        properties: {
          description: 'Required by the Bastion service for session metadata.'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRanges: [
            '80'
            '443'
          ]
          access: 'Allow'
          direction: 'Outbound'
          priority: 130
        }
      }
      {
        name: 'DenyAllOutbound'
        properties: {
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
          access: 'Deny'
          direction: 'Outbound'
          priority: 4096
        }
      }
    ]
  }
}

// -----------------------------------------------------------------------------
// NAT gateway - outbound egress for the two subnets that hold VMs.
//
// This is not optional plumbing, it is the difference between the lab working
// and not. Azure retired default outbound access for new virtual networks on
// 30 September 2025: a VM with no public IP, no load balancer and no NAT gateway
// now has no route to the internet at all. Without this resource:
//
//   - cloud-init on the Oracle VM cannot pull the Oracle Database Free image
//     from container-registry.oracle.com, and the box comes up empty with the
//     failure buried in the serial log;
//   - the jumpbox cannot reach the VS Code Marketplace, GitHub Copilot, the
//     Foundry endpoint, or https://github.com/microsoft/pgsql-tools/ - all four
//     of which the conversion flow needs.
//
// The failure mode is a timeout rather than a refusal, so it reads like a
// firewall problem and costs an afternoon.
//
// A NAT gateway also gives the lab a single stable egress IP, which is what you
// hand to whoever maintains the corporate allowlist. Find it with:
//   az network public-ip show -g <rg> -n nat-<vnet>-pip --query ipAddress -o tsv
//
// Not attached to snet-postgres: the flexible server is a PaaS resource that
// needs no outbound internet. Not attached to AzureBastionSubnet: Bastion
// manages its own egress through its own public IP.
// -----------------------------------------------------------------------------
resource natGatewayPublicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = if (deployNatGateway) {
  name: 'nat-${vnetName}-pip'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource natGateway 'Microsoft.Network/natGateways@2024-05-01' = if (deployNatGateway) {
  name: 'nat-${vnetName}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    idleTimeoutInMinutes: natGatewayIdleTimeoutMinutes
    publicIpAddresses: [
      {
        id: natGatewayPublicIp.id
      }
    ]
  }
}

// -----------------------------------------------------------------------------
// The VNet. Subnets are declared inline rather than as child resources: with
// child resources, concurrent subnet writes against the same VNet race and the
// deployment fails intermittently with a conflict on the parent.
// -----------------------------------------------------------------------------
resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: oracleSubnetName
        properties: {
          addressPrefix: oracleSubnetPrefix
          networkSecurityGroup: {
            id: oracleNsg.id
          }
          natGateway: deployNatGateway ? { id: natGateway.id } : null
          privateEndpointNetworkPolicies: 'Enabled'
        }
      }
      {
        name: jumpboxSubnetName
        properties: {
          addressPrefix: jumpboxSubnetPrefix
          networkSecurityGroup: {
            id: jumpboxNsg.id
          }
          natGateway: deployNatGateway ? { id: natGateway.id } : null
          privateEndpointNetworkPolicies: 'Enabled'
        }
      }
      {
        name: postgresSubnetName
        properties: {
          addressPrefix: postgresSubnetPrefix
          networkSecurityGroup: {
            id: postgresNsg.id
          }
          // Delegation is what puts the flexible server *inside* the VNet
          // instead of behind a public endpoint. Without it the server create
          // fails, and it cannot be added to a subnet that already holds VMs.
          delegations: [
            {
              name: 'postgres-flexible-server-delegation'
              properties: {
                serviceName: 'Microsoft.DBforPostgreSQL/flexibleServers'
              }
            }
          ]
        }
      }
      {
        name: bastionSubnetName
        properties: {
          addressPrefix: bastionSubnetPrefix
          networkSecurityGroup: {
            id: bastionNsg.id
          }
        }
      }
    ]
  }
  // No explicit dependsOn on natGateway is needed: Bicep tracks the symbolic
  // reference in `natGateway.id` above and emits the dependency itself, even
  // though that expression compiles down to a plain resourceId() string. ARM
  // treats a dependency on a resource whose condition is false as already
  // satisfied, so this stays correct when deployNatGateway is false.
}

// -----------------------------------------------------------------------------
// Private DNS zone for the flexible server.
//
// The zone has to exist and be linked to the VNet before the server is created,
// otherwise name resolution of the server FQDN from the jumpbox silently
// returns nothing. The zone name must end in .private.postgres.database.azure.com.
// -----------------------------------------------------------------------------
resource postgresPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: postgresPrivateDnsZoneName
  location: 'global'
  tags: tags
}

resource postgresPrivateDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: postgresPrivateDnsZone
  name: '${vnetName}-link'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

@description('Resource ID of the virtual network.')
output vnetId string = vnet.id

@description('Name of the virtual network.')
output vnetName string = vnet.name

// Subnet IDs are built from the VNet's own resource ID rather than read out of
// vnet.properties.subnets[n].id. Indexing that array assumes the service returns
// subnets in declaration order, which is true today and is not a documented
// guarantee - and if it ever stopped being true, the failure would be a VM
// silently landing in the wrong subnet rather than an error. Interpolating
// vnet.id still carries the dependency on the VNet.

@description('Resource ID of the Oracle subnet.')
output oracleSubnetId string = '${vnet.id}/subnets/${oracleSubnetName}'

@description('Resource ID of the jumpbox subnet.')
output jumpboxSubnetId string = '${vnet.id}/subnets/${jumpboxSubnetName}'

@description('Resource ID of the PostgreSQL delegated subnet.')
output postgresSubnetId string = '${vnet.id}/subnets/${postgresSubnetName}'

@description('Resource ID of AzureBastionSubnet.')
output bastionSubnetId string = '${vnet.id}/subnets/${bastionSubnetName}'

@description('Resource ID of the PostgreSQL private DNS zone.')
output postgresPrivateDnsZoneId string = postgresPrivateDnsZone.id

@description('Name of the PostgreSQL private DNS zone.')
output postgresPrivateDnsZoneName string = postgresPrivateDnsZone.name

@description('Resource ID of the virtual network link, so callers can order the flexible server behind it.')
output postgresPrivateDnsZoneLinkId string = postgresPrivateDnsZoneLink.id

@description('Whether a NAT gateway was deployed for outbound egress.')
output natGatewayDeployed bool = deployNatGateway

@description('Name of the NAT gateway public IP. Read its address with: az network public-ip show -g <rg> -n <name> --query ipAddress -o tsv. That address is the single egress IP for both VM subnets, and is what a corporate allowlist needs.')
output natGatewayPublicIpName string = deployNatGateway ? 'nat-${vnetName}-pip' : ''
