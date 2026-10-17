# Security architecture (remote / headless control)

This document describes the threat model and security architecture of the
Skotiq remote-control surface — the headless API that drives observatory
hardware (mount slew, park, focuser, dome, capture, sequence start, backup
restore) over the network for the desktop dashboard, mobile app, and automation
clients. It targets Skotiq **4.1.0**.

It complements two sibling documents and does not duplicate them:

- [SECURITY.md](../.github/SECURITY.md) — supported versions and how to report a
  vulnerability.
- [docs/headless-secure-setup.md](headless-secure-setup.md) — the operational
  setup guide (flags, tokens, firewall, systemd hardening).

Where the implementation is partial, this document says so plainly. This is
public beta software that controls physical, expensive, and potentially
hazardous hardware; over-claiming would be worse than admitting a gap.

## 1. Trust model

Skotiq is designed for a **trusted local observatory LAN**. The threat model
assumes the network the headless server is bound to is operated by the user and
not directly reachable from the public internet. Direct WAN exposure of the
headless API or web dashboard is **out of scope for default configurations**, as
stated in the [SECURITY.md scope notes](../.github/SECURITY.md).

Concretely, the design treats "a device is on the rig's private LAN" as a
meaningful trust signal (see pairing, below). On an untrusted shared network
(coffee-shop Wi-Fi, an unsegmented corporate LAN, a campus network) that
assumption does not hold, and the operator must add token authentication, TLS,
and firewalling — none of which are forced on by default.

## 2. Authentication defaults

Authentication is **off by default**. `parseHeadlessAuthConfig`
(`apps/desktop/lib/headless/headless_auth_config.dart`) only requires auth when
one of `--auth-token` / `SKOTIQ_AUTH_TOKEN`, `--require-auth`, or a scoped
token (`--view-token` / `--control-token` / `SKOTIQ_VIEW_TOKEN` /
`SKOTIQ_CONTROL_TOKEN`) is supplied. When none is set, the server binds to
loopback (see §3) rather than exposing an unauthenticated LAN port — that is the
fail-safe default.

**Token scopes.** Three scopes exist, ranked `view` < `control` < `admin`
(`apps/desktop/lib/headless_api/auth_policy.dart`):

| Scope | Grants |
|-------|--------|
| `view` | Read status endpoints, subscribe to WebSocket events |
| `control` | `view` plus device/capture/mount/guider/sequencer/dome/safety/switch/cover control |
| `admin` | Full protected API: self-test, settings, file browse, backup/restore |

The legacy `--auth-token` / `SKOTIQ_AUTH_TOKEN` value is an **admin** token.
Give monitoring clients a `view` token instead.

**Fail-closed on unknown scope.** `HeadlessAuthPolicy.requiredScopeFor` resolves
the scope required by a route from its metadata. If a route ever declares a
scope name the parser does not recognize, the policy returns
`HeadlessTokenScope.admin` — the highest privilege — rather than silently
granting `view`. The safe failure mode is to over-require, not to under-protect.

**CSRF posture.** The bearer token is the primary credential. For the **web
dashboard**, the token can be exchanged for an `HttpOnly; Secure;
SameSite=Strict` session cookie (`AuthCookieManager`,
`apps/desktop/lib/headless_api/auth/auth_cookie.dart`). Because that cookie is
not JS-readable, state-changing requests made with it must echo a server-issued
CSRF token via the `X-Skotiq-CSRF` header; `_methodNeedsCsrf` enforces this
for `POST/PUT/DELETE/PATCH`. Bearer-header clients (mobile, automation) are not
cookie-bearing and are not subject to CSRF — CSRF only applies to the
cookie-session path.

## 3. Network binding / LAN exposure

The default bind is **loopback (`127.0.0.1`) only**. `bindLocalOnly` is computed
as `!hasAuthentication && !allowUnauthenticatedLan` in
`headless_auth_config.dart`: enabling any form of authentication flips the bind
to the LAN interface, and `--allow-unauthenticated-lan` /
`SKOTIQ_ALLOW_UNAUTHENTICATED_LAN=true` forces LAN exposure without auth.

`startHeadlessServices` (`apps/desktop/lib/headless/headless_services_bootstrap.dart`)
gates the LAN-facing surfaces on `bindLocalOnly`: UDP discovery (port `45679`)
and the LAN push broadcaster only start when the server is LAN-bound. Loopback
deployments print `http://127.0.0.1:<port>` and skip discovery entirely.

**Risk.** `--allow-unauthenticated-lan` exposes every control command — slew,
park, connect, sequence start, backup restore — to any host that can reach the
port, with no credential. On an untrusted network this is equivalent to handing
out admin control. The startup banner prints a `WARNING: unauthenticated LAN
control is enabled` line in this mode, but nothing prevents it. Use it only on
an isolated development network.

To restrict exposure, leave the default loopback bind and reach the server
through a VPN, reverse proxy, or SSH tunnel; or bind LAN with an `admin` token
plus host firewall rules (see §11 and the
[secure-setup firewall section](headless-secure-setup.md#firewall-and-ports)).

## 4. Token storage

- **Mobile app (iOS / Android):** bearer tokens for saved servers are stored
  **only** in `flutter_secure_storage` (iOS Keychain, Android Keystore-backed
  `EncryptedSharedPreferences`), keyed by `skotiq_saved_server_token::<id>`
  (`apps/mobile/lib/services/saved_servers_service.dart`). Non-secret server
  metadata (host, port, name, fingerprint, notes) lives in a SharedPreferences
  JSON blob via `toJsonNonSecret()`; the token is deliberately excluded from
  that blob and loaded on demand via `tokenFor`.
- **Desktop / web dashboard:** after pairing, the dashboard can hold the token
  in an `HttpOnly; Secure; SameSite=Strict` cookie (§2) so JavaScript / XSS
  cannot read it.
- **Server side (headless host):** the server holds its configured tokens in
  process memory (from CLI args / environment). TLS private keys are written to
  `$APPDATA/server.key` and `chmod 600`'d on POSIX (`tls_provisioner.dart`); on
  Windows they inherit the per-user app-data ACL. The relay appliance secret is
  persisted to `relay_credentials.json` under the application-support directory.

Note: tokens passed via `SKOTIQ_AUTH_TOKEN` or `--auth-token` are visible in
the process environment / argument list to other processes and users on the host;
treat the headless host as part of the trust boundary.

## 5. Pairing

First-run pairing exchanges a code for a session token without the operator
hand-distributing tokens. `POST /api/pairing/start` generates a code (form like
`STAR-LYRA-1234`) that is printed to the desktop console / log and is **never
returned in any HTTP response body**, so a network observer or logging proxy
cannot harvest it. `POST /api/pairing/verify` exchanges a typed code for a
token, minting a **`control`-scoped** token by default; `admin` is opt-in only
via `requestedScope=admin`. Verify attempts are rate-limited by
`PairingAttemptTracker`, which locks out a brute-forcing client for a backoff
window. (`apps/desktop/lib/headless_api/handlers/pairing_handlers.dart`,
`apps/desktop/lib/headless_api/auth/pairing_service.dart`.)

**LAN one-tap (`lan-claim`).** The default `PairingMode.lanOpen` lets a device
on the same private LAN pair with one tap and no code — the same trust model as
Chromecast/Sonos. The trust decision uses the real TCP source address shelf
records (`shelf.io.connection_info`), **never** client-supplied headers like
`X-Forwarded-For` (`lanTrustedSourceAddress`). Only non-loopback RFC1918 /
link-local / ULA addresses qualify (`isPrivateLanAddress`); loopback is rejected
on purpose because a self-hosted relay tunnels remote clients in over loopback,
and the Tailscale CGNAT ranges (`100.64.0.0/10`, `fd7a:115c::/32`) are excluded
so remote clients always fall back to the code flow. Operators who do not trust
every host on the LAN can set `SKOTIQ_PAIRING_MODE=code-required` to require
the code even on the LAN.

**Assumption.** `lan-open` treats LAN membership as authorization. On a network
where untrusted devices share the subnet, any of them can one-tap pair and
obtain a `control` token. Use `code-required` there.

## 6. TLS / self-signed certificates

TLS is **off by default**; the pairing code, bearer token, and every WebSocket
frame travel in cleartext over plain HTTP unless TLS is enabled. Enable it with
`--tls` / `SKOTIQ_TLS=true`, or by supplying `--tls-cert` + `--tls-key`
(which implies TLS).

When enabled with no supplied cert, `provisionTlsContext`
(`apps/desktop/lib/headless_api/tls_provisioner.dart`) generates an RSA-2048,
SHA-256, **10-year** self-signed cert under `$APPDATA/server.{crt,key}` on first
run, with SubjectAltNames covering `127.0.0.1`, `localhost`, and every
non-loopback IPv4 of the host. The whole transport (HTTP + WebSocket upgrade) is
then served over HTTPS/WSS. TLS provisioning failures are fatal: the server
refuses to start rather than silently falling back to plain HTTP.

**Client trust.** Clients do not validate a CA chain (the cert is self-signed
and the `SecurityContext` is built `withTrustedRoots: false`). Instead, the
SHA-256 of the certificate's SubjectPublicKeyInfo is exposed via `/api/info` and
printed in the startup banner, and clients pin against that fingerprint
(trust-on-first-use). The fingerprint is stable across cert re-issuance as long
as the keypair is reused.

**Limitations.** Self-signed + TOFU pinning protects confidentiality and gives
key-continuity, but the first connection is unauthenticated at the transport
layer — a first-connect MITM on a hostile network could pin its own key. If the
SAN enumeration runs before the network is up, the cert covers only
`localhost`/`127.0.0.1` and must be regenerated (delete `server.{crt,key}`) to
cover the LAN IP. Self-signed certs will also produce browser warnings on the
dashboard.

## 7. Relay mode

Relay mode (`--relay-url` / `SKOTIQ_RELAY_URL`,
`apps/desktop/lib/headless/headless_relay_bootstrap.dart`) is an **opt-in,
additive** outbound uplink for reaching the rig from outside the LAN (e.g. from
a phone on cellular). It is off unless a relay URL is supplied, and it never
throws — a misconfigured relay must not stop the daemon coming up.

The relay proxies the local **loopback** port outward. A minted appliance id +
secret persist in `relay_credentials.json`; the secret authenticates the
appliance to the relay only. Per the code comment, **phone authentication
remains the end-to-end pairing token, which the relay never sees** — the relay
transports the session but is not granted control by virtue of carrying it.

Trust implication: the relay is on the path between phone and rig. By default
the uplink requires a valid relay TLS cert; `--relay-allow-insecure-tls` /
`SKOTIQ_RELAY_ALLOW_INSECURE_TLS` disables that check and should only be
used for a relay you operate yourself before it has a real certificate. Run your
own relay, or trust the relay operator, before relying on this path for control.

## 8. CORS

CORS uses an explicit **allow-list**, not origin reflection
(`apps/desktop/lib/headless_api/auth/cors_policy.dart`). By default only the
dashboard's own (same) origin is allowed; additional origins come from
`--cors-origin` / `SKOTIQ_CORS_ORIGINS`. `resolve()` returns an
`Access-Control-Allow-Origin` value only when the request origin is in the
allow-list or is same-origin; otherwise the header is omitted and the browser
blocks the response. High-risk control paths (`isHighRiskControlPath`) get the
same strict rule with the header omitted entirely on disallowed origins. The
prior "reflect any origin matching host:port" behaviour was removed because it
could be bypassed with a spoofed `Host` header.

## 9. What logs redact / leak

Be honest about what reaches logs:

- **Tokens are redacted.** `redactBearer` (`headless_api/request_context.dart`)
  and `_redactToken` (`headless_services_bootstrap.dart`) show only the first
  and last 4 characters of a token; the raw token is never put into the request
  context or structured logs. The auth-identity recorded per request is the
  SHA-256 digest of the token, not the token itself. Auto-generated first-run
  tokens are printed in full to **stdout** (transient) but redacted in the
  structured log.
- **Error details are sanitized** before being returned to clients
  (`validation.dart` `_sanitizeErrorDetail`, `response_helpers.dart`).
- **Local IP addresses are printed** to stdout in the operator connect-banner
  (`startHeadlessServices` enumerates `NetworkInterface.list` and prints
  `<scheme>://<localIp>:<port>`). The TLS SPKI fingerprint is also printed.
- **Filesystem paths and site coordinates** are not specially redacted. Capture
  paths, browse-root paths, the TLS cert path, and the relay-credentials path
  appear in logs; site location and target coordinates flow through ordinary
  status/log output. Anyone with the console output or a captured log file may
  see local IPs, paths, and observing coordinates.

For the full accounting of what diagnostics and logs contain and how to handle
them, see **docs/diagnostics-and-privacy.md** (sibling document). Do not assume
log redaction beyond tokens and client-facing error strings.

## 10. Reporting a vulnerability

Do not open a public GitHub issue for security vulnerabilities. Follow the
private reporting process in [SECURITY.md](../.github/SECURITY.md), and include whether
the deployment used token authentication, TLS, the relay, and host firewall
rules.

## 11. Hardening checklist for operators

- [ ] **Do not expose the headless API or dashboard directly to the WAN.** Use a
      VPN, reverse proxy, SSH tunnel, or the relay instead.
- [ ] **Keep the default loopback bind** unless you specifically need LAN
      clients; never enable `--allow-unauthenticated-lan` on a shared network.
- [ ] **Require auth for any LAN exposure** — prefer scoped tokens: `view` for
      monitors, `control` for imaging clients, `admin` only for maintenance.
- [ ] **Enable `--tls`** so the pairing code, token, and WebSocket frames are not
      cleartext; pin the printed SPKI SHA-256 fingerprint on first connect.
- [ ] **Use long, random tokens** and **rotate** them when a client device is
      lost or decommissioned.
- [ ] **Set `SKOTIQ_PAIRING_MODE=code-required`** if untrusted devices share
      the LAN subnet.
- [ ] **Firewall the TCP API port** (`8080` / `SKOTIQ_PORT`) and the UDP
      discovery port (`45679`) off untrusted networks.
- [ ] **Run your own relay** (or trust the operator) and never leave
      `--relay-allow-insecure-tls` on past initial bring-up.
- [ ] **Restrict file-browse roots** with `SKOTIQ_BROWSE_ROOTS`; only
      allow-listed directories are reachable.
- [ ] **Treat the headless host as part of the trust boundary** — env/arg tokens
      and the TLS key are readable by host users; keep the machine patched and
      access-controlled.
- [ ] **Review audit logs** for high-risk remote commands after remote sessions,
      and remember logs may contain local IPs, paths, and coordinates.
