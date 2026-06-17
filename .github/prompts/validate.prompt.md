---
mode: 'agent'
description: 'Run the full local validation gate (mirrors validate.yml) before committing.'
---

Run the same static checks the CI `validate.yml` workflow runs, locally, and
report a `[PASS]` / `[FAIL]` per check. Stop and fix anything that fails.

1. **Bicep build** — `az bicep build main.bicep` and
   `az bicep build prereqs/tier0.bicep`.
2. **Bicep params** — set dummy `DOMAIN_JOIN_PASSWORD` and `LOCAL_ADMIN_PASSWORD`
   env vars, then `az bicep build-params main.bicepparam` and
   `az bicep build-params prereqs/tier0.bicepparam`.
3. **Param invariants** — `./tests/Test-BicepParamValues.ps1`.
4. **DSC** — `./tests/Test-DscConfiguration.ps1` (note: the strict 5.1 grammar
   check only fires on Windows; on macOS this still runs PSScriptAnalyzer +
   discovery).
5. **`dsc/` encoding guard** — confirm `dsc/Configuration.ps1` and
   `dsc/Bootstrap.ps1` are ASCII (or UTF-8 BOM).
6. **PSScriptAnalyzer** — run over `scripts/` and `tests/` with
   `-Settings ./PSScriptAnalyzerSettings.psd1`; fail only on `Error` severity.

Summarize results in a table. Do not commit on my behalf unless I ask.
