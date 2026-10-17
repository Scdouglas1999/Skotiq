# Headless Secure Setup

Skotiq headless mode runs the desktop backend without the Flutter UI and
exposes the remote-control API for browser, mobile, and automation clients.
Treat it like rig-control infrastructure: bind narrowly by default, require a
token before LAN exposure, and verify the server before connecting devices.

## Network Modes

| Mode | Binding | Authentication | Intended Use |
|------|---------|----------------|--------------|
| Local loopback | `127.0.0.1` | Fail closed unless a token is configured; pairing/dashboard always reachable | Same-machine automation, reverse proxy, development |
| Authenticated LAN | LAN interface | Required | Mobile or browser control from trusted LAN clients |
| Unauthenticated LAN | LAN interface | None — requires explicit `--allow-unauthenticated` **and** `--allow-unauthenticated-lan` | Isolated development networks only |

The headless entry point binds to loopback unless one of these is true:

- `--auth-token=<token>` is provided.
- `SKOTIQ_AUTH_TOKEN` is set.
- `--require-auth` is provided, which generates a token at startup.
- `--allow-unauthenticated-lan` or
  `SKOTIQ_ALLOW_UNAUTHENTICATED_LAN=true` is provided.

Do not use unauthenticated LAN mode for normal imaging. It exposes control
commands such as slew, park, device connect, sequence start, and backup restore
to any client that can reach the port.

## Authentication Posture (Fail Closed by Default)

When no token is configured the server **fails closed**: privileged endpoints
(control, status, OpenAPI, backup, OTA) return `401`, and only the onboarding
surface — pairing (`/api/pairing/*`), discovery (`/api/info`), and the static
dashboard — is reachable. A fresh appliance is still bootstrapped normally: a
client pairs out-of-band, `POST /api/pairing/verify` mints a bearer token, and
that token unlocks the privileged endpoints. So an unconfigured server is safe by
default rather than wide open.

To intentionally serve **everything** without authentication (isolated
development networks only), opt in explicitly:

- `--allow-unauthenticated`, or
- `SKOTIQ_ALLOW_UNAUTHENTICATED=true`.

The server logs a prominent warning at startup when this is set. Authentication
(`--allow-unauthenticated`) and network exposure (`--allow-unauthenticated-lan`)
are independent: serving open *on the LAN* requires **both** flags — a deliberate
two-key requirement for the dangerous combination.

> **Upgrade note:** earlier builds served all endpoints open when no token was
> configured. They now fail closed. Configure a token (recommended) or pass
> `--allow-unauthenticated` to restore the previous open behavior on an isolated
> network.

## Start Headless Mode

Development run:

```powershell
flutter run -d windows --target=lib/main_headless.dart -- --require-auth
```

Packaged Windows run:

```powershell
.\build\windows\x64\runner\Release\skotiq_desktop.exe --headless --require-auth
```

Packaged Linux run:

```bash
./build/linux/<arch>/release/bundle/skotiq_desktop --headless --require-auth
```

Use a fixed token when clients need a stable credential:

```powershell
$env:SKOTIQ_AUTH_TOKEN = "replace-with-a-long-random-token"
$env:SKOTIQ_PORT = "8080"
.\skotiq_desktop.exe --headless
```

## Client Authentication

REST clients send the token as a bearer token:

```http
Authorization: Bearer replace-with-a-long-random-token
```

Headless mode supports three token scopes:

| Scope | Intended use | Allowed access |
| --- | --- | --- |
| `view` | Dashboards and monitoring clients | Read ordinary status endpoints and subscribe to WebSocket events. |
| `control` | Imaging-control clients | View access plus device, capture, mount, guider, sequencer, dome, safety, switch, and cover control routes. |
| `admin` | Trusted operators and maintenance tools | Full protected API access, including self-test, settings, file browsing, and backup/restore. |

The legacy `--auth-token` and `SKOTIQ_AUTH_TOKEN` values are admin tokens.
Use narrower tokens for clients that do not need administrative access:

```powershell
$env:SKOTIQ_VIEW_TOKEN = "replace-with-a-long-random-view-token"
$env:SKOTIQ_CONTROL_TOKEN = "replace-with-a-long-random-control-token"
.\skotiq_desktop.exe --headless --auth-token=replace-with-a-long-random-admin-token
```

Equivalent CLI flags are available:

```powershell
.\skotiq_desktop.exe --headless `
  --auth-token=replace-with-a-long-random-admin-token `
  --view-token=replace-with-a-long-random-view-token `
  --control-token=replace-with-a-long-random-control-token
```

WebSocket clients may use the same bearer header when the platform supports it.
Browser-style WebSocket clients can pass the token as a query parameter:

```text
ws://host:8080/events?token=replace-with-a-long-random-token
```

`GET /api/info` and dashboard static files are public so clients can discover
server metadata and load the local dashboard. Control, status, OpenAPI,
self-test, WebSocket, backup, file browsing, and device routes require an
appropriately scoped token when authentication is enabled.

## Firewall And Ports

Allow only the ports needed for the deployment:

| Port | Protocol | Purpose |
|------|----------|---------|
| `8080` or `SKOTIQ_PORT` | TCP | REST API, dashboard, WebSocket updates |
| `45679` | UDP | LAN discovery advertisement when LAN binding is enabled |

Keep the TCP API port blocked from untrusted networks. If exposing Skotiq
through a VPN or reverse proxy, terminate TLS at that layer and keep the
headless server bound to loopback when possible.

## Headless Storage

For systemd, Docker, and Raspberry Pi appliance deployments, keep application
state under the daemon-owned state directory:

```bash
SKOTIQ_DATA_DIR=/var/lib/skotiq/data
SKOTIQ_DATABASE_DIR=/var/lib/skotiq/database
```

`SKOTIQ_DATA_DIR` is the native persistence root for generated data such as
defect maps. `SKOTIQ_DATABASE_DIR` pins the Drift database outside any user
Documents folder. Capture output, backups, and exports can still be pointed at
operator-selected storage such as an external imaging disk.

Remote clients can browse only allow-listed directories. Add external capture
disks with `SKOTIQ_BROWSE_ROOTS`:

```bash
SKOTIQ_BROWSE_ROOTS="Captures=/mnt/captures;USB SSD=/media/skotiq"
```

In the hardened systemd unit, any external write target must also be listed in
`ReadWritePaths` or a drop-in because `ProtectSystem=strict` is enabled.

## Linux Device Access

Bare-metal and Raspberry Pi appliance installs include
`/etc/udev/rules.d/99-skotiq-astro.rules`. The rule grants `0660` access to
the `skotiq` service group, plus logind `uaccess`, for common astronomy USB
camera/filter-wheel vendors and USB-serial mount adapters. This replaces the
world-writable `0666` rules many vendor SDKs suggest.

The rule covers baseline permissions only. Some QHY-class devices still need
vendor firmware packages or INDI packages for firmware upload, and native SDK
support still depends on shipping the correct `.so` files for the host CPU.
After changing rules or groups, reload udev and reconnect devices:

```bash
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=usb --subsystem-match=tty --subsystem-match=hidraw
```

## Verification Checklist

1. Confirm `/api/info` reports the expected version, platform, auth mode, and
   platform capabilities:

   ```powershell
   Invoke-RestMethod http://localhost:8080/api/info
   ```

2. Confirm authenticated endpoints reject missing credentials:

   ```powershell
   Invoke-WebRequest http://localhost:8080/api/self-test
   ```

   A protected server should return `401 Unauthorized`.

3. Confirm the token works:

   ```powershell
   Invoke-RestMethod `
     -Headers @{ Authorization = "Bearer replace-with-a-long-random-token" } `
     http://localhost:8080/api/self-test
   ```

4. Confirm the OpenAPI route document is available to authenticated clients:

   ```powershell
   Invoke-RestMethod `
     -Headers @{ Authorization = "Bearer replace-with-a-long-random-token" } `
     http://localhost:8080/api/openapi.json
   ```

5. Confirm mobile or browser clients reject incompatible server versions before
   entering remote-control mode.

6. Confirm WebSocket clients send `ping`, receive `pong`, and reconnect after a
   heartbeat timeout.

7. On Linux/Pi appliances, confirm the daemon can see plugged-in rig devices:

   ```bash
   lsusb
   ls -l /dev/ttyUSB* /dev/ttyACM* 2>/dev/null || true
   sudo -u skotiq groups
   ```

## Operational Notes

- Use long random tokens and rotate them when a client device is lost.
- Give monitoring clients `view` tokens instead of admin tokens.
- Prefer a dedicated observatory VLAN, VPN, or local-only reverse proxy for
  remote access.
- Keep the machine clock, site location, storage path, and device drivers
  configured before starting an unattended sequence.
- Run `/api/self-test` after updates and before hardware smoke tests.
- Review audit logs for high-risk remote commands after remote sessions.
