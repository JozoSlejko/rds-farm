---
mode: 'agent'
description: 'Triage a broken RDS farm by symptom, evidence-first.'
---

Help me triage an RDS farm problem. **Gather ground-truth evidence before
concluding** — don't theorize from the symptom alone. Cross-reference
`docs/troubleshooting.md`.

Ask me for the symptom, then work the relevant class:

- **TLS / cert rejected** (`ERR_SSL_KEY_USAGE_INCOMPATIBLE`, "identity cannot be
  verified"): check the served cert on the wire and the cert store on the gateway.
  Likely causes: `publicGatewayFqdn` ↔ `certificateSubject` drift (RD Gateway
  mints a competing self-signed cert), or the Key Vault VM extension v4.0
  non-exportable key breaking the bind. Confirm the bound thumbprint has Digital
  Signature + Server Authentication EKU.
- **RD Web unreachable** (TCP 443 timeout, even from allow-listed clients): suspect
  the **two-NSG sandwich** — the platform/governance **subnet** NSG, not just the
  farm rules. Run **Network Watcher IP-flow verify** to see Allow/Deny and which
  rule decided.
- **DSC role `NotConfigured`**: check whether `Bootstrap.ps1` surfaced a DSC
  failure (`Get-DscConfigurationStatus`), the RSAT feature install (`0x800f0922`
  from `-IncludeAllSubFeature`), and the cert fetch via IMDS.
- **Domain-join failure**: OU path / delegated rights / DNS to the DC.

For each, name the exact command to get evidence (cert store dump, `az vm
extension` status, Network Watcher), run it, then conclude.
