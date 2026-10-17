# Skotiq remote protocol — security

Skotiq 2.x remote control uses **REST + WebSocket** via `HeadlessApiServer`
(`apps/desktop/lib/headless_api_server.dart`). The `skotiq_remote_protocol`
package supplies discovery, pairing, optional payload encryption helpers, and
Drift-backed paired-device storage.

Historical note: this package was named `skotiq_webrtc`. WebRTC peer
connections and the old signaling server were removed; do not expect WebRTC
APIs to exist or work.

## Threat model (LAN companion)

| Asset | Protection |
|-------|------------|
| API bearer tokens | 256-bit session tokens; constant-time comparison in `TokenResolver` |
| Pairing codes | Short-lived (~5 min); not returned in `POST /api/pairing/start` body |
| Paired phone scope | Default **`control`** at verify; **`admin`** only when client sends `requestedScope: admin` |
| Host authenticity | `/api/info` `fingerprint` + QR confirmation UI on mobile |
| QR payloads | Strict JSON schema; `service: skotiq`; RFC1918 / `.local` hosts only |
| Token storage (mobile) | `flutter_secure_storage` for bearer tokens |

WAN exposure is out of scope for the in-app server: use TLS at a reverse proxy
(see [docs/remote-control.md](../../docs/remote-control.md)).

## Pairing

### Shared storage

GUI **Manage pairing** (`PairingScreen`) and HTTP `/api/pairing/*` both use
`PairingDatabase` (`~/Skotiq/pairing.db` under app documents) via
`TokenManager` / `PairingService`. Codes use the `WORD-WORD-NNNN` format.

### Endpoints

| Endpoint | Auth | Purpose |
|----------|------|---------|
| `POST /api/pairing/start` | Public | Create session; code shown on desktop / QR only |
| `POST /api/pairing/verify` | Public | Exchange code for bearer token + `tokenScope` |

Verify body fields:

- `code` — pairing phrase (required)
- `deviceId`, `deviceName`, `deviceType` — companion identity
- `requestedScope` — `control` (default) or `admin` (opt-in)

Paired tokens are registered in `_pairedSessionTokens` with the granted scope;
they are not promoted to the configured admin token table.

### QR enrollment

`EnhancedSkotiqDiscovery.generateQrData()` includes `host`, `port`,
`version`, `fingerprint`, and optional `pairingCode` while pairing is active.
Mobile `QrConnectionData.parseStrict()` rejects non-local hosts and missing
fingerprints.

`authToken` in QR is reserved for explicit pre-shared enrollment; routine
phone pairing should use `pairingCode` + verify instead of embedding long-lived
admin tokens.

## Discovery

| Component | Status |
|-----------|--------|
| UDP / mDNS discovery (`discovery.dart`, `enhanced_discovery.dart`) | **Supported** for LAN server location |

`SecureDiscovery` and the `ChannelEncryption` (AES-256-GCM + PBKDF2) payload
helper were removed in 6.1: neither had a caller anywhere in the repo, and a
second, unexercised encryption layer is an audit liability. Transport security
is TLS plus bearer tokens on HTTP/WebSocket.

## Token scopes (headless API)

Configured tokens (desktop persistent token, CLI `--view-token` / `--control-token`)
are documented in `apps/desktop/lib/headless_api/auth_policy.dart`.

Paired companions default to **control**: imaging, devices, sequencer; not backup
upload, filesystem browse, or other **admin** routes (see `route_metadata.dart`).

## Operator checklist

1. Enable remote access only on trusted networks.
2. Compare QR / `/api/info` fingerprint before accepting pairing on a phone.
3. Leave **Grant full admin access** off unless the device must manage backups.
4. Revoke lost devices under **Manage pairing**.
5. Terminate TLS with nginx (or equivalent) before exposing the API beyond LAN.

## Related docs

- [INTEGRATION.md](INTEGRATION.md) — client integration steps
- [docs/remote-control.md](../../docs/remote-control.md) — nginx TLS recipe
- [docs/headless-secure-setup.md](../../docs/headless-secure-setup.md) — bind modes and tokens
