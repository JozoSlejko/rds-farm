// Replaces the Microsoft.Powershell/DSC extension, which silently ignored our
// managedIdentity protectedSettings (DSC's schema only supports SAS / shared
// key for the download). The tenant policy on the artifacts SA blocks both
// anonymous access and shared keys, so the previous setup always fell back to
// anonymous and failed with PublicAccessNotPermitted.
//
// Microsoft.Compute/CustomScriptExtension v1.10+ officially supports
// `managedIdentity` in protectedSettings for fileUris downloads, so the VM
// authenticates with its UAMI (Storage Blob Data Reader on the SA, granted
// by modules/sa-role.bicep). CSE downloads Bootstrap.ps1 + Configuration.zip
// into Downloads\<seq>, Bootstrap.ps1 compiles the chosen configuration and
// runs Start-DscConfiguration locally.
//
// NOTE: the resource name changes from 'Microsoft.Powershell.DSC' to
// 'CustomScriptExtension'. Existing VMs with a failed Microsoft.Powershell.DSC
// extension are NOT removed by this template (Bicep can't manage resources
// it no longer declares). Clean up manually after the first successful deploy:
//   az vm extension delete -g <rg> --vm-name <vm> --name Microsoft.Powershell.DSC

param vmName string
param location string

@description('Configuration function in Configuration.ps1 (e.g. "Gateway", "SessionHost", "RDSDeployment"). For backwards compatibility, callers may still pass the legacy "Configuration.ps1\\Gateway" form.')
param configurationFunction string

@description('Public arguments hashtable passed to the configuration function. Serialized as base64-JSON and forwarded to Bootstrap.ps1 -ArgumentsBase64.')
param configurationProperties object

@description('Protected arguments hashtable (creds + other secrets). Entries shaped { UserName, Password } are promoted to PSCredential by Bootstrap.ps1 before splatting. Travels in protectedSettings.commandToExecute (encrypted at rest, never logged).')
@secure()
param protectedItems object = {}

@description('Base blob URL (no SAS) containing Bootstrap.ps1 and Configuration.zip, e.g. https://<sa>.blob.core.windows.net/dsc/. CSE downloads both files using the VM\'s user-assigned managed identity.')
param artifactsLocation string

@description('Client ID of the user-assigned managed identity attached to the VM. CSE uses it to OAuth-download Bootstrap.ps1 + Configuration.zip from the artifacts SA (Storage Blob Data Reader granted by modules/sa-role.bicep).')
param userAssignedIdentityClientId string

@description('Opaque marker forwarded to properties.forceUpdateTag. Change this value to force the Custom Script Extension to re-run Bootstrap.ps1 and re-apply DSC.')
param forceUpdateTag string

// Accept either 'Foo' or 'Configuration.ps1\\Foo' for backwards compatibility
// with the original DSC extension's <script>\<function> convention.
var functionName    = last(split(configurationFunction, '\\'))
var argsBase64      = base64(string(configurationProperties))
var protectedBase64 = base64(string(protectedItems))

// commandToExecute lives in protectedSettings (encrypted at rest, never
// surfaced in extension status output) because protectedBase64 carries the
// domain-join credentials.
var commandToExecute = 'powershell.exe -ExecutionPolicy Bypass -NoProfile -File Bootstrap.ps1 -ConfigurationFunction ${functionName} -ArgumentsBase64 ${argsBase64} -ProtectedArgumentsBase64 ${protectedBase64}'

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' existing = {
  name: vmName
}

resource cse 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: vm
  name: 'CustomScriptExtension'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    forceUpdateTag: forceUpdateTag
    settings: {
      fileUris: [
        uri(artifactsLocation, 'Bootstrap.ps1')
        uri(artifactsLocation, 'Configuration.zip')
      ]
    }
    protectedSettings: {
      commandToExecute: commandToExecute
      managedIdentity: {
        clientId: userAssignedIdentityClientId
      }
    }
  }
}
