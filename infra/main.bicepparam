// -----------------------------------------------------------------------------
// main.bicepparam
//
// Parameters for infra/main.bicep.
//
// This is a PUBLIC repository, so no value here is a secret and none ever should
// be. Everything sensitive is read from the environment at build time via
// readEnvironmentVariable(), which means the value lives in your shell (or in
// az keyvault, exported by scripts/) and never in git.
//
// Populate your shell from .env first, then deploy:
//
//   set -a; . ./.env; set +a
//   export AZ_SSH_PUBLIC_KEY="$(cat ~/.ssh/id_ed25519.pub)"
//   export ORACLE_CLOUD_INIT_B64="$(base64 < scripts/cloud-init-oracle.yaml | tr -d '\n')"
//
//   az deployment sub create \
//     --name o2p-lab \
//     --location "$AZ_LOCATION" \
//     --template-file infra/main.bicep \
//     --parameters infra/main.bicepparam
//
// The three variables that have no safe default and will fail the deployment if
// unset are AZ_SSH_PUBLIC_KEY, PGPASSWORD and JUMPBOX_ADMIN_PASSWORD.
// -----------------------------------------------------------------------------

using './main.bicep'

// -- Placement ---------------------------------------------------------------

param location = readEnvironmentVariable('AZ_LOCATION', 'swedencentral')
param resourceGroupName = readEnvironmentVariable('AZ_RESOURCE_GROUP', 'o2p-migration-lab-rg')
param namePrefix = readEnvironmentVariable('AZ_PREFIX', 'o2p')

param tags = {
  workload: 'oracle-to-postgres-migration-lab'
  environment: 'lab'
}

// -- Network -----------------------------------------------------------------

param vnetAddressPrefix = '10.42.0.0/16'
param oracleSubnetPrefix = '10.42.1.0/24'
param jumpboxSubnetPrefix = '10.42.2.0/24'
param postgresSubnetPrefix = '10.42.3.0/24'
param bastionSubnetPrefix = '10.42.4.0/26'

// Azure retired default outbound access for new VNets in September 2025. Both
// VMs have no public IP, so without this the Oracle container image pull and the
// VS Code Marketplace both fail with a timeout that looks like a firewall.
param deployNatGateway = true

// -- Oracle VM ---------------------------------------------------------------

param oracleVmSize = readEnvironmentVariable('ORACLE_VM_SIZE', 'Standard_D4s_v5')
param oracleVmPrivateIp = '10.42.1.10'
param oracleAdminUsername = readEnvironmentVariable('ORACLE_VM_ADMIN_USER', 'azureuser')
param oracleDataDiskSizeGb = int(readEnvironmentVariable('ORACLE_VM_DATA_DISK_GB', '128'))

// Not a secret - a public key is public - but it is personal, so it comes from
// the environment rather than being pinned in the repository.
param oracleSshPublicKey = readEnvironmentVariable('AZ_SSH_PUBLIC_KEY', '')

// Already base64. See the header for how to produce it.
param oracleCloudInitBase64 = readEnvironmentVariable('ORACLE_CLOUD_INIT_B64', '')

// -- PostgreSQL --------------------------------------------------------------

param postgresVersion = '16'
param postgresSkuName = readEnvironmentVariable('PG_SKU_NAME', 'Standard_D4ds_v5')
param postgresSkuTier = readEnvironmentVariable('PG_SKU_TIER', 'GeneralPurpose')
param postgresStorageSizeGb = int(readEnvironmentVariable('PG_STORAGE_GB', '128'))
param postgresAdministratorLogin = readEnvironmentVariable('PGUSER', 'o2padmin')
param postgresDatabaseName = readEnvironmentVariable('PGDATABASE', 'contoso_store')

param postgresAdministratorPassword = readEnvironmentVariable('PGPASSWORD', '')

// -- Foundry -----------------------------------------------------------------

// Foundry model quota is regional. Leave FOUNDRY_LOCATION unset to co-locate the
// account with the rest of the lab.
param foundryLocation = readEnvironmentVariable('FOUNDRY_LOCATION', '')
param foundryDeploymentName = readEnvironmentVariable('FOUNDRY_DEPLOYMENT_NAME', 'o2p-schema-conversion')

// Learn documents gpt-5.2; Microsoft's own lab template ships gpt-5-mini.
// gpt-5.2 verified deployable in swedencentral 2026-09-02 (version 2025-12-11).
// Default follows Learn.
param foundryModelName = readEnvironmentVariable('FOUNDRY_MODEL_NAME', 'gpt-5.2')
param foundryModelVersion = readEnvironmentVariable('FOUNDRY_MODEL_VERSION', '')

// foundryModelCapacity is denominated in THOUSANDS of TPM, but FOUNDRY_TPM_QUOTA
// in .env is the raw token-per-minute figure (500000) because that is the number
// the Foundry quota blade shows. Divide here so the two deployment paths agree:
// scripts/deploy.sh reads the same FOUNDRY_TPM_QUOTA and does the same
// `/ 1000`. Bicep `/` on integers truncates, matching bash $(( )).
// Lowering FOUNDRY_TPM_QUOTA below ~200000 throttles a ~1,820-object schema badly.
param foundryModelCapacity = int(readEnvironmentVariable('FOUNDRY_TPM_QUOTA', '500000')) / 1000

// -- Jumpbox -----------------------------------------------------------------

param jumpboxVmSize = readEnvironmentVariable('JUMPBOX_VM_SIZE', 'Standard_D4s_v5')
param jumpboxPrivateIp = '10.42.2.10'
param jumpboxAdminUsername = readEnvironmentVariable('JUMPBOX_ADMIN_USER', 'o2padmin')

param jumpboxAdminPassword = readEnvironmentVariable('JUMPBOX_ADMIN_PASSWORD', '')

// -- Bastion -----------------------------------------------------------------

param bastionSkuName = readEnvironmentVariable('AZ_BASTION_SKU', 'Basic')
