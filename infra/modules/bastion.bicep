// -----------------------------------------------------------------------------
// bastion.bicep
//
// Azure Bastion and its public IP. This is the only inbound path into the lab.
// Neither VM has a public IP; RDP to the jumpbox and SSH to the Oracle host are
// both brokered here, over TLS, from the portal or from
// `az network bastion rdp|ssh`.
//
// Basic SKU is deliberate. It is roughly a third the cost of Standard and does
// everything this lab needs. What you give up: native client support
// (--target-resource-id from a local mstsc/ssh), IP-based connection, shareable
// links, and manual scale units. If you want to RDP from your own machine's
// client rather than the browser, that needs Standard - set skuName accordingly.
//
// AzureBastionSubnet must be /26 or larger and must carry that exact name; both
// are enforced by the platform, not by this file.
// -----------------------------------------------------------------------------

targetScope = 'resourceGroup'

@description('Azure region for the Bastion host and its public IP.')
param location string

@description('Name of the Bastion host.')
param bastionName string

@description('Resource ID of AzureBastionSubnet.')
param subnetId string

@description('Name of the public IP resource fronting Bastion.')
param publicIpName string = '${bastionName}-pip'

@description('DNS label for the public IP, forming <label>.<region>.cloudapp.azure.com. Must be globally unique within the region.')
param publicIpDnsLabel string = ''

@description('Bastion SKU. Basic covers browser-based RDP and SSH. Standard adds native client support, IP-based connection and shareable links.')
@allowed([
  'Basic'
  'Standard'
])
param skuName string = 'Basic'

@description('Tags applied to every resource in this module.')
param tags object = {}

resource publicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: publicIpName
  location: location
  tags: tags
  sku: {
    // Bastion requires a Standard SKU public IP with static allocation.
    // Basic-SKU public IPs are retired and will be rejected.
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    idleTimeoutInMinutes: 4
    dnsSettings: empty(publicIpDnsLabel) ? null : {
      domainNameLabel: publicIpDnsLabel
    }
  }
}

resource bastion 'Microsoft.Network/bastionHosts@2024-05-01' = {
  name: bastionName
  location: location
  tags: tags
  sku: {
    name: skuName
  }
  properties: union(
    {
      ipConfigurations: [
        {
          name: 'IpConf'
          properties: {
            subnet: {
              id: subnetId
            }
            publicIPAddress: {
              id: publicIp.id
            }
            privateIPAllocationMethod: 'Dynamic'
          }
        }
      ]
    },
    // Basic SKU REJECTS enableTunneling, so it can only be set for Standard --
    // hence union() rather than a plain property.
    //
    // It is not optional for this lab. Standard SKU alone does NOT switch
    // tunneling on: enableTunneling defaults to false, and without it
    // `az network bastion tunnel` fails, which takes down scripts/connect.sh
    // (oracle-azure, postgres, scratch) and scripts/seed-oracle.sh --azure --
    // i.e. every way of reaching the Oracle VM or the private PostgreSQL
    // server. A real deployment came up Standard with enableTunneling = None
    // and the whole Azure path was unusable.
    skuName == 'Standard' ? { enableTunneling: true } : {}
  )
}

@description('Name of the Bastion host.')
output bastionName string = bastion.name

@description('Resource ID of the Bastion host.')
output bastionId string = bastion.id

@description('Public IPv4 address of the Bastion host.')
output publicIpAddress string = publicIp.properties.ipAddress

@description('SKU the Bastion host was deployed with.')
output skuName string = skuName
