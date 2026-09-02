// -----------------------------------------------------------------------------
// foundry.bicep
//
// Microsoft Foundry account plus the model deployment that powers schema
// conversion in the PostgreSQL extension for VS Code (ms-ossdata.vscode-pgsql).
//
// Two things upstream Microsoft sources disagree about, recorded rather than
// quietly resolved:
//
//   Model.  The Learn documentation states the deployment must be gpt-5.2;
//           Microsoft's own lab ARM template defaults to gpt-5-mini. gpt-5.2 is
//           verified deployable in swedencentral (2026-09-02, version 2025-12-11);
//           this module defaults to gpt-5.2 per Learn. Set modelName to gpt-5-mini
//           for what the official sample deploys. Availability varies by region.
//
//   Quota.  500,000 TPM is the recommended capacity. modelCapacity is expressed
//           in thousands of tokens per minute, so the default of 500 is
//           500,000 TPM. Below that, a schema of ~1,855 objects throttles badly
//           and the run takes hours instead of minutes.
//
// RBAC is deliberately not done here. Current Foundry docs name the role
// "Foundry User"; DP-300 lab 18 says "Cognitive Services OpenAI User". That
// conflict is unresolved upstream, so the reader grants whichever their portal
// offers - see docs/01-prerequisites.md - rather than this template guessing and
// failing the deployment on a role definition ID that does not exist.
// -----------------------------------------------------------------------------

targetScope = 'resourceGroup'

@description('Azure region for the Foundry account. Model availability varies by region - check quota before changing this.')
param location string

@description('Name of the Microsoft Foundry (Cognitive Services) account. Must be globally unique, 2-64 characters.')
@minLength(2)
@maxLength(64)
param accountName string

@description('Custom subdomain for the account. Required for token-based authentication and for the account to get a stable endpoint. Defaults to the account name.')
param customSubDomainName string = ''

@description('Name of the model deployment. This is the value the VS Code extension asks for as the deployment name, not the model name.')
param deploymentName string = 'o2p-schema-conversion'

@description('Model to deploy. Learn documents gpt-5.2 for schema conversion; the official Microsoft lab template uses gpt-5-mini. gpt-5.2 is verified deployable in swedencentral as of 2026-09-02 (version 2025-12-11); availability varies by region.')
param modelName string = 'gpt-5.2'

@description('Model version. Leave empty to let Azure pick the current default version for modelName, which is what you usually want.')
param modelVersion string = ''

@description('Model publisher format.')
param modelFormat string = 'OpenAI'

@description('Deployment capacity in thousands of tokens per minute. 500 means 500,000 TPM, which is the recommended quota for a ~1,855-object schema.')
@minValue(1)
param modelCapacity int = 500

@description('Deployment SKU. GlobalStandard gives the highest available quota; use Standard if data residency requires a single region.')
@allowed([
  'GlobalStandard'
  'DataZoneStandard'
  'Standard'
])
param deploymentSkuName string = 'GlobalStandard'

@description('Whether the account endpoint is reachable from the public Internet. The jumpbox needs outbound access to it, so this stays Enabled unless you add a private endpoint.')
@allowed([
  'Enabled'
  'Disabled'
])
param publicNetworkAccess string = 'Enabled'

@description('Tags applied to every resource in this module.')
param tags object = {}

var effectiveSubDomain = empty(customSubDomainName) ? accountName : customSubDomainName

resource foundry 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: accountName
  location: location
  tags: tags
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    customSubDomainName: effectiveSubDomain
    publicNetworkAccess: publicNetworkAccess
    // Key auth is left on so the reader can paste an endpoint and key into VS
    // Code and get moving. Entra ID auth is the better answer for anything that
    // is not a lab.
    disableLocalAuth: false
    networkAcls: {
      defaultAction: 'Allow'
    }
  }
}

resource deployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: foundry
  name: deploymentName
  sku: {
    name: deploymentSkuName
    capacity: modelCapacity
  }
  properties: {
    model: {
      format: modelFormat
      name: modelName
      // An empty string is not the same as "unset" to ARM, so send null and let
      // Azure resolve the current default version.
      version: empty(modelVersion) ? null : modelVersion
    }
    versionUpgradeOption: 'OnceCurrentVersionExpired'
    raiPolicyName: 'Microsoft.DefaultV2'
  }
}

@description('Endpoint of the Foundry account. This is FOUNDRY_ENDPOINT.')
output endpoint string = foundry.properties.endpoint

@description('Name of the Foundry account.')
output accountName string = foundry.name

@description('Resource ID of the Foundry account, for granting the reader the Foundry User role.')
output accountId string = foundry.id

@description('Name of the model deployment. This is FOUNDRY_DEPLOYMENT_NAME.')
output deploymentName string = deployment.name

@description('Model that was deployed.')
output modelName string = modelName

@description('Deployed capacity in thousands of tokens per minute.')
output modelCapacity int = modelCapacity

@description('Principal ID of the account system-assigned identity.')
output principalId string = foundry.identity.principalId
