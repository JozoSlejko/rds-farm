---
mode: 'agent'
description: 'Pre-deployment readiness check + what-if for the RDS farm (Tier 1).'
---

Help me run a safe pre-deploy pass for the farm. **Tier 1 must run from a host
with VNet line-of-sight** — the artifacts storage account and Key Vault are
private-endpoint-only, so a GitHub-hosted runner can't reach them.

1. Confirm I'm on an in-VNet host (laptop on VPN or jumpbox). If readiness checks
   for KV/SA data planes fail from outside the VNet, treat them as soft warnings,
   not hard blockers.
2. Run `./tests/Test-PreDeployReadiness.ps1` and summarize: cert expiry, KV/SA
   reachability, VNet/subnet, allow-list sanity.
3. Run the deploy in preview mode: `./scripts/Invoke-ManualDeploy.ps1 -Action
   what-if -StorageAccount <sa> -ResourceGroup <rg>`.
4. Summarize the what-if delta. **Flag any destructive change** (deletes,
   replacements) explicitly and stop for my confirmation before any real deploy.

Never run `-Action deploy` without my explicit go-ahead.
