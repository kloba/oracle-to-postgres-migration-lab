// -----------------------------------------------------------------------------
// postgres-flex.bicep
//
// The migration target: Azure Database for PostgreSQL flexible server, PG 16,
// injected into a delegated subnet (private access). No public endpoint exists,
// so the only way to reach it is from inside the VNet - i.e. from the jumpbox.
//
// The interesting part of this file is the server parameter ordering.
//
// Azure splits server parameters into "dynamic" (applied immediately) and
// "static" (applied on restart). shared_preload_libraries is static: writing it
// puts the server into an Updating state and bounces it. Any other configuration
// write that lands while that is happening either fails outright or is silently
// lost, and ARM will happily fire all of the configuration resources in parallel
// because it sees no dependency between them - they are siblings that only share
// a parent.
//
// So the chain below is deliberate and load bearing:
//
//   1. azure.extensions            dynamic. Allowlist first, so plpgsql_check is
//                                  present before the very first conversion run.
//                                  It is fail-open: if it is missing the tool
//                                  skips its deeper validation with no error and
//                                  no warning, and you get a clean-looking report
//                                  that was never actually checked.
//   2. shared_preload_libraries    static. Does NOT restart the server, see below.
//   3. pg_stat_statements.track    only exists as a GUC once the library has
//   4. pg_partman_bgw.dbname       actually been loaded, i.e. after a restart.
//   5. the contoso_store database  created last, so it is not racing a restart.
//
// Reversing 1 and 2, or dropping the dependsOn, produces a deployment that
// succeeds perhaps four times in five. That is the worst possible failure mode.
//
// THE RESTART IS NOT AUTOMATIC, AND ARM CANNOT DO IT.
//
// An earlier version of this comment claimed step 2 "triggers the restart". It
// does not. Microsoft's own parameter reference is explicit: a static parameter
// "Requires a server restart to make the change effective", and the
// configuration resource then reports isConfigPendingRestart = true until
// somebody actually restarts the server.
//
// That matters more here than it would anywhere else. Writing
// shared_preload_libraries makes plpgsql_check *configured* but not *loaded*,
// and plpgsql_check is fail-open: the conversion tool skips its deeper
// validation with no error and nothing in the report to say so. So a lab that
// stopped here would ship the exact trap it exists to teach, and a reader
// checking azure.extensions would get a clean answer while the library was not
// in memory.
//
// There is no ARM verb for "restart", so scripts/deploy.sh performs it after
// the deployment and scripts/status.sh asserts isConfigPendingRestart is false.
// -----------------------------------------------------------------------------

targetScope = 'resourceGroup'

@description('Azure region for the flexible server.')
param location string

@description('Name of the PostgreSQL flexible server. Must be globally unique, 3-63 characters, lowercase letters, digits and hyphens.')
@minLength(3)
@maxLength(63)
param serverName string

@description('PostgreSQL major version. 15 is the floor for this lab: the conversion tool requires 15+ for the scratch database, and the generated schema uses MERGE.')
@allowed([
  '15'
  '16'
  '17'
])
param postgresVersion string = '16'

@description('Administrator login name. Cannot be azure_superuser, azure_pg_admin, admin, administrator, root, guest or public.')
param administratorLogin string = 'o2padmin'

@description('Administrator password. Supply from an environment variable or az keyvault - never commit it.')
@secure()
param administratorLoginPassword string

@description('Compute SKU name.')
param skuName string = 'Standard_D4ds_v5'

@description('Compute tier for skuName.')
@allowed([
  'Burstable'
  'GeneralPurpose'
  'MemoryOptimized'
])
param skuTier string = 'GeneralPurpose'

@description('Provisioned storage in GiB.')
@allowed([
  32
  64
  128
  256
  512
  1024
  2048
])
param storageSizeGb int = 128

@description('Resource ID of the delegated subnet the server is injected into. Must be delegated to Microsoft.DBforPostgreSQL/flexibleServers and hold no other resources.')
param delegatedSubnetId string

@description('Resource ID of the private DNS zone ending in .private.postgres.database.azure.com, already linked to the virtual network.')
param privateDnsZoneId string

@description('Name of the application database created on the server.')
param databaseName string = 'contoso_store'

@description('Name of the scratch database the conversion tool compiles converted objects into. It creates and drops _mig_scratch_ schemas here, so keep it separate from the migration target.')
param scratchDatabaseName string = 'migration_scratch'

@description('Value for the azure.extensions server parameter: the exact extension allowlist this lab needs. dblink is on the list because CONTOSO uses PRAGMA AUTONOMOUS_TRANSACTION, which converts to a dblink round trip, and it is needed on the target and not only on the scratch server.')
param extensionsAllowlist string = 'orafce,uuid-ossp,pgcrypto,pg_trgm,postgis,postgis_topology,postgis_tiger_geocoder,pg_partman,pg_stat_statements,plpgsql_check,dblink'

@description('Value for shared_preload_libraries. Note the background worker is pg_partman_bgw, not pg_partman - the extension and its worker library have different names.')
param sharedPreloadLibraries string = 'pg_partman_bgw,pg_stat_statements,plpgsql_check'

@description('Days of automated backup retention.')
@minValue(7)
@maxValue(35)
param backupRetentionDays int = 7

@description('Tags applied to every resource in this module.')
param tags object = {}

resource postgres 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = {
  name: serverName
  location: location
  tags: tags
  sku: {
    name: skuName
    tier: skuTier
  }
  properties: {
    version: postgresVersion
    administratorLogin: administratorLogin
    administratorLoginPassword: administratorLoginPassword
    createMode: 'Create'
    storage: {
      storageSizeGB: storageSizeGb
      autoGrow: 'Enabled'
    }
    backup: {
      backupRetentionDays: backupRetentionDays
      geoRedundantBackup: 'Disabled'
    }
    network: {
      // Setting both of these is what selects private access. Once the server
      // exists this cannot be switched to public access - it is a rebuild.
      delegatedSubnetResourceId: delegatedSubnetId
      privateDnsZoneArmResourceId: privateDnsZoneId
    }
    highAvailability: {
      mode: 'Disabled'
    }
    authConfig: {
      activeDirectoryAuth: 'Disabled'
      passwordAuth: 'Enabled'
    }
  }
}

// Step 1 - dynamic. Allowlist the extensions before anything else touches the
// server, so the first conversion run has plpgsql_check available.
resource cfgAzureExtensions 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2024-08-01' = {
  parent: postgres
  name: 'azure.extensions'
  properties: {
    value: extensionsAllowlist
    source: 'user-override'
  }
}

// Step 2 - static. This one restarts the server. It must not run concurrently
// with step 1.
resource cfgSharedPreloadLibraries 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2024-08-01' = {
  parent: postgres
  name: 'shared_preload_libraries'
  properties: {
    value: sharedPreloadLibraries
    source: 'user-override'
  }
  dependsOn: [
    cfgAzureExtensions
  ]
}

// Step 3 - pg_stat_statements.track is registered by the pg_stat_statements
// module, so it does not exist as a settable parameter until step 2 has
// restarted the server with the library loaded.
resource cfgPgStatStatementsTrack 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2024-08-01' = {
  parent: postgres
  name: 'pg_stat_statements.track'
  properties: {
    value: 'all'
    source: 'user-override'
  }
  dependsOn: [
    cfgSharedPreloadLibraries
  ]
}

// Step 4 - same story: the pg_partman background worker only reads this once it
// is loaded, and without a dbname it starts up and does nothing at all, which
// looks exactly like it working.
resource cfgPgPartmanBgwDbname 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2024-08-01' = {
  parent: postgres
  name: 'pg_partman_bgw.dbname'
  properties: {
    value: databaseName
    source: 'user-override'
  }
  dependsOn: [
    cfgPgStatStatementsTrack
  ]
}

// Step 5 - created last so the CREATE DATABASE does not collide with the
// restart that step 2 scheduled.
resource database 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2024-08-01' = {
  parent: postgres
  name: databaseName
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
  dependsOn: [
    cfgPgPartmanBgwDbname
  ]
}

// Step 6 - the scratch database the conversion tool compiles into.
//
// The VS Code PostgreSQL extension does not translate Oracle DDL and hope for
// the best: it compiles every converted object against a real database, then
// runs plpgsql_check over the PL/pgSQL bodies, and feeds failures back through
// an AI fix loop. To do that it creates and drops schemas prefixed
// _mig_scratch_, so it needs a database where that churn is harmless.
//
// A second database on the SAME flexible server is the right answer rather than
// a second server: it inherits the extension allowlist and shared_preload_
// libraries configured above (which is what plpgsql_check needs to be present at
// all), and it costs nothing extra. Keeping it separate from contoso_store means
// the scratch churn can never touch the migration target.
//
// Serialised behind the application database so the two CREATE DATABASE calls do
// not race each other on the same server.
resource scratchDatabase 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2024-08-01' = {
  parent: postgres
  name: scratchDatabaseName
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
  dependsOn: [
    database
  ]
}

@description('Name of the flexible server.')
output serverName string = postgres.name

@description('Resource ID of the flexible server.')
output serverId string = postgres.id

@description('Fully qualified domain name of the server. Resolves only from inside the virtual network. This is PGHOST.')
output fullyQualifiedDomainName string = postgres.properties.fullyQualifiedDomainName

@description('Name of the application database. This is PGDATABASE.')
output databaseName string = database.name

@description('Name of the scratch database the conversion tool compiles into. Not the migration target.')
output scratchDatabaseName string = scratchDatabase.name

@description('Administrator login name. This is PGUSER.')
output administratorLogin string = administratorLogin

@description('The extension allowlist that was applied, so scripts/check-pg-prereqs.sh can diff against what the server actually reports.')
output extensionsAllowlist string = extensionsAllowlist

@description('The shared_preload_libraries value that was applied.')
output sharedPreloadLibraries string = sharedPreloadLibraries
