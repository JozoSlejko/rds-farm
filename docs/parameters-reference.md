# Parameters reference (`main.bicepparam`)

[← Back to main README](../README.md)

> [!NOTE]
> **Where this fits in the tier model.** The values below are baked into [`main.bicepparam`](../main.bicepparam) during **Tier 0** — normally by [`scripts/Initialize-RdsFarm.ps1`](../scripts/Initialize-RdsFarm.ps1). This page is the per-parameter source-of-truth: which rows the wrapper sets for you (`file`), which it leaves as `readEnvironmentVariable(...)` (`env var`), and which the pipeline overrides at run time (`CI override`). See [README → Deployment guide](../README.md#deployment-guide) for the bigger picture; for the *external* infrastructure you need (AD, VNet, etc.), see the **Prerequisites** section of the README directly.

All parameters are defined in [`main.bicep`](../main.bicep). The most relevant ones:

> [!IMPORTANT]
> **Source of value** in the table below:
>
> | Source | Meaning |
> | --- | --- |
> | **file** | You write the literal value into [`main.bicepparam`](../main.bicepparam) once. Both CI and laptop runs read it as-is. |
> | **env var** | Param uses `readEnvironmentVariable(...)` — CI injects from a GitHub secret, laptop runs use `$env:` (the helper scripts prompt). **Do not put a literal value in the file.** |
> | **CI override** | The pipeline passes `--parameters <name>=<value>` from a previous job's output. The value in the file is only used by laptop runs (`Invoke-ManualDeploy.ps1` sets it too). |

| Parameter | Required | Source | Description |
| --- | --- | --- | --- |
| `existingVnetName`, `existingVnetResourceGroup`, `existingRdsSubnetName` | yes | file | Target VNet/subnet (can be in another RG). |
| `adDomainName` | yes | file | FQDN of the existing AD domain, e.g. `contoso.local`. |
| `adDnsServerIp` | yes | file | Private IP of an AD DNS server reachable from the subnet. |
| `domainJoinUserName` | yes | file | Service account user name for domain join (password below). |
| `domainJoinPassword` | yes | **env var** | `$env:DOMAIN_JOIN_PASSWORD`. CI secret `DOMAIN_JOIN_PASSWORD` (set by [`scripts/Initialize-CiPrerequisites.ps1`](../scripts/Initialize-CiPrerequisites.ps1)). |
| `localAdminUserName` | yes | file | Local admin user name on every VM. |
| `localAdminPassword` | yes | **env var** | `$env:LOCAL_ADMIN_PASSWORD`. CI secret `LOCAL_ADMIN_PASSWORD`. |
| `sessionHostCount` | no (default 2) | file | 1–20 RDSH VMs, spread across `availabilityZones`. |
| `vmSize` | no (`Standard_D4s_v5`) | file | Used for every RDS VM. |
| `windowsSku` | no (`2022-datacenter-azure-edition`) | file | Azure Edition recommended (hotpatch capable). |
| `allowedClientSourceAddressPrefixes` | yes | file | CIDRs allowed to reach 443/UDP 3391. **Do not use `0.0.0.0/0`.** |
| `gatewayDnsLabelPrefix` | yes | file | Becomes `<prefix>.<region>.cloudapp.azure.com`. |
| `deployBastion` | no (true) | file | Set false if you already have Bastion in a hub VNet. |
| `availabilityZones` | no (`['1','2','3']`) | file | Reduce if the region has fewer zones. |
| `artifactsLocation` | yes | **CI override** (file for laptop) | Base URL of the blob container that holds `Configuration.zip`. Must end with `/`. Pipeline's `upload-artifacts` job sets this from the SA the `prereqs` job created. |
| `artifactsLocationSasToken` | when artifacts container is private | **env var** | `$env:ARTIFACTS_SAS`. Pipeline mints a user-delegation SAS via [`scripts/Publish-DscArtifact.ps1`](../scripts/Publish-DscArtifact.ps1) and exports it as a masked job output. |
| `sessionHostNamingPrefix` | no (`rds-sh-`) | file | Must match what the broker DSC uses to compute FQDNs. |
| `collectionName` | no | file | RDS session collection name. |
| `rdsAccessGroup` | no (`Domain Users`) | file | sAMAccountName of the AD security group whose members can sign in to the collection and through the RD Gateway (used for both `Set-RDSessionCollectionConfiguration -UserGroup` and the RD CAP/RAP). |
| `enableCertificateBinding` | no (false) | file | Enables the KV → cert binding flow described in [Key Vault prep](./key-vault-cert.md). |
| `keyVaultName`, `keyVaultResourceGroup` | only if cert binding | file | Existing vault. |
| `keyVaultCertSecretUri` | only if cert binding | file | `https://<vault>.vault.azure.net/secrets/<cert>`. [`scripts/Set-BicepParamCertUri.ps1`](../scripts/Set-BicepParamCertUri.ps1) patches this for you. |
| `publicGatewayFqdn` | only if cert binding (recommended) | file | Public hostname clients type. Wired into RD Gateway's `GatewayExternalFqdn` and the `rdWebUrl` output. Leave empty to use the LB FQDN (lab/dev only — see [Choosing your gateway FQDN](./gateway-fqdn.md)). |
| `certificateSubject` | only if cert binding | file | Subject substring to locate the cert (e.g. `CN=rdsgw.contoso.com`). |
