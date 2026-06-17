---
applyTo: '**/*.bicep,**/*.bicepparam'
description: 'Bicep authoring conventions for the rds-farm templates.'
---

# Bicep — rds-farm

## Structure

- `main.bicep` (resource-group scope) orchestrates the farm via single-purpose
  modules in `modules/` (`network`, `loadbalancer`, `vm`, `dsc`, `identity`,
  `bastion`, `kv-role`, `sa-role`).
- `prereqs/tier0.bicep` (subscription scope) provisions the prereq Key Vault +
  DSC storage account and their private endpoints.
- 2-space indent. `lowerCamelCase` for params/vars; descriptive symbolic names.
  Add `@description()` to every parameter.

## Validate before committing

```bash
az bicep build main.bicep
az bicep build-params main.bicepparam        # needs DOMAIN_JOIN_PASSWORD + LOCAL_ADMIN_PASSWORD set (any value)
az bicep build prereqs/tier0.bicep
az bicep build-params prereqs/tier0.bicepparam
```

`bicepconfig.json` enables the analyzer — clear its warnings before committing.

## Compiled JSON

- `main.json` and `prereqs/tier0.json` are **gitignored** — never commit them.
- A few `modules/*.json` (`dsc.json`, `identity.json`, `sa-role.json`) are
  **intentionally tracked**. Leave them; only regenerate if you deliberately
  change those modules.

## Never hand-edit the bicepparam files

> [!IMPORTANT]
> `main.bicepparam` and `prereqs/tier0.bicepparam` are owned by Tier 0
> (`scripts/Initialize-RdsFarm.ps1`), which writes them and re-validates with
> `az bicep build-params`. To change a value, **re-run Tier 0** (idempotent).
> Hand-edits cause the FQDN/cert-drift class of bug.

## Param invariants (enforced by `tests/Test-BicepParamValues.ps1`)

- `allowedClientSourceAddressPrefixes` must **not** contain `0.0.0.0/0` or `::/0`.
- `publicGatewayFqdn` must match `certificateSubject` (CN/SAN).
- When `enableCertificateBinding`, the KV name / RG / cert secret URI / subject
  are all non-empty and well-formed.
- `bastionSubnetName` (when `deployBastion`) must be exactly `AzureBastionSubnet`.

## Security defaults

Keep secure-by-default: no `0.0.0.0/0`, private endpoints with public network
access disabled on KV/SA, Trusted Launch + zones on VMs. Don't add public ingress
beyond the Standard LB allow-list.
