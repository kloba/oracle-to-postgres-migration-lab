// -----------------------------------------------------------------------------
// bastion.bicep
//
// Azure Bastion and its public IP. This is the only inbound path into the lab.
// Neither VM has a public IP; RDP to the jumpbox and SSH to the Oracle host are
// both brokered here, over TLS, from the portal or from
// `az network bastion rdp|ssh`.
//
// Basic is the module default because it is roughly a third the cost, but the
// lab does not use it: infra/main.bicep passes Standard, because the scripts
// need native-client tunneling and Basic cannot do it. Treat Basic as viable
// only if you will connect exclusively from the portal in a browser.
//
// Choosing a tunneling-capable SKU is necessary but NOT sufficient --
// enableTunneling has to be set as well, see the union() below.
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

@description('Bastion SKU. Basic covers browser-based RDP and SSH from the portal only. Standard adds native-client tunneling (az network bastion tunnel/ssh/rdp --target-resource-id), IP-based connection and shareable links. This lab requires Standard: scripts/connect.sh and scripts/seed-oracle.sh --azure reach the Oracle VM and the private PostgreSQL server exclusively through the tunnel.')
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
    // Basic SKU REJECTS enableTunneling and would fail the deployment, so the
    // property is merged in conditionally rather than written inline.
    //
    // It is not optional for this lab. Picking a tunneling-capable SKU does NOT
    // switch tunneling on: enableTunneling defaults to false, and without it
    // `az network bastion tunnel` fails, which takes down scripts/connect.sh
    // (oracle-azure, postgres, scratch) and scripts/seed-oracle.sh --azure --
    // i.e. every way of reaching the Oracle VM or the private PostgreSQL
    // server. A real deployment came up Standard with enableTunneling = None
    // and the whole Azure path was unusable.
    //
    // The test is "not Basic" rather than "is Standard" because Basic being
    // rejected is the actual platform constraint. The az bastion extension
    // gates tunneling on Standard OR Premium
    // (azext_bastion/custom.py:383-388, _is_sku_standard_or_higher), so an
    // is-Standard test would silently omit the property if Premium were ever
    // added to @allowed above, reintroducing this exact bug.
    skuName == 'Basic' ? {} : { enableTunneling: true }
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
