# Remote protocol integration guide

This guide describes how to integrate **LAN discovery, pairing, and REST/WebSocket
remote control** with Skotiq 2.5+. It replaces the legacy WebRTC-oriented
integration doc.

## Architecture

```
Desktop (HeadlessApiServer :8080)
    ↑ HTTP / WS + Bearer token
Mobile / scripts / dashboard
```

Package exports (see `lib/skotiq_remote_protocol.dart`):

- `EnhancedSkotiqDiscovery`, `DiscoveredServer`, `QrConnectionData`
- `RemotePairingClient`
- `computeServerFingerprint`, `SkotiqServerCompatibility`
- `TokenManager`, `PairingDatabase` (desktop GUI pairing UI)

## Desktop: enable remote access

Remote access is toggled in **Settings → Remote access**. The embedded server is
`HeadlessApiServer` with the persistent desktop admin token plus paired-session
tokens.

When the server is running, `/api/info` includes:

```json
{
  "version": "2.6.0",
  "apiVersion": "2.6.0",
  "pairingSupported": true,
  "fingerprint": "<sha256-hex>",
  "authRequired": true
}
```

Show the operator the **fingerprint** and QR from Remote access (uses
`generateQrData()` with LAN IP, port, version, fingerprint, and active
`pairingCode`).

## Mobile: discovery

```dart
final server = await EnhancedSkotiqDiscovery.discoverWithFallback(
  onStatus: (msg) => print(msg),
);
if (server == null) return;

final info = await EnhancedSkotiqDiscovery.fetchServerInfo(server);
final target = info ?? server;
```

Default manual port: **8080** (`host:8080`).

## Mobile: pairing (no pre-shared admin token)

### A. QR with embedded pairing code

1. Desktop starts pairing; QR includes `pairingCode`.
2. Mobile scans → `QrConnectionData.parseStrict` → confirm fingerprint sheet.
3. Mobile calls verify:

```dart
final client = RemotePairingClient(host: data.host, port: data.webPort);
final result = await client.verify(
  code: data.pairingCode!,
  deviceId: await MobilePairingService.deviceId(),
  deviceName: MobilePairingService.deviceName(),
  requestedScope: 'control', // or 'admin' when operator opts in
);
final token = result.token;
```

4. Connect `NetworkBackend` with `Authorization: Bearer $token`.

### B. Manual code entry

```dart
await RemotePairingClient(host: host, port: port).start(); // optional; desktop usually starts
final result = await RemotePairingClient(host: host, port: port).verify(
  code: operatorEnteredCode,
  deviceId: deviceId,
  deviceName: 'My Phone',
);
```

`POST /api/pairing/start` does not return the code in the HTTP response; read it
from the desktop UI.

### C. QR with `authToken` (legacy / break-glass)

If the QR includes `authToken`, the mobile app may connect directly after
fingerprint confirmation. Prefer `pairingCode` for routine enrollment.

## WebSocket

After obtaining a bearer token:

1. `POST /api/ws/ticket` with `Authorization: Bearer <token>`
2. Connect `ws://host:port/events?ticket=<ticket>` (see `docs/api/web-server-api.md`)

Do not pass long-lived bearer tokens in WebSocket query strings.

## Scopes

| Scope | Typical use |
|-------|-------------|
| `view` | Read-only monitoring |
| `control` | **Default for paired phones** — sequencer, devices, imaging |
| `admin` | Backups, filesystem, destructive maintenance — CLI/desktop token or explicit `requestedScope: admin` at verify |

## TLS

The Shelf server speaks plain HTTP. For TLS, terminate at nginx — full example in
[docs/remote-control.md](../../docs/remote-control.md).

## Tests

- `packages/skotiq_remote_protocol/test/remote_pairing_client_test.dart`
- `apps/desktop/test/headless_api/pairing_handlers_test.dart`
