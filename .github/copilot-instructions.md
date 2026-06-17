# Copilot instructions — rds-farm

Modernized **Azure RDS farm** infrastructure-as-code: **Bicep + PowerShell DSC**,
joined to an **existing** Active Directory domain. Public ingress is a Standard
Load Balancer + Public IP today; a Microsoft Entra application proxy migration is
designed (not yet built) in [docs/app-proxy.md](../docs/app-proxy.md).

## Deployment model — Prereqs → Tier 0 → Tier 1 → Tier 2

- **Tier 0** (`scripts/Initialize-RdsFarm.ps1`) bootstraps everything: CI wiring,
  prereq Azure (Key Vault + DSC storage), the TLS cert, and it **writes
  `main.bicepparam`**.
- **Tier 1** is the farm deploy (`scripts/Invoke-ManualDeploy.ps1`).
- **Tier 2** is post-deploy (vanity CNAME, RDS CALs, smoke tests).

> [!IMPORTANT]
> **Never hand-edit `main.bicepparam` or `prereqs/tier0.bicepparam`.** Tier 0 owns
> them and re-validates with `az bicep build-params`. To change a value, re-run
> Tier 0 (it's idempotent) — don't edit the file. Hand-edits are how the
> FQDN/cert-drift class of bug gets introduced.

## Where code runs (this matters)

- **Authoring** happens on macOS (this clone). **Deploys** must run from a host
  with **VNet line-of-sight** — the artifacts storage account and Key Vault are
  **private-endpoint-only** (public network access disabled). A GitHub-hosted
  runner can't reach them, so Tier 1 runs from a laptop-on-VPN or an in-VNet
  jumpbox, not the pipeline.
- **Apple Silicon cannot parse the DSC `Configuration` keyword** (an ARM64
  limitation). Never trust a local Mac parse of `dsc/*.ps1`; validate via
  `tests/Test-DscConfiguration.ps1` on Windows / CI.

## PowerShell — author in 7; two files are run by the platform on 5.1

Write everything in **PowerShell 7**. The one unavoidable exception is the two
files the Azure VM extensions execute on the RDS VMs — `dsc/Configuration.ps1`
and `dsc/Bootstrap.ps1`. **WS2022 ships only Windows PowerShell 5.1** (PS7 is a
separate MSI install), and the **DSC / Custom Script extensions run under 5.1** —
the classic `Configuration` keyword is a WMF 5.1 technology PS7 can't run. So
those two files must avoid PS7-only syntax: no trailing-pipe line continuation,
no `??`, `?.`, ternary `a ? b : c`, `ForEach-Object -Parallel`, or
`ConvertFrom-Json -AsHashtable`. `tests/Test-DscConfiguration.ps1` and the
validate.yml `dsc-parse` job enforce this with a real 5.1 parse.

- **Everything else** (`scripts/`, `tests/`) runs on PowerShell 7 — PS7 idioms
  are fine.
- **Encoding:** keep the two `dsc/` files **ASCII** (preferred) or UTF-8 **BOM**.
  5.1 mis-decodes BOM-less non-ASCII as cp1252 and the parser fails far from the
  real line. CI's encoding guard enforces this for `dsc/`; `.editorconfig` adds a
  BOM to `.ps1` on save as a backstop.
- Under `Set-StrictMode -Version Latest`, probe `PSObject.Properties` before
  dereferencing optional JSON fields — don't assume `$o.a.b.c` exists.

## Bicep

- 2-space indent. Validate with `az bicep build <file>` and
  `az bicep build-params <param>` before committing.
- Compiled top-level ARM (`main.json`, `prereqs/tier0.json`) is **gitignored** —
  don't commit it. A few `modules/*.json` are intentionally tracked; leave them.
- Keep `allowedClientSourceAddressPrefixes` free of `0.0.0.0/0` —
  `tests/Test-BicepParamValues.ps1` enforces this and other param invariants.

## Certificates

- `publicGatewayFqdn` **must** match `certificateSubject` (CN/SAN) or every RDP
  client rejects the connection. Tier 0 keeps the two in lockstep.
- The **Key Vault VM extension v4.0 installs keys as non-exportable**, so DSC
  fetches the PFX from Key Vault via IMDS rather than `Export-PfxCertificate`.

## Docs

- Each page opens with `[← Back to main README](../README.md)`, uses GitHub alert
  callouts (`> [!NOTE]`, `> [!WARNING]`), mermaid for diagrams, and tables.
- markdownlint runs in CI; `MD013` (line length) is disabled.

## Tests (`tests/Test-*.ps1`)

- Plain scripts (not Pester): they print `[PASS]` / `[FAIL]` and **exit non-zero**
  on failure so they can gate CI. Run the relevant ones before deploying.

## Git

- Conventional-ish messages (`docs:`, `feat:`, `fix:`, `refactor:`).
- **Don't `git push`** unless explicitly asked — the maintainer controls pushes.
