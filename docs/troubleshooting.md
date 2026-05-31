# Troubleshooting

[← Back to main README](../README.md)

## Common issues

| Symptom | Cause / fix |
| --- | --- |
| DSC extension fails with `Cannot bind argument to parameter 'Url'` | `artifactsLocation` doesn't end with `/`, or `Configuration.zip` not at the root of the container. |
| Domain join fails | Wrong `adDnsServerIp`, NSG blocking DNS/LDAP/Kerberos, or service account lacks rights in the target OU. |
| `New-RDSessionDeployment` fails | Session host VM names don't match `<sessionHostNamingPrefix><NN>.<adDomainName>`. Make sure `sessionHostNamingPrefix` here is the same as the prefix used to name the RDSH VMs in `main.bicep`. |
| `BindRDSCertificates` throws "Certificate ... not found" | KV VM extension hasn't synced yet, cert policy isn't `exportable: true`, or `certificateSubject` doesn't match the cert's subject. |
| `403` from Key Vault to the VM extension | UAMI doesn't have `Key Vault Secrets User` on the vault, **or** the vault still uses access policies instead of RBAC. |
| Health probe shows backend unhealthy | RD Gateway role not finished installing yet (give it ~15 min on first boot), or NSG blocking `AzureLoadBalancer` source tag. |

## See also

- [Choosing your gateway FQDN → Common gotchas](./gateway-fqdn.md#common-gotchas) — DNS / cert mismatch issues
- [Testing & verification](./testing.md) — staged smoke tests that catch most failures early
