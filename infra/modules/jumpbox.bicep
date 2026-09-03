// -----------------------------------------------------------------------------
// jumpbox.bicep
//
// Windows Server 2022 VM. This is where the reader sits to drive the conversion:
// VS Code, the PostgreSQL extension (ms-ossdata.vscode-pgsql), GitHub Copilot
// and the Oracle client all belong on this box.
//
// THIS MODULE DOES NOT INSTALL ANY OF THEM. It creates a NIC and a bare VM, and
// nothing else -- no CustomScript extension, no DSC, no winget bootstrap. An
// earlier version of this header said the software "all live here", which read
// as a promise the template does not keep: you RDP in and find a clean Windows
// Server 2022 desktop.
//
// That is deliberate, not an oversight. The extension needs an interactive sign
// in to both Foundry and GitHub Copilot, so the box cannot be brought to a
// ready state unattended anyway, and a half-provisioned VM is harder to reason
// about than an obviously empty one. The manual steps are written up in
// docs/01-deploy-infrastructure.md ("Sign in as o2padmin ... Install VS Code")
// and docs/03-run-ai-migration.md.
//
// Also note the template grants NOBODY access to the Foundry model. The account
// and deployment are created, but the data-plane role assignment is a manual
// step -- see docs/01-deploy-infrastructure.md and docs/03-run-ai-migration.md,
// which cover the Foundry User vs Cognitive Services OpenAI User ambiguity.
//
// Why Windows, and why a VM at all: the extension's thick client is documented
// as Windows and Linux x64 only. ARM64 is not supported on either, so Apple
// Silicon is a risk rather than a supported path. A Windows x64 jumpbox is the
// one configuration that is unambiguously in scope, which is why
// CLIENT_PLATFORM=jumpbox is the lab default.
//
// It has no public IP. RDP arrives through Azure Bastion, and the jumpbox NSG
// only accepts 3389 from AzureBastionSubnet.
//
// Outbound egress this box needs, all of which will bite you behind a
// restrictive firewall: the Foundry endpoint, the VS Code Marketplace, GitHub
// Copilot services, and https://github.com/microsoft/pgsql-tools/ - that last
// one is easy to miss and fails confusingly.
// -----------------------------------------------------------------------------

targetScope = 'resourceGroup'

@description('Azure region for the VM and its NIC.')
param location string

@description('Name of the jumpbox virtual machine. Windows computer names are capped at 15 characters, so keep this short.')
@maxLength(15)
param vmName string

@description('VM size. Standard_D4s_v5 is 4 vCPU / 16 GiB, which is comfortable for VS Code plus an Oracle client.')
param vmSize string = 'Standard_D4s_v5'

@description('Resource ID of the subnet the VM NIC is placed in.')
param subnetId string

@description('Static private IPv4 address for the jumpbox.')
param privateIpAddress string = '10.42.2.10'

@description('Local administrator user name. Cannot be administrator, admin, guest, root, user or any other name Windows reserves.')
param adminUsername string = 'o2padmin'

@description('Local administrator password. 12-123 characters and must satisfy Windows complexity rules. Supply from an environment variable or az keyvault - never commit it.')
@secure()
param adminPassword string

@description('Size in GiB of the OS disk. VS Code, the Oracle Instant Client and the converted DDL all land here.')
@minValue(127)
@maxValue(4095)
param osDiskSizeGb int = 256

@description('Windows image publisher.')
param imagePublisher string = 'MicrosoftWindowsServer'

@description('Windows image offer.')
param imageOffer string = 'WindowsServer'

@description('Windows image SKU. 2022-datacenter-azure-edition is Windows Server 2022, gen2, which Trusted Launch requires.')
param imageSku string = '2022-datacenter-azure-edition'

@description('Windows image version.')
param imageVersion string = 'latest'

@description('Time zone applied to the jumpbox. Timestamps in the conversion report come from here.')
param timeZone string = 'UTC'

@description('Tags applied to every resource in this module.')
param tags object = {}

var nicName = '${vmName}-nic'
var osDiskName = '${vmName}-osdisk'

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: nicName
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: privateIpAddress
          subnet: {
            id: subnetId
          }
          // Deliberately no publicIPAddress. Bastion is the only way in.
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-11-01' = {
  name: vmName
  location: location
  tags: tags
  identity: {
    // Lets the reader run az login --identity on the jumpbox and pull lab
    // passwords from Key Vault instead of typing them into a terminal.
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: imagePublisher
        offer: imageOffer
        sku: imageSku
        version: imageVersion
      }
      osDisk: {
        name: osDiskName
        caching: 'ReadWrite'
        createOption: 'FromImage'
        diskSizeGB: osDiskSizeGb
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: true
        timeZone: timeZone
        patchSettings: {
          patchMode: 'AutomaticByOS'
          assessmentMode: 'ImageDefault'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

@description('Name of the jumpbox virtual machine. Pass this to az network bastion rdp --target-resource-id.')
output vmName string = vm.name

@description('Resource ID of the jumpbox virtual machine.')
output vmId string = vm.id

@description('Private IPv4 address of the jumpbox.')
output privateIpAddress string = nic.properties.ipConfigurations[0].properties.privateIPAddress

@description('Local administrator user name.')
output adminUsername string = adminUsername

@description('Principal ID of the VM system-assigned identity, for Key Vault role assignments.')
output principalId string = vm.identity.principalId
