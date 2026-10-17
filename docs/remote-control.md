# Skotiq remote control (REST + WebSocket)

Skotiq 2.x remote control runs over the **headless API** (`HeadlessApiServer`):
HTTP/JSON for commands and status, WebSocket (`/events` or `/api/ws`) for live updates.
There is **no in-process TLS terminator** in the Dart server for P1; production deployments
should place a reverse proxy in front of the API port.

## Ports and discovery

| Port / service | Protocol | Purpose |
|----------------|----------|---------|
| `8080` (or `SKOTIQ_PORT` / Settings → Remote access) | TCP HTTP + WS | REST API, web dashboard, WebSocket events |
| `45679` | UDP | Legacy/broadcast discovery (optional) |
| mDNS | — | Bonjour-style `_skotiq._tcp` discovery when enabled |

Mobile and desktop companions discover hosts via mDNS, UDP fallback, manual host entry,
or a **pairing QR** generated under **Settings → Remote access**.

## Pairing model

1. Enable **Remote access** on the imaging machine.
2. Start pairing (Remote access screen or **Manage pairing**). Desktop shows a
   `WORD-WORD-NNNN` code and, when pairing is active, a QR payload from
   `EnhancedSkotiqDiscovery.generateQrData()`.
3. On the phone/tablet:
   - **Scan QR** — validates JSON schema, local-network host, and fingerprint; may
     include `pairingCode` for one-scan enrollment; or
   - **Enter host + pairing code** — `POST /api/pairing/verify` with
     `requestedScope` defaulting to **`control`** (`admin` only when explicitly requested).
4. Store the returned bearer token in secure storage and pass it to `NetworkBackend`.

Public endpoints (no bearer): `/api/info`, `/api/pairing/start`, `/api/pairing/verify`,
plus static dashboard paths documented in `docs/api/web-server-api.md`.

`/api/pairing/start` does **not** return the pairing code in the HTTP body (it is shown on
the desktop UI / embedded in QR only) so passive observers cannot harvest codes from logs.

## Reaching the rig over Tailscale (internet reachability, no relay)

Tailscale gives a paired phone a route to the imaging machine **from anywhere**
— including cellular — without port-forwarding, dynamic-DNS, or exposing the
API to the public internet. Skotiq does **not** run, proxy, or depend on any
Skotiq-operated relay server: the phone talks **directly** to your rig over
the tailnet. The only third party in the path is your own Tailscale tailnet
(WireGuard mesh / DERP). If you are not signed into Tailscale, nothing about the
remote-access feature changes — it stays LAN/loopback only.

### How a tailnet address is detected and advertised

When **Remote access** is enabled and bound beyond loopback, the desktop
enumerates its network interfaces and classifies each address with the
fail-closed `TailnetDetector`
(`packages/skotiq_remote_protocol/lib/src/tailnet_detector.dart`):

| Tier | Ranges | Used as |
|------|--------|---------|
| `tailscale` | IPv4 CGNAT `100.64.0.0/10` (MagicDNS `100.x.y.z`), IPv6 `fd7a:115c::/32` | `WebServerState.tailscaleIp` / Tailscale QR |
| `lan` | RFC1918, `169.254/16`, generic ULA `fc00::/7`, mDNS `.local` | `WebServerState.localIp` / LAN QR |
| `loopback` | `127.0.0.0/8`, `::1`, `localhost` | never advertised in any QR |
| `public` / `invalid` | anything else | **refused** — never embedded in a QR |

The tailnet address is surfaced as a **separate** field from the LAN address, so
the two never get confused. `Settings → Remote access` then shows a dedicated
**"Reach this rig over Tailscale"** panel:

- **Reachable** (a `100.x` / `fd7a:…` interface is up *and* the server is not
  bound loopback-only): the panel shows the tailnet host, its
  bracket-correct URL (`http://100.96.0.7:8080`, or `http://[fd7a:115c::1]:8080`
  for IPv6), and — once you press **Start pairing** — a QR that embeds the
  **tailnet** host. It never embeds the LAN address.
- **Not detected**: the panel shows an informational alert with a **Re-check**
  button (re-scans interfaces without restarting the server, so a tailnet that
  came up after launch is picked up) and a **manual host** field. The manual
  host is validated against `TailnetDetector.isTailscaleHost` before a QR is
  built — a LAN/public/garbage value is rejected with a clear message rather
  than silently embedded.

### Bring Tailscale up on the rig

1. Install Tailscale on the imaging machine (`https://tailscale.com/download`).
2. `tailscale up` and sign in to your tailnet.
3. Confirm an address exists: `tailscale ip -4` prints the `100.x.y.z` MagicDNS
   address. (`tailscale status` shows the full peer list.)
4. In Skotiq, enable **Remote access**, then open the Tailscale panel and
   press **Re-check** if the address is not already shown.
5. On the phone: install Tailscale, sign in to the **same** tailnet, then scan
   the Tailscale QR (or enter the `100.x` host + pairing code manually).

### Why the QR carries the `100.x` host, not a hostname

The pairing QR is validated by the strict parser (`QrConnectionData.parseStrict`
→ `isLocalNetworkHost` → `TailnetDetector.isAccepted`), which accepts loopback,
LAN, and tailnet **literals** but does **not** perform DNS resolution (a hostile
resolver could otherwise steer a scan to an attacker host). MagicDNS *names*
(`my-rig.tail1234.ts.net`) therefore are not embedded in the QR; the stable
`100.x` tailnet IP is. The phone reconstructs the URL from the bare host and
brackets an IPv6 literal itself.

### No relay — what this means operationally

- **No Skotiq cloud.** There is no Skotiq-hosted account, broker, or
  TURN/relay. Pairing, tokens, and the WebSocket all terminate on your rig.
- **Direct WireGuard.** Tailscale negotiates a direct encrypted tunnel between
  phone and rig; it only falls back to Tailscale's DERP relays for NAT
  traversal of the *encrypted* WireGuard packets — it can never read your
  traffic, and that path is between your two devices, not a Skotiq service.
- **Pairing is transport-agnostic.** The fingerprint/scope/token model
  (see *Pairing model* above and `SECURITY.md`) is identical over LAN and
  Tailscale. A tailnet does not weaken or bypass pairing — a device still needs
  a valid bearer token minted by `POST /api/pairing/verify`.
- **Auto-reconnect on cellular.** The phone's connectivity monitor treats a
  tailnet host as reachable over cellular (not Wi-Fi-only), so a backgrounded
  session resumes when the phone regains any network, not just Wi-Fi.

### Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| Panel says "No Tailscale address detected" | `tailscale up` not run, or the address came up after the server started — press **Re-check**. |
| QR refuses a manually-entered host | The value is not in `100.64.0.0/10` or `fd7a:115c::/32`. Use the address from `tailscale ip -4`. |
| Phone scans QR but cannot connect | Phone is on a *different* tailnet, or the rig's OS firewall blocks inbound TCP on the API port (default `8080`) on the tailnet interface. See [troubleshooting/firewall.md](troubleshooting/firewall.md). |
| Reachable URL is shown but `bindLocalOnly` is on | The server is bound to loopback; the tailnet address is not actually reachable. Disable local-only bind in **Remote access**. |

## TLS with nginx (recommended for WAN or untrusted LAN)

Terminating TLS at nginx keeps certificate rotation out of the Flutter/Shelf stack.

### 1. Issue certificates

Use your CA of choice (Let’s Encrypt, internal PKI, etc.) for a DNS name that resolves
to the imaging PC, e.g. `skotiq.observatory.local`.

### 2. Example nginx site

```nginx
# /etc/nginx/sites-available/skotiq.conf
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

upstream skotiq_api {
    # Shelf binds 0.0.0.0:8080 in LAN mode; keep proxy on loopback.
    server 127.0.0.1:8080;
    keepalive 32;
}

server {
    listen 443 ssl http2;
    server_name skotiq.observatory.local;

    ssl_certificate     /etc/ssl/skotiq/fullchain.pem;
    ssl_certificate_key /etc/ssl/skotiq/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    # Optional: require client certs or IP allowlists here.

    location / {
        proxy_pass http://skotiq_api;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # WebSocket upgrade for /events and /api/ws
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_read_timeout 3600s;
    }
}

# Redirect cleartext → TLS
server {
    listen 80;
    server_name skotiq.observatory.local;
    return 301 https://$host$request_uri;
}
```

Enable and reload:

```bash
sudo ln -sf /etc/nginx/sites-available/skotiq.conf /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

### 3. Trust the proxy for per-client rate limiting (`SKOTIQ_TRUST_PROXY`)

By default the API derives its rate-limit and pairing brute-force-lockout key
from the **real TCP socket peer**, because in the direct-bind deployment the
`X-Forwarded-For` / `X-Real-IP` headers are attacker-controlled and a client
could rotate them to evade both limiters.

Behind the loopback nginx proxy above, every request arrives from `127.0.0.1`,
so that default would collapse **all** clients into a single rate-limit/lockout
bucket — one misbehaving phone could lock everyone out, and a brute-forcer
behind the same proxy would never be isolated. When (and only when) the API
sits behind this documented loopback proxy, set:

```bash
# systemd unit / environment file for the headless service
SKOTIQ_TRUST_PROXY=true
```

With the flag set, the limiter keys off the client IP nginx forwards in
`X-Forwarded-For` — and only when the socket peer is loopback, so a direct
LAN/WAN client can never forge the key. Leave it **unset** for any direct-bind
(`0.0.0.0:8080`, no proxy) deployment. The companion nginx config above already
injects `X-Real-IP` and `X-Forwarded-For`; this flag is what tells the API to
believe them.

> Related testing-only escape hatch: `SKOTIQ_ALLOW_INSECURE_UPDATE_SOURCE=true`
> lets the OTA updater fetch from a non-HTTPS / unpinned source. Never set it on
> a production appliance.

### 4. Client configuration

- Mobile manual host: `skotiq.observatory.local:443` is **not** valid in the strict
  LAN QR schema; for WAN, use manual host entry with `https` via a client build that
  supports TLS URLs, or stay on LAN with QR.
- Set desktop **Remote access** port to `8080` internally; only nginx exposes `443`.
- Pairing QR still uses the **LAN IP and API port** (`8080`) unless you maintain a
  separate enrollment path for proxied hostnames.

### 5. Operational checks

```bash
curl -fsS https://skotiq.observatory.local/api/info | jq .version,.fingerprint,.pairingSupported
```

Confirm `fingerprint` matches the value on **Settings → Remote access** before pairing
phones.

## Critical push notifications (LAN UDP + FCM/APNs)

Skotiq fires critical alerts (weather unsafe, sequence failed, guiding lost,
mount runaway) through three independent channels. Each one covers a failure
mode the others can't.

### Channels

| Channel | Reaches | Failure mode it covers |
|---------|---------|------------------------|
| WebSocket `push_notification` | Phones with a live WS connection | Foreground/recently-foreground |
| LAN UDP push (port `45681`) | Phones on the same LAN | WS dropped (Android battery firmware, Wi-Fi roam) |
| FCM / APNs (cellular) | Phones anywhere with network | Phone on cellular, far from the rig |

The LAN UDP push is **automatic** — no operator setup required. FCM/APNs require
project-level Firebase / Apple Developer configuration; see below.

### LAN UDP wire format

```
[0:4]    "NSPP"               magic
[4]      0x01                 protocol version
[5]      severity             0=info, 1=warning, 2=critical
[6:8]    payload length       u16 big-endian
[8:40]   HMAC-SHA256          MAC over payload bytes
[40:N]   payload (JSON)       title, body, id (UUID), timestamp,
                              data, serverFingerprint
```

- Sent on `255.255.255.255:45681` (broadcast) AND `239.255.42.99:45681`
  (multicast) so it works on simple LANs and on networks that block broadcast.
- HMAC key: `SHA-256("skotiq-push-v1:" + serverFingerprint)`. Same value on
  both sides — paired phones already have the fingerprint from the QR code /
  `GET /api/info`.
- Default broadcaster severity floor: `critical`. Configurable.

#### Threat model

Without the HMAC, any LAN host could spoof "WEATHER UNSAFE — PARKING NOW" to
your phone (think coffee-shop Wi-Fi, campground SSID). The HMAC binds each
datagram to the paired server's fingerprint, so only hosts that completed
pairing — i.e., your own desktop — can produce a verifying frame.

What this does **not** defend against:

- Replay (an old verified frame can be replayed). Dedup by the per-frame UUID
  cuts the OS-level duplicate to one notification per id; the OS-level wall
  clock the user sees lets them spot a stale replay visually.
- Confidentiality. Payloads are not encrypted. Lock-screen banners already
  leak the same content. If confidentiality matters, run the rig on a
  wired/VPN LAN.
- A LAN attacker who already paired (they have the fingerprint).

### FCM setup (Android phones on cellular)

Out of scope for this code drop: FCM requires a Firebase project + service
account + per-app device registration. The scaffolding in
`packages/skotiq_remote_protocol/lib/src/push/remote_push_delivery.dart`
defines `FcmRemotePushDelivery` and throws `UnimplementedError` with this
doc reference. To wire it:

1. Create a Firebase project (`console.firebase.google.com`) and download
   the service-account JSON.
2. Add the FCM HTTP-v1 sender to the desktop runtime. Subclass
   `FcmRemotePushDelivery.deliver(frame)` to:
   - Mint an OAuth2 access token from the service account.
   - `POST https://fcm.googleapis.com/v1/projects/<projectId>/messages:send`
     with the per-frame payload, mapping `frame.severity` → FCM `priority`
     (`high` for `critical`/`warning`, `normal` for `info`).
3. On the mobile companion, register the FCM device token. Add a new
   `POST /api/push/register-fcm` endpoint (see the headless API server) that
   stores the token in the paired-device table.
4. Pass the configured instance to
   `HeadlessApiServer.setRemotePushDelivery(...)`.

### APNs setup (iOS phones on cellular)

Out of scope for the same reasons — APNs needs an Apple Developer Program
auth key. The scaffold in `ApnsRemotePushDelivery` throws
`UnimplementedError`. To wire it:

1. Apple Developer console → Keys → generate an APNs auth key (`.p8`). Note
   the Key ID, Team ID, and Bundle ID.
2. Add a JWT signer (ES256) to the desktop runtime. Subclass
   `ApnsRemotePushDelivery.deliver(frame)` to:
   - Sign the per-request JWT with the auth key.
   - `POST https://api.push.apple.com/3/device/<deviceToken>` with the
     per-frame payload, `apns-push-type: alert`, and
     `apns-priority: 10` for `critical`, `5` for everything else.
3. Confirm the mobile companion is built with the Critical Alerts entitlement
   (`com.apple.developer.usernotifications.critical-alerts`); see
   `apps/mobile/ios/CRITICAL_ALERTS_SETUP.md`. Without it, APNs-delivered
   critical alerts fall back to default interruption level and DO NOT bypass
   Do Not Disturb.
4. Pass the configured instance to
   `HeadlessApiServer.setRemotePushDelivery(...)`.

### Trade-offs

- **LAN UDP** works without any cloud account. The phone must be on the same
  Wi-Fi as the rig (or a routed VPN that carries 239.255.42.99 multicast).
  iOS suspends UDP sockets when the app is fully backgrounded — LAN UDP
  primarily helps Android phones and foreground iOS.
- **FCM/APNs** works on cellular and on any LAN, even when the WebSocket
  is dropped, but requires per-deployment operator setup with the cloud
  provider.

### Port assignments (recap)

| Port | Protocol | Purpose |
|------|----------|---------|
| `45679` | UDP | Legacy/broadcast discovery |
| `45680` | TCP | OTA update push receiver (dev → rig) |
| `45681` | UDP | **LAN push notifications (this section)** |

## OTA updates (headless)

The headless API exposes the full OTA update flow so a paired
phone operator can drive updates without physical access to the host.
The endpoints wrap the existing `UpdateService` (HTTPS-pull) and the LAN
push receiver (`LanPushReceiver`, TCP port `45680`); the signing /
verification model is unchanged — manifests are Ed25519-signed and
per-file hashes are checked before any byte hits the install directory.

### Wire summary

| Method | Path | Scope | Audit action |
|--------|------|-------|--------------|
| GET    | `/api/system/version`           | view  | — |
| POST   | `/api/system/update/check`      | admin | — |
| GET    | `/api/system/update/status`     | view  | — |
| POST   | `/api/system/update/download`   | admin | `update_download` |
| POST   | `/api/system/update/apply`      | admin | `update_apply` (high-risk) |
| POST   | `/api/system/update/abort`      | admin | — |
| POST   | `/api/system/update/rollback`   | admin | `update_rollback` (high-risk) |
| GET    | `/api/system/update/staged`     | view  | — |
| DELETE | `/api/system/update/staged`     | admin | `update_discard_staged` |

### Example flows

Check + download + apply (admin scope token in `Authorization: Bearer ...`):

```bash
# 1. Kick off a check job.
curl -X POST -H "Authorization: Bearer $TOKEN" \
  https://rig:8080/api/system/update/check
# -> {"jobId": "abc-...", "status": "queued"}

# 2. Poll job state (also see WS event stream below).
curl -H "Authorization: Bearer $TOKEN" \
  https://rig:8080/api/jobs/abc-...
# -> {"state": "succeeded", "result": {"available": true, "latestVersion": "2.7.0", ...}}

# 3. Start the download. Returns a new jobId for progress tracking.
curl -X POST -H "Authorization: Bearer $TOKEN" \
  https://rig:8080/api/system/update/download

# 4. After UpdateDownloadComplete arrives on the WS, apply.
curl -X POST -H "Authorization: Bearer $TOKEN" \
  https://rig:8080/api/system/update/apply
# Server process may restart; reconnect after the WS drops.
```

### Event broadcast

Update lifecycle is emitted as `SkotiqEvent` with `category: 'system'`
on the existing WebSocket transport (`/api/ws`, `/events`). Event types:

- `UpdateAvailable` — payload `{currentVersion, latestVersion, downloadUrl, releaseNotes, downloadSize}`
- `UpdateDownloadStarted` — `{jobId, version, totalBytes}`
- `UpdateDownloadProgress` — `{jobId, downloadedBytes, totalBytes, pct}`
- `UpdateDownloadComplete` — `{jobId, stagedPath, version}`
- `UpdateVerificationFailed` — `{jobId, reason, expectedHash?, actualHash?}`
- `UpdateApplyStarted` — `{jobId, version}`
- `UpdateApplied` — `{fromVersion, toVersion, restartRequired}`
- `UpdateFailed` — `{jobId?, phase, error}`

`UpdateAvailable` is also routed through `PushNotificationService`, so a
paired phone gets a `type: 'push_notification'` envelope on the WS
("Skotiq 2.7.0 available — open Settings > Updates to install"). The
other variants are operator-driven and don't escalate to push.

### LAN push (port 45680)

The headless daemon also starts a `LanPushReceiver` on TCP `45680` when
the build embeds a trusted public key (`--dart-define=SKOTIQ_UPDATE_PUBLIC_KEY=...`).
This lets a dev machine push a signed update package directly to the rig
without going through an update server. See
`packages/skotiq_updater/lib/src/services/lan_push_receiver.dart` for
the wire protocol (4-byte length prefix + JSON auth frame, then manifest +
package bytes).

### Rollback

`UpdateService.rollbackToPrevious()` performs a real manual rollback by
relaunching the external updater in `--rollback` mode, which restores the
previous version's files from the retained restore point
(`updates/backup/rollback_log.json` + the `restore_point/` originals the
last successful apply left behind). This reuses the same move-then-restore
machinery the boot verifier uses to auto-roll-back a failed update.

A rollback is only possible **while that restore point exists** — i.e.
after an update is applied and before the next launch confirms it healthy
(the boot verifier reclaims the backup dir once the new build proves
stable). `UpdateController.rollbackSupported()` probes for the restore
point; when none is present, `POST /api/system/update/rollback` returns
**501 Not Implemented** (`error: rollback_unavailable`). Otherwise it
dispatches a rollback job; the host process restarts during the rollback,
so clients should reconnect after the WS drops.

## Firewall

See [troubleshooting/firewall.md](troubleshooting/firewall.md). Minimum for LAN companions:
inbound TCP on the configured API port (default `8080`).

For LAN push notifications, also allow inbound UDP on `45681` on the phone's
operating system if it has its own firewall (typical on rooted Android or
managed enterprise iOS).

For LAN push updates (dev-machine -> rig), allow inbound TCP on `45680`.

## Catalog management (headless)

A freshly imaged server (new Raspberry Pi install, or server reinstall) has
no star/DSO catalogs on disk. Plate solving will fail and target search will
return nothing until catalogs are downloaded. The headless API exposes a
full management surface so a remote operator can populate the
server's catalog directory without SSH or the local GUI.

### Catalogs the server knows how to install

| Name         | Source                                          | Size (decompressed) | Plate-solve? |
| ------------ | ----------------------------------------------- | ------------------- | ------------ |
| `stars`      | HYG v4.2 (Codeberg, gzipped CSV)                | ~35 MB              | **required** |
| `dso`        | OpenNGC NGC/IC (GitHub raw, CSV)                | ~5 MB               | optional     |
| `annotation` | GLADE+ standard tier (VizieR TAP, CSV)          | ~50 MB              | optional     |

Plate solving requires `stars` at minimum. `dso` is what powers
catalog-name target search (M31, NGC7000, etc.).

### Endpoints

All `/api/catalog/*` routes are JSON. `download`, `upload`, `verify`,
`reload`, and DELETE require **admin** scope; `status` and `available`
are **view** scope. All mutating ops are audited.

| Method | Path                          | Scope | Audit action       |
| ------ | ----------------------------- | ----- | ------------------ |
| GET    | `/api/catalog/status`         | view  | —                  |
| GET    | `/api/catalog/available`      | view  | —                  |
| POST   | `/api/catalog/download`       | admin | `catalog_download` |
| POST   | `/api/catalog/upload`         | admin | `catalog_upload`   |
| POST   | `/api/catalog/verify`         | admin | `catalog_verify`   |
| POST   | `/api/catalog/reload`         | admin | —                  |
| DELETE | `/api/catalog/<name>`         | admin | `catalog_delete`   |

### Download flow (online server)

1. `POST /api/catalog/download` body `{"name": "stars"}` →
   `{ "jobId": "...", "state": "queued", "operation": "catalog.download" }`.
2. Subscribe to the WS event stream and filter `category == "catalog"`.
   Progress events arrive as `CatalogDownloadProgress` with
   `{ jobId, name, downloadedBytes, totalBytes, pct }` at ~1 Hz.
3. Completion fires `CatalogDownloadComplete` with the recorded SHA-256.
4. `GET /api/catalog/status` now reports `status: "installed"` for the
   catalog. The server's plate-solve service picks up the new catalog
   on the next solve attempt (no restart required).

The download path streams into a temp file, decompresses (gzip when the
upstream URL ends in `.gz`), computes SHA-256 over the decompressed
bytes, then atomically renames into the catalog directory. A failed
download leaves no partial file behind.

### Hash verification

Every install (download or upload) records the SHA-256 of the
decompressed file in a metadata sidecar (`<name>_metadata.json`).
`POST /api/catalog/verify` (optionally with `{"name": "stars"}`) streams
the file from disk, recomputes SHA-256, and compares against the
recorded hash. The response is:

```json
{
  "verified": {
    "stars": {
      "ok": true,
      "expectedHash": "abc...",
      "actualHash": "abc..."
    },
    "dso": { "ok": false, "errors": ["not_installed"] }
  }
}
```

Verify also updates the `lastVerified` field in the sidecar so the
status endpoint can show the most-recent check time.

### Air-gap upload (offline server)

When the server has no outbound internet (locked-down observatory
network, etc.) an operator can fetch the catalog file out-of-band and
push it to the server with `POST /api/catalog/upload`:

```bash
# Compute the local SHA-256 first.
SHA=$(sha256sum NGC.csv | cut -d' ' -f1)
curl -X POST \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/octet-stream" \
  --data-binary @NGC.csv \
  "https://server:9001/api/catalog/upload?name=dso&sha256=$SHA"
```

The server computes SHA-256 of the uploaded bytes and rejects with HTTP
400 + `{"error":"sha256_mismatch","expected":..,"actual":..}` if it
does not match. The 1 GiB body cap covers HYG and OpenNGC trivially;
operators wanting the full GLADE+ tier (~2 GB) must stage it manually
to the catalog directory and call `POST /api/catalog/reload`.

### Reload

If files were placed in the catalog directory out-of-band (manual
`scp`, restoring from a backup, etc.) call `POST /api/catalog/reload`
to drop the server's cached loaders so subsequent searches re-parse
the new files.

### Uninstall

`DELETE /api/catalog/<name>` removes the data file + metadata sidecar.
`status` will report `missing` afterwards; subsequent plate solves
against a removed catalog will fail with a clear error (per the
CONTRIBUTING.md "errors are a feature" house rule).

## Further reading

- [docs/api/web-server-api.md](api/web-server-api.md) — route catalog
- [docs/headless-secure-setup.md](headless-secure-setup.md) — tokens and bind modes
- [packages/skotiq_remote_protocol/SECURITY.md](../packages/skotiq_remote_protocol/SECURITY.md) — pairing and scope policy
- [RUNBOOK.md](RUNBOOK.md) — field diagnostics
