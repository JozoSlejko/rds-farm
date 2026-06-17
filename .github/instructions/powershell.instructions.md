---
applyTo: '**/*.ps1,**/*.psd1,**/*.psm1'
description: 'PowerShell authoring + test conventions for rds-farm.'
---

# PowerShell — rds-farm

## Runtime split

Author in **PowerShell 7** for everything in `scripts/` and `tests/` — PS7 idioms
are fine. The **only** exception is `dsc/Configuration.ps1` + `dsc/Bootstrap.ps1`,
which the Azure VM extensions execute under **Windows PowerShell 5.1** on the VMs.
Those two have their own rules — see [dsc.instructions.md](./dsc.instructions.md).

## Style

- Start scripts with `[CmdletBinding()]`, a `param()` block, and
  `$ErrorActionPreference = 'Stop'`.
- Under `Set-StrictMode -Version Latest`, probe `PSObject.Properties` before
  dereferencing optional JSON fields — don't assume `$o.a.b.c` exists.
- `Write-Host` is **allowed** here: these are operator-facing CLI/deploy scripts,
  so colored progress output is intentional (the PSSA rule is excluded).
- Lint ruleset: `PSScriptAnalyzerSettings.psd1` at the repo root.

## Secrets

Never write secrets to disk. Passwords flow through environment variables
(`readEnvironmentVariable` in bicepparam, `$env:` in scripts) — e.g.
`DOMAIN_JOIN_PASSWORD`, `LOCAL_ADMIN_PASSWORD`. The persisted Tier 0 answer file
is gitignored.

## Tests (`tests/Test-*.ps1`)

- Plain scripts, **not** Pester. They print `[PASS]` / `[FAIL]` via a
  `Write-TestResult` helper and **exit non-zero** on failure so they gate CI.
- New tests follow that same pattern (collect failures in a list, exit on count).
- Validate DSC with `tests/Test-DscConfiguration.ps1` on **Windows/CI** — an
  Apple-Silicon Mac can't parse the `Configuration` keyword.
