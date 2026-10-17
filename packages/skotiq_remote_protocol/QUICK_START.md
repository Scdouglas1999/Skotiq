# Quick start

This package provides LAN discovery, pairing, and token management for the
Skotiq remote control plane. The control plane itself is `HeadlessApiServer`
(`apps/desktop/lib/headless_api_server.dart`) speaking REST + WebSocket with
bearer tokens.

[INTEGRATION.md](INTEGRATION.md) is the full guide; this page is the five-minute
version. [SECURITY.md](SECURITY.md) covers the threat model and scopes.

## Desktop: the server is already wired

Remote access is a toggle in **Settings → Remote access**. Nothing in this
package needs to be started by hand — the desktop bootstrap owns the server,
the mDNS advertisement (`mdns_registration.dart`), and the pairing database.

Show the operator the fingerprint and QR from that screen. `/api/info` reports
the same fingerprint, so a client can confirm it before trusting the host.

## Mobile: find a server

```dart
final server = await EnhancedSkotiqDiscovery.discoverWithFallback(
  onStatus: (msg) => print(msg),
);
if (server == null) return;

final info = await EnhancedSkotiqDiscovery.fetchServerInfo(server);
final target = info ?? server;
```

Manual entry defaults to port **8080**.

## Mobile: pair

Scan the desktop QR, parse it strictly, then exchange the pairing code for a
bearer token:

```dart
final data = QrConnectionData.parseStrict(scannedPayload);
// Confirm data.fingerprint with the operator before continuing.

final result = await RemotePairingClient(
  host: data.host,
  port: data.webPort,
).verify(
  code: data.pairingCode!,
  deviceId: await MobilePairingService.deviceId(),
  deviceName: MobilePairingService.deviceName(),
  requestedScope: 'control',
);
```

Send `Authorization: Bearer ${result.token}` on every subsequent request.
Paired phones get the `control` scope: sequencer, devices, imaging — not backup
upload or filesystem browsing. See the scope table in INTEGRATION.md.

## Mobile: subscribe to events

Never put a long-lived bearer token in a WebSocket query string. Mint a
single-use ticket instead:

1. `POST /api/ws/ticket` with the bearer token.
2. Connect `ws://host:port/events?ticket=<ticket>`.

## Where the pieces live

| Concern | Type |
|---|---|
| Find a host on the LAN | `EnhancedSkotiqDiscovery`, `DiscoveredServer` |
| Parse and validate a pairing QR | `QrConnectionData` |
| Exchange a code for a token | `RemotePairingClient` |
| Issue / verify / revoke tokens (desktop) | `TokenManager`, `PairingDatabase` |
| Confirm host identity | `computeServerFingerprint` |
| Version negotiation | `SkotiqServerCompatibility` |
| Push alerts to paired phones | `push/lan_push_broadcaster.dart` |

## Troubleshooting

**Discovery finds nothing.** Check that UDP broadcast is allowed on the
network — client isolation on guest Wi-Fi blocks it. Fall back to manual
`host:8080` entry.

**The pairing code is rejected.** Codes expire after five minutes and are
single-use. `POST /api/pairing/start` deliberately does not return the code in
its HTTP response; read it from the desktop screen.

**A request returns 403.** The token's scope is lower than the route requires.
Re-pair with `requestedScope: 'admin'` only if the device genuinely needs
backups or filesystem access.

## Tests

- `test/remote_pairing_client_test.dart`
- `apps/desktop/test/headless_api/pairing_handlers_test.dart`
