# Contributing to rds-farm

Thanks for working on the RDS farm. This repo is **Bicep + PowerShell DSC** that
deploys a Remote Desktop Services farm into an **existing** Active Directory
domain. A few conventions are load-bearing — please skim this before your first PR.

## Where things run

- **Author on your laptop** (macOS/Windows). **Deploy from a host with VNet
  line-of-sight** — the artifacts storage account and Key Vault are
  private-endpoint-only (public network access disabled), so a GitHub-hosted
  runner can't reach them. Tier 1 deploys run from a laptop-on-VPN or an in-VNet
  jumpbox.
- The deployment model is **Prereqs → Tier 0 → Tier 1 → Tier 2**. See the
  [README](README.md) and [docs/runbook.md](docs/runbook.md).

> [!IMPORTANT]
> **Never hand-edit `main.bicepparam` or `prereqs/tier0.bicepparam`.** Tier 0
> (`scripts/Initialize-RdsFarm.ps1`) writes and re-validates them. Change a value
> by re-running Tier 0 — it's idempotent.

## PowerShell

- Write everything in **PowerShell 7** (`scripts/`, `tests/`).
- The **only** exception is `dsc/Configuration.ps1` and `dsc/Bootstrap.ps1`,
  which the Azure VM extensions run under **Windows PowerShell 5.1**. Keep those
  two **ASCII** and free of PS7-only syntax (`??`, `?.`, ternary, trailing-pipe
  continuation, `ForEach-Object -Parallel`, `ConvertFrom-Json -AsHashtable`).
  Details: [.github/instructions/dsc.instructions.md](.github/instructions/dsc.instructions.md).

## Bicep

- 2-space indent; the analyzer is configured in `bicepconfig.json` (security
  rules at `error`). Validate with `az bicep build` / `az bicep build-params`.
- Compiled top-level ARM (`main.json`, `prereqs/tier0.json`) is gitignored —
  don't commit it.

## Validate before you push

Run the same checks CI runs (no Azure needed):

```bash
az bicep build main.bicep && az bicep build prereqs/tier0.bicep
DOMAIN_JOIN_PASSWORD=x LOCAL_ADMIN_PASSWORD=x az bicep build-params main.bicepparam
pwsh ./tests/Test-BicepParamValues.ps1
pwsh ./tests/Test-DscConfiguration.ps1
pwsh -c "Invoke-ScriptAnalyzer -Path scripts,tests -Recurse -Settings ./PSScriptAnalyzerSettings.psd1"
```

Or open the repo in the **dev container** (`.devcontainer/`), or run the VS Code
tasks (**Terminal → Run Task**), or use the `/validate` prompt in Copilot Chat.
The [`Validate`](.github/workflows/validate.yml) workflow runs all of this on every
PR, plus a **Windows** job that does the authoritative DSC 5.1 parse.

## Tests

- Integration-style checks are plain scripts in `tests/` (`Test-*.ps1`) — they
  print `[PASS]`/`[FAIL]` and exit non-zero.
- Pure-function **unit tests** live in `tests/unit/` (Pester 5).

## Commits & PRs

- Conventional-ish messages: `feat:`, `fix:`, `docs:`, `ci:`, `chore:`,
  `refactor:`.
- **Don't `git push`** unless asked — the maintainer controls pushes.
- Fill in the PR checklist.
