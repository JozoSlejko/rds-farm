---
applyTo: 'dsc/**'
description: 'DSC + Windows PowerShell 5.1 constraints for the files the platform runs on the VMs.'
---

# DSC — rds-farm (`dsc/Configuration.ps1`, `dsc/Bootstrap.ps1`)

These two files are **not** run by you. The Azure DSC extension compiles/applies
`Configuration.ps1`, and the Custom Script Extension launches `Bootstrap.ps1` —
both under **Windows PowerShell 5.1** on the WS2022 VMs. PS7 is not present by
default and cannot run them.

## 5.1 syntax ban

No PS7-only syntax: no trailing-pipe line continuation, no `??`, `?.`, ternary
`a ? b : c`, `ForEach-Object -Parallel`, or `ConvertFrom-Json -AsHashtable`.

## Validation (never trust a local Mac parse)

> [!WARNING]
> Apple Silicon (ARM64) **cannot parse the `Configuration` keyword**. A local Mac
> parse is meaningless. Validate on Windows:
> `tests/Test-DscConfiguration.ps1` (PSScriptAnalyzer + 5.1 parse + config
> discovery) and the `dsc-parse` job in `.github/workflows/validate.yml`.

## Encoding — ASCII only

Keep both files **ASCII** (no BOM dependency at all). 5.1 mis-decodes BOM-less
non-ASCII as cp1252 and the parser fails far from the real line. The `validate.yml`
encoding guard enforces this for `dsc/`.

## Surface DSC failures (don't swallow them)

`Bootstrap.ps1` must check the result: after `Start-DscConfiguration`, call
`Get-DscConfigurationStatus` and **throw if `Status -ne 'Success'`**. A swallowed
DSC failure once hid the cert-binding bug for a full deploy cycle.

## Certificate binding

- The **Key Vault VM extension v4.0 installs private keys NON-exportable**, so
  `Export-PfxCertificate` fails. `BindRDSCertificates` instead fetches the PFX
  from Key Vault via **IMDS** (managed-identity token → `GET
  /secrets/rds-tls?api-version=7.4` → re-wrap as exportable) before
  `Set-RDCertificate`.
- The cert `TestScript` matches by **Subject only** (not trust level) so a
  self-signed / NotTrusted cert still converges.

## Feature install gotcha

Install `RSAT-RDS-Tools` **without** `-IncludeAllSubFeature` — the GUI snap-ins
pull IIS packages that fail with `0x800f0922` on Azure-Edition WS2022.

## Configurations

`SessionHost`, `Gateway`, `RDSDeployment` — keep each idempotent.
