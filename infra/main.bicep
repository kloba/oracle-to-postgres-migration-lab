// -----------------------------------------------------------------------------
// main.bicep
//
// Subscription-scope entry point for the Oracle to PostgreSQL migration lab.
// Creates the resource group and wires up the six modules:
//
//   network         VNet, four subnets, NSGs, PostgreSQL private DNS zone
//   oracle-vm       Ubuntu 22.04 box playing the role of the on-premises Oracle
//   postgres-flex   the migration target, PG 16, private access
//   foundry         Microsoft Foundry account + model deployment
//   jumpbox         Windows Server 2022 box where the reader runs VS Code
//   bastion         the only inbound path into any of it
//
// Deploy with:
//
//   az deployment sub create \
//     --name o2p-lab \
//     --location "$AZ_LOCATION" \
//     --template-file infra/main.bicep \
//     --parameters infra/main.bicepparam
//
// Every password is a @secure() parameter with no default. main.bicepparam
// sources them from environment variables, so nothing sensitive is ever written
// to a file in this repository.
// -----------------------------------------------------------------------------

targetScope = 'subscription'

// -- Placement ---------------------------------------------------------------

@description('Azure region for the resource group and for every regional resource in the lab.')
param location string = 'swedencentral'

@description('Name of the resource group the lab is deployed into. It is created by this template.')
@minLength(1)
@maxLength(90)
param resourceGroupName string = 'o2p-migration-lab-rg'

@description('Short prefix for every resource name. Kept tight because the Windows jumpbox computer name is capped at 15 characters.')
@minLength(2)
@maxLength(10)
param namePrefix string = 'o2p'

@description('Tags applied to the resource group and to every resource inside it.')
param tags object = {
  workload: 'oracle-to-postgres-migration-lab'
  environment: 'lab'
}

// -- Network -----------------------------------------------------------------

@description('Address space of the lab virtual network.')
param vnetAddressPrefix string = '10.42.0.0/16'

@description('Address prefix for the Oracle subnet.')
param oracleSubnetPrefix string = '10.42.1.0/24'

@description('Address prefix for the jumpbox subnet.')
param jumpboxSubnetPrefix string = '10.42.2.0/24'

@description('Address prefix for the PostgreSQL delegated subnet.')
param postgresSubnetPrefix string = '10.42.3.0/24'

@description('Address prefix for AzureBastionSubnet. Must be /26 or larger.')
param bastionSubnetPrefix string = '10.42.4.0/26'

@description('Deploy a NAT gateway so the Oracle and jumpbox subnets have outbound internet access. Azure retired default outbound access in September 2025, so without this the Oracle image pull and the VS Code Marketplace both time out. Set false only if you are providing egress another way.')
param deployNatGateway bool = true

// -- Oracle VM ---------------------------------------------------------------

@description('Size of the Oracle VM.')
param oracleVmSize string = 'Standard_D4s_v5'

@description('Static private IPv4 address for the Oracle VM. Must sit inside oracleSubnetPrefix. This becomes ORACLE_HOST.')
param oracleVmPrivateIp string = '10.42.1.10'

@description('SSH user name on the Oracle VM.')
param oracleAdminUsername string = 'azureuser'

@description('OpenSSH public key for oracleAdminUsername, for example the contents of ~/.ssh/id_ed25519.pub. Password authentication is disabled on the VM, so without this you cannot log in.')
param oracleSshPublicKey string

@description('Base64 encoded cloud-init document for the Oracle VM. Produce it with: base64 -i scripts/cloud-init-oracle.yaml. Leave empty to bring up a bare VM and install Oracle by hand.')
param oracleCloudInitBase64 string = ''

@description('Size in GiB of the Premium SSD data disk holding the Oracle datafiles.')
param oracleDataDiskSizeGb int = 128

// -- PostgreSQL --------------------------------------------------------------

@description('PostgreSQL major version. 15 is the floor: the conversion tool requires 15+ for its scratch database, and the converted schema uses MERGE.')
param postgresVersion string = '16'

@description('Compute SKU for the PostgreSQL flexible server.')
param postgresSkuName string = 'Standard_D4ds_v5'

@description('Compute tier for postgresSkuName.')
param postgresSkuTier string = 'GeneralPurpose'

@description('Provisioned storage in GiB for the PostgreSQL flexible server.')
param postgresStorageSizeGb int = 128

@description('PostgreSQL administrator login. This becomes PGUSER.')
param postgresAdministratorLogin string = 'o2padmin'

@description('PostgreSQL administrator password. Supply from an environment variable or az keyvault. Never commit a real value.')
@secure()
param postgresAdministratorPassword string

@description('Name of the target database. This becomes PGDATABASE.')
param postgresDatabaseName string = 'contoso_store'

@description('Name of the scratch database the conversion tool compiles into. It creates and drops _mig_scratch_ schemas here, so it is deliberately a different database from the migration target.')
param postgresScratchDatabaseName string = 'migration_scratch'

// -- Foundry -----------------------------------------------------------------

@description('Region for the Microsoft Foundry account. Model availability and quota vary by region, so this is separate from location. Defaults to location.')
param foundryLocation string = ''

@description('Name of the model deployment. The VS Code extension asks for this, not for the model name.')
param foundryDeploymentName string = 'o2p-schema-conversion'

@description('Model to deploy. Learn documents gpt-5.2 for schema conversion; the official Microsoft lab template uses gpt-5-mini. gpt-5.2 is verified deployable in swedencentral as of 2026-09-02 (version 2025-12-11); availability varies by region, so preflight.sh checks it.')
param foundryModelName string = 'gpt-5.2'

@description('Model version. Leave empty to let Azure pick the current default for foundryModelName.')
param foundryModelVersion string = ''

@description('Deployment capacity in thousands of tokens per minute. 500 means the recommended 500,000 TPM; below that a ~1,820-object schema throttles badly.')
param foundryModelCapacity int = 500

// -- Jumpbox -----------------------------------------------------------------

@description('Size of the Windows jumpbox VM.')
param jumpboxVmSize string = 'Standard_D4s_v5'

@description('Static private IPv4 address for the jumpbox. Must sit inside jumpboxSubnetPrefix.')
param jumpboxPrivateIp string = '10.42.2.10'

@description('Local administrator user name on the jumpbox.')
param jumpboxAdminUsername string = 'o2padmin'

@description('Local administrator password on the jumpbox. 12-123 characters, must satisfy Windows complexity rules. Supply from an environment variable or az keyvault.')
@secure()
param jumpboxAdminPassword string

// -- Bastion -----------------------------------------------------------------

@description('Azure Bastion SKU. Basic is enough for browser-based RDP and SSH; Standard adds native client support.')
param bastionSkuName string = 'Basic'

// -----------------------------------------------------------------------------
// Names
//
// uniqueString over the subscription ID and resource group name gives a stable
// 13-character suffix: the same inputs always produce the same names, so a
// redeploy updates the lab in place instead of orphaning it, while two people in
// two subscriptions do not collide on the globally unique ones.
// -----------------------------------------------------------------------------
var uniqueSuffix = uniqueString(subscription().subscriptionId, resourceGroupName)

var vnetName = '${namePrefix}-vnet'
var oracleVmName = '${namePrefix}-oracle-vm'
var jumpboxVmName = '${namePrefix}-jump'
var bastionHostName = '${namePrefix}-bastion'
var bastionPublicIpName = '${namePrefix}-bastion-pip'

// Globally unique: DNS-addressable or ARM-global.
var postgresServerName = '${namePrefix}-pg-${uniqueSuffix}'
var foundryAccountName = '${namePrefix}-foundry-${uniqueSuffix}'
var bastionDnsLabel = '${namePrefix}-bastion-${uniqueSuffix}'

// The zone suffix is fixed by the platform: a flexible server in private access
// mode will only accept a private DNS zone ending in exactly this.
var postgresPrivateDnsZoneName = '${postgresServerName}.private.postgres.database.azure.com'

var effectiveFoundryLocation = empty(foundryLocation) ? location : foundryLocation

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module network 'modules/network.bicep' = {
  name: 'deploy-network'
  scope: rg
  params: {
    location: location
    tags: tags
    vnetName: vnetName
    vnetAddressPrefix: vnetAddressPrefix
    oracleSubnetPrefix: oracleSubnetPrefix
    jumpboxSubnetPrefix: jumpboxSubnetPrefix
    postgresSubnetPrefix: postgresSubnetPrefix
    bastionSubnetPrefix: bastionSubnetPrefix
    postgresPrivateDnsZoneName: postgresPrivateDnsZoneName
    deployNatGateway: deployNatGateway
  }
}

module oracleVm 'modules/oracle-vm.bicep' = {
  name: 'deploy-oracle-vm'
  scope: rg
  params: {
    location: location
    tags: tags
    vmName: oracleVmName
    vmSize: oracleVmSize
    subnetId: network.outputs.oracleSubnetId
    privateIpAddress: oracleVmPrivateIp
    adminUsername: oracleAdminUsername
    sshPublicKey: oracleSshPublicKey
    cloudInitBase64: oracleCloudInitBase64
    dataDiskSizeGb: oracleDataDiskSizeGb
  }
}

// Consuming the network module's outputs makes this depend on the whole network
// deployment, which is what we want: the private DNS zone must already be linked
// to the VNet before the server is created, or the FQDN resolves to nothing from
// the jumpbox and the failure looks like a firewall problem.
module postgres 'modules/postgres-flex.bicep' = {
  name: 'deploy-postgres'
  scope: rg
  params: {
    location: location
    tags: tags
    serverName: postgresServerName
    postgresVersion: postgresVersion
    administratorLogin: postgresAdministratorLogin
    administratorLoginPassword: postgresAdministratorPassword
    skuName: postgresSkuName
    skuTier: postgresSkuTier
    storageSizeGb: postgresStorageSizeGb
    delegatedSubnetId: network.outputs.postgresSubnetId
    privateDnsZoneId: network.outputs.postgresPrivateDnsZoneId
    databaseName: postgresDatabaseName
    scratchDatabaseName: postgresScratchDatabaseName
  }
}

module foundry 'modules/foundry.bicep' = {
  name: 'deploy-foundry'
  scope: rg
  params: {
    location: effectiveFoundryLocation
    tags: tags
    accountName: foundryAccountName
    deploymentName: foundryDeploymentName
    modelName: foundryModelName
    modelVersion: foundryModelVersion
    modelCapacity: foundryModelCapacity
  }
}

module jumpbox 'modules/jumpbox.bicep' = {
  name: 'deploy-jumpbox'
  scope: rg
  params: {
    location: location
    tags: tags
    vmName: jumpboxVmName
    vmSize: jumpboxVmSize
    subnetId: network.outputs.jumpboxSubnetId
    privateIpAddress: jumpboxPrivateIp
    adminUsername: jumpboxAdminUsername
    adminPassword: jumpboxAdminPassword
  }
}

module bastion 'modules/bastion.bicep' = {
  name: 'deploy-bastion'
  scope: rg
  params: {
    location: location
    tags: tags
    bastionName: bastionHostName
    publicIpName: bastionPublicIpName
    publicIpDnsLabel: bastionDnsLabel
    subnetId: network.outputs.bastionSubnetId
    skuName: bastionSkuName
  }
}

// -----------------------------------------------------------------------------
// Outputs
//
// Everything scripts/ needs to write a working .env without anyone reading the
// portal. No secrets here: passwords went in, they do not come back out.
// -----------------------------------------------------------------------------

@description('Name of the resource group the lab was deployed into.')
output resourceGroupName string = rg.name

@description('Region the lab was deployed into.')
output location string = location

@description('Private IPv4 address of the Oracle VM. This is ORACLE_HOST.')
output oracleVmPrivateIp string = oracleVm.outputs.privateIpAddress

@description('Name of the Oracle VM.')
output oracleVmName string = oracleVm.outputs.vmName

@description('Resource ID of the Oracle VM, for az network bastion tunnel --target-resource-id. scripts/connect.sh, scripts/seed-oracle.sh and tests/run-tests.sh all read this; without it they fall back to an extra az vm show round trip that breaks if the resource group or VM name has drifted.')
output oracleVmId string = oracleVm.outputs.vmId

@description('SSH user name on the Oracle VM.')
output oracleAdminUsername string = oracleVm.outputs.adminUsername

@description('Fully qualified domain name of the PostgreSQL flexible server. Resolves only from inside the VNet. This is PGHOST.')
output postgresFqdn string = postgres.outputs.fullyQualifiedDomainName

@description('Name of the PostgreSQL flexible server.')
output postgresServerName string = postgres.outputs.serverName

@description('Name of the target database. This is PGDATABASE.')
output postgresDatabaseName string = postgres.outputs.databaseName

@description('Name of the scratch database to point the conversion tool at. Not the migration target.')
output postgresScratchDatabaseName string = postgres.outputs.scratchDatabaseName

@description('FQDN of the server hosting the scratch database. Deliberately identical to postgresFqdn: modules/postgres-flex.bicep puts the scratch database on the SAME flexible server as the target, so it inherits the azure.extensions allowlist and shared_preload_libraries that plpgsql_check needs. Emitted as its own output so scripts/connect.sh scratch never has to guess a hostname. This is SCRATCH_PGHOST.')
output scratchPostgresFqdn string = postgres.outputs.fullyQualifiedDomainName

@description('PostgreSQL administrator login. This is PGUSER.')
output postgresAdministratorLogin string = postgres.outputs.administratorLogin

@description('Extension allowlist applied to azure.extensions, for scripts/check-pg-prereqs.sh to verify against.')
output postgresExtensionsAllowlist string = postgres.outputs.extensionsAllowlist

@description('Endpoint of the Microsoft Foundry account. This is FOUNDRY_ENDPOINT.')
output foundryEndpoint string = foundry.outputs.endpoint

@description('Name of the Microsoft Foundry account.')
output foundryAccountName string = foundry.outputs.accountName

@description('Resource ID of the Foundry account. Grant the reader the Foundry User role here.')
output foundryAccountId string = foundry.outputs.accountId

@description('Name of the Foundry model deployment. This is FOUNDRY_DEPLOYMENT_NAME.')
output foundryDeploymentName string = foundry.outputs.deploymentName

@description('Name of the jumpbox VM. Connect with: az network bastion rdp --name <bastion> --resource-group <rg> --target-resource-id <jumpboxVmId>.')
output jumpboxName string = jumpbox.outputs.vmName

@description('Resource ID of the jumpbox VM, for az network bastion rdp --target-resource-id.')
output jumpboxVmId string = jumpbox.outputs.vmId

@description('Private IPv4 address of the jumpbox.')
output jumpboxPrivateIp string = jumpbox.outputs.privateIpAddress

@description('Local administrator user name on the jumpbox.')
output jumpboxAdminUsername string = jumpbox.outputs.adminUsername

@description('Name of the Azure Bastion host.')
output bastionName string = bastion.outputs.bastionName

@description('Name of the lab virtual network.')
output vnetName string = network.outputs.vnetName

@description('Name of the NAT gateway public IP, which is the single outbound egress address for both VM subnets. Read the address with: az network public-ip show -g <rg> -n <name> --query ipAddress -o tsv.')
output natGatewayPublicIpName string = network.outputs.natGatewayPublicIpName
