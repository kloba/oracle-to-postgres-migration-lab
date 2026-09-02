// -----------------------------------------------------------------------------
// oracle-vm.bicep
//
// The "on-premises" Oracle server. In the story this lab tells, this box is not
// Azure at all - it is the legacy database sitting in someone's data centre that
// nobody wants to touch. It gets no public IP and no inbound path from the
// Internet; you reach it through Bastion or from the jumpbox.
//
// Oracle itself is not installed here by ARM. The caller passes a base64 encoded
// cloud-init document via cloudInitBase64 and cloud-init pulls the Oracle
// Database Free container image and starts it. Keeping the payload out of Bicep
// means scripts/ owns the Oracle build and this file stays a plain VM.
// -----------------------------------------------------------------------------

targetScope = 'resourceGroup'

@description('Azure region for the VM and its NIC.')
param location string

@description('Name of the Oracle virtual machine.')
param vmName string

@description('VM size. Standard_D4s_v5 is 4 vCPU / 16 GiB, which is enough for Oracle Database Free plus the ~1,855-object CONTOSO schema.')
param vmSize string = 'Standard_D4s_v5'

@description('Resource ID of the subnet the VM NIC is placed in.')
param subnetId string

@description('Static private IPv4 address for the VM, so scripts and tnsnames.ora have something stable to point at.')
param privateIpAddress string = '10.42.1.10'

@description('Local administrator (SSH) user name on the Ubuntu host.')
param adminUsername string = 'azureuser'

@description('OpenSSH public key for adminUsername. Password authentication is disabled outright, so this is the only way in.')
param sshPublicKey string

@description('Base64 encoded cloud-init document passed straight through to customData. Leave empty to bring up a bare VM and provision Oracle by hand.')
param cloudInitBase64 string = ''

@description('Size in GiB of the Premium SSD data disk that holds the Oracle datafiles.')
@minValue(32)
@maxValue(4095)
param dataDiskSizeGb int = 128

@description('Size in GiB of the OS disk.')
@minValue(30)
@maxValue(4095)
param osDiskSizeGb int = 64

@description('Ubuntu image publisher.')
param imagePublisher string = 'Canonical'

@description('Ubuntu image offer. 0001-com-ubuntu-server-jammy is Ubuntu 22.04 LTS.')
param imageOffer string = '0001-com-ubuntu-server-jammy'

@description('Ubuntu image SKU. The gen2 variant is required for Trusted Launch.')
param imageSku string = '22_04-lts-gen2'

@description('Ubuntu image version. "latest" keeps the lab reproducible enough without pinning to a build that will be delisted.')
param imageVersion string = 'latest'

@description('Tags applied to every resource in this module.')
param tags object = {}

var nicName = '${vmName}-nic'
var osDiskName = '${vmName}-osdisk'
var dataDiskName = '${vmName}-datadisk-0'

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: nicName
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          // Static, not Dynamic: the Oracle connect string is baked into
          // .env and tnsnames.ora, and a lease change would break every script.
          privateIPAllocationMethod: 'Static'
          privateIPAddress: privateIpAddress
          subnet: {
            id: subnetId
          }
          // Deliberately no publicIPAddress. This box is not on the Internet.
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
    // Used by scripts/ to pull the Oracle SYSTEM password out of Key Vault
    // rather than passing it on a command line.
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
      dataDisks: [
        {
          name: dataDiskName
          lun: 0
          createOption: 'Empty'
          diskSizeGB: dataDiskSizeGb
          // ReadOnly host caching is the wrong answer for a database volume:
          // it can serve stale reads after a write that bypassed the cache.
          caching: 'None'
          managedDisk: {
            storageAccountType: 'Premium_LRS'
          }
        }
      ]
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      // customData wants base64 and the caller has already encoded it. Passing
      // null rather than '' when empty keeps ARM from rejecting the property.
      customData: empty(cloudInitBase64) ? null : cloudInitBase64
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
        patchSettings: {
          patchMode: 'ImageDefault'
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
        // Managed boot diagnostics: no storage account to create or clean up,
        // and it is the only way to see why cloud-init failed.
        enabled: true
      }
    }
  }
}

@description('Name of the Oracle virtual machine.')
output vmName string = vm.name

@description('Resource ID of the Oracle virtual machine.')
output vmId string = vm.id

@description('Private IPv4 address of the Oracle virtual machine. This is the host in ORACLE_HOST.')
output privateIpAddress string = nic.properties.ipConfigurations[0].properties.privateIPAddress

@description('Principal ID of the VM system-assigned identity, for Key Vault role assignments.')
output principalId string = vm.identity.principalId

@description('Local administrator (SSH) user name.')
output adminUsername string = adminUsername
