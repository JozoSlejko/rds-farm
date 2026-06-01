# Troubleshooting

[← Back to main README](../README.md)

> [!TIP]
> Most issues map cleanly to one of the [three tiers](../README.md#deployment-guide). Tier 0 problems (CI bootstrap, cert, hostname) surface as red `pre-deploy-checks` jobs and never leave your tenant in a half-deployed state. Tier 1 problems (Bicep / DSC) appear during `deploy`. Tier 2 problems (DNS, CALs) surface only when a real user tries to sign in.

## Common issues — Tier 0 (cert, hostname, CI bootstrap)

| Symptom | Cause / fix |
| --- | --- |
| `Test-CiPrerequisites.ps1` FAILs on "Repo secret X exists" | Re-run [`scripts/Initialize-CiPrerequisites.ps1`](../scripts/Initialize-CiPrerequisites.ps1) (idempotent) and re-enter the password. Check `gh auth status` shows `repo` scope. |
| `Test-CiPrerequisites.ps1` FAILs on "Federated credential gh-pr exists" | Tenant admin removed it, or you ran the bootstrap against a different repo/branch. Re-run the bootstrap with the correct `-GitHubRepo '<org>/<repo>'`. |
| GitHub Actions error `AADSTS70021: No matching federated identity record found` | The repo / branch / environment in the workflow `permissions.id-token` claim doesn't match any federated credential. Inspect the failing run's `Login` step output for the exact `sub` claim, then check `az ad app federated-credential list --id <appId> -o table`. |
| Pipeline `deploy` job error `AuthorizationFailed: ... does not have authorization to perform action 'Microsoft.Authorization/roleAssignments/write'` | The SP lacks `Role Based Access Control Administrator` on the Key Vault RG. Either grant it (`az role assignment create`) or set `enableCertificateBinding = false` to skip the cross-RG role-assignment module. |
| Cert in Key Vault, but `BindRDSCertificates` throws `Certificate ... not found` | KV VM extension hasn't synced yet (give it up to 1 h), cert policy isn't `exportable: true`, or `certificateSubject` doesn't match the cert's actual subject. Run `tests/Test-PreDeployReadiness.ps1` to catch this before deploy. |
| `403` from Key Vault to the VM extension | UAMI doesn't have `Key Vault Secrets User` on the vault, **or** the vault still uses access policies instead of RBAC (`az keyvault update --enable-rbac-authorization true`). |
| `manual-deploy.md` Step 7a: `az network dns record-set cname set-record` returns `ZoneNotFound` | The zone lives in a different RG than the farm. Pass `-ZoneResourceGroup <dns-rg>` to [`scripts/Set-GatewayCname.ps1`](../scripts/Set-GatewayCname.ps1) or use the CLI's `--resource-group <dns-rg>`. |

## Common issues — Tier 1 (Bicep / DSC apply)

| Symptom | Cause / fix |
| --- | --- |
| DSC extension fails with `Cannot bind argument to parameter 'Url'` | `artifactsLocation` doesn't end with `/`, or `Configuration.zip` not at the root of the container. Re-run [`scripts/Publish-DscArtifact.ps1`](../scripts/Publish-DscArtifact.ps1) to refresh both the URL and the SAS. |
| DSC extension downloads succeed, but `New-RDSessionDeployment` fails | Session host VM names don't match `<sessionHostNamingPrefix><NN>.<adDomainName>`. Make sure `sessionHostNamingPrefix` here is the same as the prefix used to name the RDSH VMs in `main.bicep`. |
| Domain join fails | Wrong `adDnsServerIp`, NSG blocking DNS/LDAP/Kerberos, or service account lacks rights in the target OU. |
| `pre-deploy-checks` job errors `Configuration.zip SAS unreachable (HTTP 403)` | SAS expired (the pipeline issues a 2 h SAS; re-run the workflow) or the storage account firewall blocks GitHub-hosted runners. Open the SA to "All networks" or move to a self-hosted runner. |
| `deploy` job error `quotaExceeded` for `standardDSv5Family` | Sub quota in the target region is below `sessionHostCount + 2`. Request an increase via Azure Portal → Quotas, or reduce `sessionHostCount`. |

## Common issues — Tier 2 (post-deploy, user-facing)

| Symptom | Cause / fix |
| --- | --- |
| `https://<publicGatewayFqdn>/RDWeb/` doesn't resolve | CNAME not yet created ([Manual deploy → Step 7a](./manual-deploy.md#7a-public-dns-cname-vanity-fqdn-only)) or TTL hasn't elapsed. |
| Browser warns "the identity of this computer cannot be verified" | Cert SAN doesn't match the FQDN the user typed (Tier 0 cert mismatch), or you're on Option 1 (Azure LB FQDN) with a self-signed cert and haven't pushed it to the client's Trusted Root store. |
| Health probe shows backend unhealthy | RD Gateway role not finished installing yet (give it ~15 min on first boot), or NSG blocking `AzureLoadBalancer` source tag. |
| User signed in but lands in the wrong session host pool | `rdsAccessGroup` membership change hasn't propagated. Log off / log on the user; or restart the broker (`Restart-Computer -ComputerName rds-cb-01`). |
| CALs about to expire (broker event log 20 day warning) | Activate the license server in **RD Licensing Manager** and add the broker to the AD `Terminal Server License Servers` group. Required for the 120-day grace period to convert to permanent CALs. |

## See also

- [Gateway FQDN and TLS certificate → Common gotchas](./fqdn-and-cert.md#common-gotchas) — DNS / cert mismatch details
- [Testing & verification](./testing.md) — staged smoke tests that catch most failures early
- [`tests/Test-PreDeployReadiness.ps1`](../tests/Test-PreDeployReadiness.ps1) — laptop equivalent of the pipeline's `pre-deploy-checks` job
- [`tests/Test-CiPrerequisites.ps1`](../tests/Test-CiPrerequisites.ps1) — read-only audit of the GitHub Actions + Entra wiring
