# Publishing RDS through Microsoft Entra application proxy

[← Back to main README](../README.md)

> [!IMPORTANT]
> **This is a design blueprint, not yet implemented.** The farm today is published
> through a **public** Standard Load Balancer + Public IP (see the main
> [README](../README.md)). This page is the agreed target architecture for moving
> the public ingress behind **Microsoft Entra application proxy** so there is **no
> public inbound** at all. Implementation is staged in three phases at the bottom
> of this page. Until Phase 2 lands, the `useAppProxy` flag and the connector
> module described here do not exist in the Bicep yet.

---

## Why application proxy

The current design exposes `TCP 443` + `UDP 3391` from the internet to the RD
Gateway through a Standard Load Balancer, gated by an IP allow-list. Entra
application proxy replaces that with an **outbound-only** model:

- **No public IP, no inbound NSG rules.** The connector dials *out* to Microsoft's
  edge; nothing listens on the internet. The whole inbound attack surface goes away.
- **Entra pre-authentication in front of RDS.** Users authenticate to Entra ID
  first (Conditional Access + MFA), and only assigned users ever reach RD Web.
- **Keep the HTML5 RD Web Client.** Browser-based access at a vanity hostname you
  own, with a publicly trusted certificate.

### At a glance — before vs target

| Aspect | Today (public LB) | Target (application proxy) |
| --- | --- | --- |
| Public ingress | Public IP + Standard LB (`TCP 443`, `UDP 3391`) | None — connector is outbound-only |
| Inbound NSG rules | Allow-list CIDRs → `443` / `3391` on the governance NSG | None inbound from internet; intra-VNet `443` connector → gateway only |
| Pre-auth | None at the edge (RDS handles auth) | Entra ID (Conditional Access + MFA) before RDS |
| Public hostname | `rds-j-slejco.italynorth.cloudapp.azure.com` | `rds.slejco.com` (vanity, you own it) |
| Certificate | Self-signed (cloudapp FQDN) | Let's Encrypt DV, publicly trusted |
| New infra | — | 1+ connector VM in the VNet |
| UDP transport (3391) | Available (perf on lossy links) | **Lost** — App Proxy is HTTPS-only (see limitations) |

---

## Target architecture

```mermaid
flowchart TB
    User[Remote users<br/>any network]
    Entra[Microsoft Entra ID<br/>pre-auth · Conditional Access · MFA]
    AppProxy[Entra application proxy<br/>cloud edge · presents rds.slejco.com cert]
    Connector[Entra private network connector<br/>VM in VNet · outbound 443 only]
    GW[RD Gateway + RD Web Access<br/>private IP · binds rds.slejco.com cert]
    Broker[RD Connection Broker + Licensing<br/>private]
    SH[RD Session Hosts<br/>private]
    DC[(AD DS + internal DNS<br/>rds.slejco.com A → GW private IP)]

    User -->|HTTPS rds.slejco.com| Entra
    Entra --> AppProxy
    AppProxy <-->|outbound TLS<br/>*.msappproxy.net<br/>*.servicebus.windows.net| Connector
    Connector -->|HTTPS 443 internal| GW
    GW -. private .-> Broker
    Broker --> SH
    GW -. LDAP/Kerberos/DNS .-> DC
    Connector -. internal DNS .-> DC
```

The end user only ever talks to Entra ID and the App Proxy cloud edge. The
connector holds a persistent **outbound** tunnel to that edge and forwards
authenticated requests to the gateway's **private** IP. The gateway, broker, and
session hosts never change their private posture.

---

## Hard constraints (from Microsoft docs)

These are non-negotiable requirements pulled from the references at the bottom.
The design below satisfies each one.

| Constraint | Source | How this design meets it |
| --- | --- | --- |
| RD Web + RD Gateway on the **same machine** with a common root, published as a **single** app proxy app (for SSO between them) | RDS integration | Already true — both roles live on the one gateway VM. Publish one app with internal/external URL `https://rds.slejco.com/`. |
| RD Web **Client (HTML5)** requires the **same internal and external FQDN** | RDS integration | Both URLs = `rds.slejco.com`. Split-horizon DNS makes the name resolve internally to the private IP. |
| Custom-domain cert must be a **real, publicly trusted** cert **with private key** (self-signed/expired/missing-key rejected) | Add on-prem app | Let's Encrypt DV cert for `rds.slejco.com`, uploaded as PFX. |
| Connector is **outbound-only**: `443` to `*.msappproxy.net` + `*.servicebus.windows.net`; no inbound | Connector requirements | Connector VM needs only outbound `443`; no inbound NSG rule, no public IP. |
| Do **not** TLS-inspect connector traffic | Connector + proxy | No interception proxy in the connector's egress path. |
| **Entra ID P1** + Application Administrator to publish; synced/cloud identities for pre-auth | Add on-prem app | P1 confirmed available. |
| Connector **v1.5.1975.0+** for the RD Web Client | RDS integration | Install current connector build on the connector VM. |
| **"Use HTTP-Only Cookie" must be OFF** for RDS | RDS integration | Set `isHttpOnlyCookieEnabled = false` when publishing. |
| TLS 1.2 enabled on the connector host | Connector requirements | WS2022 default; verify in DSC. |

> [!WARNING]
> **App Proxy carries HTTPS only — `UDP 3391` does not traverse it.** RDP-over-HTTPS
> through the RD Gateway works fine (that is what the web client and the native
> client use), but the optional **UDP transport** that improves performance on
> lossy/high-latency links is not available through application proxy. For a LAN/VPN
> lab this is irrelevant; flag it if users are on poor remote links.

---

## Locked decisions

The design inputs, all decided 2026-06-17:

| Decision | Choice | Rationale |
| --- | --- | --- |
| Pre-auth mode | **Entra ID** (not pass-through) | Conditional Access + MFA in front of RDS — the main security win. |
| Vanity FQDN | **`rds.slejco.com`** | Owned by you, hosted at GoDaddy. Required for the HTML5 web client. |
| Certificate source | **Let's Encrypt (DV)** via **DNS-01** | No internal CA needed; DV needs only domain control. KV-integrated DigiCert was rejected — it issues **OV** certs that require a validated **organization** in CertCentral, which you don't have. |
| One cert, two bindings | **Yes** | A single `rds.slejco.com` cert serves both the internal RD Web/Gateway IIS binding **and** the App Proxy custom-domain upload. Also retires the old cloudapp-FQDN drift problem. |
| ACME DNS automation | **CNAME delegation to Azure DNS** | GoDaddy gates its Domains API (needs 10+ domains or DDC Premier; you have 2). Delegate only the `_acme-challenge` record to Azure DNS so `posh-acme` can write it via managed identity. |
| Connector count | **1** (lab) | Add a 2nd for production HA. Microsoft recommends a dedicated host, not co-located on the gateway. |
| Public LB | **Removed** (single gateway) | No public ingress. If multiple gateways are added later, front them with an **internal** LB for connector → gateway balancing. |

---

## DNS design (split-horizon)

Three DNS planes. Only the ACME challenge record needs automation; everything else
is static.

### 1. Public — GoDaddy (`slejco.com` zone)

All set by hand, once:

| Record | Type | Value | Purpose |
| --- | --- | --- | --- |
| `rds.slejco.com` | CNAME | `<app-id>.msappproxy.net` | Points the vanity name at the App Proxy edge (value shown after you publish the app). |
| `acme.slejco.com` | NS | 4× Azure DNS name servers | One-time delegation of a child zone to Azure DNS. |
| `_acme-challenge.rds.slejco.com` | CNAME | `rds.acme.slejco.com` | One-time static alias so ACME validation chases into the delegated zone. |

### 2. ACME delegation — Azure DNS (`acme.slejco.com` zone) — automated

`posh-acme` creates and deletes the `rds.acme.slejco.com` **TXT** record on every
renewal using the **`Azure` plugin + managed identity**. You never touch it, and
the GoDaddy API is never involved.

### 3. Internal — AD DNS (`slejco.com` zone on the DCs)

| Record | Type | Value | Purpose |
| --- | --- | --- | --- |
| `rds.slejco.com` | A | RD Gateway **private** IP | Lets the connector resolve the internal URL to the private gateway. **Without this the connector would resolve the public CNAME and loop.** |

> [!NOTE]
> Internal `rds.slejco.com` → private IP and public `rds.slejco.com` → `msappproxy.net`
> is the whole point of split-horizon: clients on the internet hit the App Proxy edge;
> the connector inside the VNet hits the gateway directly.

---

## Certificate design — Let's Encrypt via DNS-01

### Why DNS-01

The connector is outbound-only, so there is no public endpoint for an HTTP-01
challenge to hit. **DNS-01** proves domain control by publishing a TXT record —
no inbound required — and works from the DC or any jumpbox.

### Issuance + renewal flow

```mermaid
flowchart LR
    Task[Scheduled task<br/>posh-acme] -->|request rds.slejco.com<br/>-DnsAlias rds.acme.slejco.com| LE[Let's Encrypt]
    Task -->|write TXT via Azure plugin + MI| ADNS[Azure DNS<br/>acme.slejco.com]
    LE -->|follow CNAME → read TXT| ADNS
    LE -->|issue cert| Task
    Task -->|import PFX| KV[(Key Vault<br/>secret rds-tls)]
    Task -->|upload PFX via Graph| AP[App Proxy<br/>custom domain]
    KV -->|KV VM extension + DSC| GW[RD Gateway internal binding]
```

1. `posh-acme` requests `rds.slejco.com` with `-DnsAlias rds.acme.slejco.com`.
2. It writes the challenge TXT into the **Azure DNS** delegated zone (managed identity).
3. Let's Encrypt follows the GoDaddy CNAME into Azure DNS, reads the TXT, issues the cert.
4. The renewed PFX is pushed to **both** sinks:
   - **Key Vault** secret `rds-tls` → the KV VM extension + DSC `BindRDSCertificates`
     re-bind it on the RDS roles internally (existing mechanism).
   - **App Proxy** custom domain → uploaded via Microsoft Graph for the external edge.

Both sinks need the push regardless of CA; Let's Encrypt just adds the 90-day cadence,
which the scheduled task handles unattended.

> [!NOTE]
> The same publicly trusted cert on the internal binding also satisfies the
> connector's **backend** TLS validation: the connector connects to
> `https://rds.slejco.com/` (private IP) and the gateway presents a cert whose name
> matches and chains to a public root. No name mismatch, no validation bypass needed.

---

## Connector design

- **Placement:** a dedicated Windows Server VM in the RDS VNet (Microsoft recommends
  not co-locating on the gateway). One for the lab; two in different zones for prod HA.
- **Egress (outbound `443`, no inbound):** `*.msappproxy.net`, `*.servicebus.windows.net`,
  plus auth/CRL endpoints (`login.microsoftonline.com`, `*.msauth.net`, `mscrl.microsoft.com`,
  `crl3/crl4.digicert.com`, `ocsp.*`, `ctldl.windowsupdate.com`). Full list in the connector
  reference. **Do not** route this through a TLS-inspecting proxy.
- **DNS:** must resolve the **internal** `rds.slejco.com` (point the connector at the AD DNS
  servers, e.g. `172.16.0.4`).
- **Build:** connector **v1.5.1975.0+** (required for the RD Web Client). TLS 1.2 on.

---

## RDS-side configuration

Once the app is published and DNS/cert are in place, point the deployment at the
external URL (run on the broker):

```powershell
# Route RDS through the proxy external URL, password auth at the gateway
Set-RDDeploymentGatewayConfiguration -GatewayMode Custom `
    -GatewayExternalFqdn 'rds.slejco.com' `
    -LogonMethod Password -UseCachedCredentials $true `
    -BypassLocal $false -Force

# Per collection: require Entra pre-authentication
$preauth = "pre-authentication server address:s:https://rds.slejco.com/`n" +
           "require pre-authentication:i:1"
Set-RDSessionCollectionConfiguration -CollectionName 'DesktopCollection' `
    -CustomRdpProperty $preauth
```

Then enable the RD Web Client and **remove the public endpoints** (the LB + public
IP — handled by the `useAppProxy` Bicep flag in Phase 2). Users connect only to
resources in the RemoteApp/Desktops pane (not "Connect to a remote PC").

---

## Entra publish settings

When `Configure-AppProxy.ps1` creates the on-prem app (Microsoft Graph
`onPremisesPublishing`), the RDS-specific settings are:

| Setting | Value |
| --- | --- |
| Internal URL | `https://rds.slejco.com/` |
| External URL | `https://rds.slejco.com/` (custom domain) |
| Pre-authentication | Microsoft Entra ID |
| Translate URL in headers | No |
| Translate URL in body | No |
| Use HTTP-Only Cookie | **No** (required for RDS) |
| Backend SSO method | None |
| Home page URL (branding) | `https://rds.slejco.com/RDWeb` |
| User assignment | The `RDS-Users` group (only assigned users reach RD Web) |

Layer Conditional Access (require MFA, compliant device, etc.) on the resulting
enterprise app for defense-in-depth.

---

## Repo impact — implementation status

> ✅ done (committed) · ☐ remaining (manual / admin).

### Phase 1 — Entra + cert plumbing ✅

- ✅ `scripts/New-LetsEncryptRdsCertificate.ps1` — `posh-acme` DNS-01 with
  `-DnsAlias` → Azure DNS; import to KV `rds-tls` (only on thumbprint change); stage the PFX.
- ✅ `scripts/Configure-AppProxy.ps1` — Microsoft Graph: instantiate the app,
  `onPremisesPublishing` (Entra pre-auth, RDS flags), custom-domain cert upload,
  connector group, group assignment.
- ✅ DSC — gated `Rds07_PreAuthCustomRdp` step driven by `$PreAuthServerUrl`.
- ☐ Azure DNS zone `acme.slejco.com` + one-time GoDaddy NS delegation + static CNAME (**manual**).
- ☐ Connector VM **software**: MSI install + registration (**admin step** — needs an interactive Entra token).

### Phase 2 — Bicep `useAppProxy` flag ✅

- ✅ `main.bicep` — `useAppProxy` / `appProxyExternalFqdn`; the public IP + load
  balancer become `if (!useAppProxy)`; a connector VM (reusing `modules/vm.bicep`,
  which already does domain-join + optional identity + optional backend pool);
  `PreAuthServerUrl` wired into the broker DSC; conditional outputs via the `!` pattern.
- ✅ `modules/network.bicep` — `writeInternetInboundRules` (= `!useAppProxy`) gates
  the two internet-facing inbound NSG rules.
- ✅ `scripts/Initialize-RdsFarm.ps1` (Tier 0) — `-UseAppProxy` / `-AppProxyExternalFqdn`
  (+ Step 6 bicepparam patching).
- ✅ `main.bicepparam` — declares `useAppProxy` / `appProxyExternalFqdn`; Tier 0 owns the values.

### Phase 3 — Docs + tests

- ✅ This page (status + cutover runbook below).
- ✅ `tests/Test-BicepParamValues.ps1` — App Proxy invariant (valid `appProxyExternalFqdn`,
  `publicGatewayFqdn` == external FQDN).
- ✅ `tests/Test-PostDeployHealth.ps1` — skips the public-LB checks and resolves the
  App Proxy external FQDN when `useAppProxy`.
- ✅ README architecture diagram + "What it deploys" table.

---

## Cutover — turning App Proxy on

Once the manual prerequisites (Azure DNS delegation, connector VM + registered MSI,
GoDaddy CNAME) are in place, run from an **in-VNet** host:

1. **Issue the cert:** `./scripts/New-LetsEncryptRdsCertificate.ps1 -Contact you@slejco.com`
   (use `-Staging` for the first run). Imports to KV `rds-tls` and stages a PFX.
2. **Publish the app:** `./scripts/Configure-AppProxy.ps1 -PfxPath <staged.pfx>
   -PfxPassword <secure> -AssignGroupName 'RDS-Users'`. Note the `<app>.msappproxy.net`
   target it reports.
3. **DNS:** GoDaddy `rds.slejco.com` CNAME → `<app>.msappproxy.net`; internal AD DNS
   `rds.slejco.com` A → the RD Gateway private IP (split-horizon).
4. **Flip the farm to App Proxy mode** (Tier 0 owns the params — don't hand-edit):

   ```bash
   ./scripts/Initialize-RdsFarm.ps1 -UseAppProxy -AppProxyExternalFqdn rds.slejco.com \
       -PublicGatewayFqdn rds.slejco.com   # ...plus your usual Tier 0 args
   ```

   This sets `useAppProxy=true` and points `appProxyExternalFqdn` / `publicGatewayFqdn` /
   `certificateSubject` at `rds.slejco.com`.
5. **Deploy** (`Invoke-ManualDeploy.ps1 -Action deploy`): no public IP/LB, no internet
   inbound rules, a connector VM, and the gateway configured for Entra pre-auth.
6. **Verify**, then decommission any leftover public IP / load balancer.

---

## Prerequisites checklist

Before Phase 1 starts:

- ☐ Entra ID **P1** licensed (confirmed) and an **Application Administrator** account.
- ☐ `slejco.com` publicly owned and managed at GoDaddy (confirmed).
- ☐ An Azure DNS **public zone** for `acme.slejco.com` and a **managed identity** with
  *DNS Zone Contributor* on it (for `posh-acme`).
- ☐ Subnet/route for the connector VM with **outbound `443`** to the App Proxy endpoints.
- ☐ Internal DNS authority to add the split-horizon `rds.slejco.com` A record.
- ☐ The `RDS-Users` group synced to Entra ID (pre-auth needs cloud identities).

---

## References

- [Publish RDS with Microsoft Entra application proxy](https://learn.microsoft.com/entra/identity/app-proxy/application-proxy-integrate-with-remote-desktop-services)
- [Add an on-premises application for remote access](https://learn.microsoft.com/entra/identity/app-proxy/application-proxy-add-on-premises-application)
- [Connector requirements / work with proxy servers](https://learn.microsoft.com/entra/identity/app-proxy/application-proxy-configure-connectors-with-proxy-servers)
- [Custom domains in application proxy](https://learn.microsoft.com/entra/identity/app-proxy/application-proxy-configure-custom-domain)
- [posh-acme — DNS challenge aliases (CNAME delegation)](https://poshac.me/docs/v4/Guides/DNS-Challenge-Aliases/)
