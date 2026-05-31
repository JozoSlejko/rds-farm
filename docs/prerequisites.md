# Prerequisites & parameters reference

[← Back to main README](../README.md)

## Prerequisites

| Item | Notes |
| --- | --- |
| Existing VNet + subnet | Subnet must be able to reach your DCs (DNS, LDAP, Kerberos, SMB). |
| Existing AD DS | On-prem or Azure-hosted DCs reachable from the subnet. |
| Domain-join service account | Member of an OU with delegated rights to join machines. |
| `AzureBastionSubnet` | Required only if `deployBastion = true`. Minimum /26. |
| Azure CLI ≥ 2.60 + Bicep ≥ 0.27 | `az bicep upgrade` if needed. |
| Storage account for DSC artifacts | Blob container (e.g. `dsc`) that holds `Configuration.zip`. |
| RDS CALs | Not provisioned by this template. The deployment uses the 120-day Per-User grace period; install real CALs on the broker post-deploy. |
| TLS certificate (optional) | In Key Vault with **`exportable: true`** in the policy. See [Key Vault prep](./key-vault-cert.md). |
| **Test AD user / group** | Must exist in your AD. By default any `Domain Users` member can sign in; override with `rdsAccessGroup` (e.g. `RDS-Users`). |

## Parameters reference

All parameters are defined in [`main.bicep`](../main.bicep). The most relevant ones:

| Parameter | Required | Description |
| --- | --- | --- |
| `existingVnetName`, `existingVnetResourceGroup`, `existingRdsSubnetName` | yes | Target VNet/subnet (can be in another RG). |
| `adDomainName` | yes | FQDN of the existing AD domain, e.g. `contoso.local`. |
| `adDnsServerIp` | yes | Private IP of an AD DNS server reachable from the subnet. |
| `domainJoinUserName`, `domainJoinPassword` | yes | Credentials for domain join (and the RDS deployment script). |
| `localAdminUserName`, `localAdminPassword` | yes | Local admin on every VM. |
| `sessionHostCount` | no (default 2) | 1–20 RDSH VMs, spread across `availabilityZones`. |
| `vmSize` | no (`Standard_D4s_v5`) | Used for every RDS VM. |
| `windowsSku` | no (`2022-datacenter-azure-edition`) | Azure Edition recommended (hotpatch capable). |
| `allowedClientSourceAddressPrefixes` | yes | CIDRs allowed to reach 443/UDP 3391. **Do not use `0.0.0.0/0`.** |
| `gatewayDnsLabelPrefix` | yes | Becomes `<prefix>.<region>.cloudapp.azure.com`. |
| `deployBastion` | no (true) | Set false if you already have Bastion in a hub VNet. |
| `availabilityZones` | no (`['1','2','3']`) | Reduce if the region has fewer zones. |
| `artifactsLocation` | yes | Base URL of the blob container that holds `Configuration.zip`. Must end with `/`. |
| `artifactsLocationSasToken` | when artifacts container is private | SAS token including the leading `?`. |
| `sessionHostNamingPrefix` | no (`rds-sh-`) | Must match what the broker DSC uses to compute FQDNs. |
| `collectionName` | no | RDS session collection name. |
| `rdsAccessGroup` | no (`Domain Users`) | sAMAccountName of the AD security group whose members can sign in to the collection and through the RD Gateway (used for both `Set-RDSessionCollectionConfiguration -UserGroup` and the RD CAP/RAP). |
| `enableCertificateBinding` | no (false) | Enables the KV → cert binding flow described in [Key Vault prep](./key-vault-cert.md). |
| `keyVaultName`, `keyVaultResourceGroup` | only if cert binding | Existing vault. |
| `keyVaultCertSecretUri` | only if cert binding | `https://<vault>.vault.azure.net/secrets/<cert>`. |
| `publicGatewayFqdn` | only if cert binding (recommended) | Public hostname clients type. Wired into RD Gateway's `GatewayExternalFqdn` and the `rdWebUrl` output. Leave empty to use the LB FQDN (lab/dev only — see [Choosing your gateway FQDN](./gateway-fqdn.md)). |
| `certificateSubject` | only if cert binding | Subject substring to locate the cert (e.g. `CN=rdsgw.contoso.com`). |
