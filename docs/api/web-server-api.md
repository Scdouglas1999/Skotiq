# Web Server API Reference

The Skotiq Web Server provides a REST API for remote control of the desktop application. This allows mobile devices and other clients to control Skotiq over the network.

## Overview

The web server runs on port 8080 by default and provides both REST API endpoints and WebSocket support for real-time updates.

**Base URL:** `http://localhost:8080`

## WebSocket Heartbeat

Remote clients connect to `/events` or `/api/ws` for real-time updates. Clients
send JSON heartbeat messages periodically:

```json
{
  "type": "ping",
  "timestamp": "2026-05-05T00:00:00Z"
}
```

The server replies:

```json
{
  "type": "pong",
  "timestamp": "2026-05-05T00:00:00Z"
}
```

Mobile and network clients treat a socket as stale when no WebSocket message,
including `pong`, arrives before the heartbeat timeout. A stale socket is closed
and the normal reconnect backoff starts.

## Server Information

### GET /api/info

Get server information and capabilities.

**Response:**
```json
{
  "status": "running",
  "version": "2.6.0",
  "apiVersion": "2.6.0",
  "apiOnlyMode": true,
  "webUIAvailable": false,
  "timestamp": "2025-11-30T12:00:00Z",
  "platformCapabilities": {
    "platform": "windows",
    "drivers": [
      {
        "backend": "ascom",
        "label": "ASCOM COM",
        "status": "available",
        "supportedPlatforms": ["windows"],
        "unsupportedReason": null,
        "deviceCoverage": "Camera, mount, focuser, filter wheel, rotator, dome, weather, safety monitor, switch, cover/calibrator"
      },
      {
        "backend": "native",
        "label": "Native SDK",
        "status": "capability-gated",
        "supportedPlatforms": ["windows", "linux", "macos"],
        "unsupportedReason": null,
        "deviceCoverage": "Vendor cameras and native mount protocols where SDKs are installed."
      }
    ]
  },
  "endpoints": [
    "GET /api/info",
    "GET /api/status",
    "GET /api/self-test",
    "GET /api/openapi.json",
    "GET /api/devices",
    "POST /api/devices/connect",
    "POST /api/devices/disconnect",
    "GET /api/devices/connected",
    "POST /api/phd2/connect",
    "POST /api/phd2/disconnect",
    "GET /api/sequencer/status",
    "POST /api/sequencer/start",
    "POST /api/sequencer/stop",
    "GET /api/images/recent"
  ]
}
```

## Version Compatibility

Remote clients use `/api/info.apiVersion` for API compatibility checks before
switching into network-control mode. The `version` field is the application
release version shown to operators. Clients fall back to `version` when talking
to older servers that do not advertise `apiVersion`. The current client accepts
Skotiq server API versions `2.4.0` and newer within major version `2`.
Servers older than `2.4.0`, servers with an unknown/malformed version, and
servers with a newer major API version are rejected with user-facing "server
too old/new" guidance.

## Authentication Scopes

When authentication is enabled, tokens can be scoped:

| Scope | Access |
| --- | --- |
| `view` | Ordinary read endpoints and WebSocket event subscriptions. |
| `control` | View access plus imaging and device-control routes. |
| `admin` | Full protected API access, including settings, self-test, file browsing, and backup/restore. |

The legacy `--auth-token` and `SKOTIQ_AUTH_TOKEN` values are admin tokens.
Optional `SKOTIQ_VIEW_TOKEN`, `SKOTIQ_CONTROL_TOKEN`, `--view-token`,
and `--control-token` values can grant narrower access.

### GET /api/status

Get server status.

**Response:**
```json
{
  "status": "running",
  "version": "2.6.0",
  "timestamp": "2025-11-30T12:00:00Z"
}
```

### GET /api/self-test

Run a non-invasive headless runtime self-test. This endpoint is authenticated
whenever the server requires authentication. It reports platform details, auth
and bind mode, backend type, driver availability, storage path writability, and
API route count without connecting to hardware.

**Response:**
```json
{
  "status": "ok",
  "timestamp": "2026-05-05T00:00:00Z",
  "platform": {
    "operatingSystem": "windows",
    "operatingSystemVersion": "Windows 10 ...",
    "executable": "C:\\Program Files\\Skotiq\\skotiq.exe"
  },
  "server": {
    "port": 8080,
    "bindMode": "loopback",
    "authMode": "token",
    "authRequired": true,
    "dashboardAvailable": true
  },
  "backend": {
    "type": "FfiBackend",
    "connectedDevices": {
      "status": "ok",
      "count": 0,
      "devices": []
    }
  },
  "deviceDrivers": {
    "platform": "windows",
    "drivers": [
      {
        "backend": "ascom",
        "label": "ASCOM COM",
        "status": "available",
        "supportedPlatforms": ["windows"],
        "unsupportedReason": null
      }
    ]
  },
  "storagePaths": [
    {
      "name": "applicationDocuments",
      "status": "ok",
      "path": "C:\\Users\\user\\Documents",
      "exists": true,
      "writable": true
    }
  ],
  "database": {
    "name": "driftDatabase",
    "status": "ok"
  },
  "api": {
    "endpointCount": 120,
    "selfTestEndpoint": "GET /api/self-test"
  }
}
```

### GET /api/openapi.json

Return a minimal OpenAPI 3.0 document generated from the server route table.
The generated spec includes every HTTP route returned by `/api/info.endpoints`
and excludes WebSocket-only routes.

**Response:**
```json
{
  "openapi": "3.0.3",
  "info": {
    "title": "Skotiq Headless API",
    "version": "2.6.0"
  },
  "servers": [
    {"url": "http://localhost:8080"}
  ],
  "paths": {
    "/api/info": {
      "get": {
        "summary": "GET /api/info",
        "tags": ["core"]
      }
    }
  }
}
```

## Device Management

### GET /api/devices

List all available and connected devices.

**Response:**
```json
{
  "devices": [
    {
      "id": "camera-1",
      "name": "ZWO ASI294MC Pro",
      "deviceType": "camera",
      "driverType": "native",
      "description": "ZWO Camera",
      "driverVersion": "1.0.0"
    }
  ],
  "connected": {
    "camera": "camera-1",
    "mount": null,
    "focuser": null,
    "filterWheel": null,
    "rotator": null
  },
  "available": [...]
}
```

### POST /api/devices/connect

Connect to a device.

**Request Body:**
```json
{
  "deviceType": "camera",
  "deviceId": "camera-1"
}
```

**Response:**
```json
{
  "status": "connected",
  "deviceId": "camera-1"
}
```

### POST /api/devices/disconnect

Disconnect from a device.

**Request Body:**
```json
{
  "deviceType": "camera",
  "deviceId": "camera-1"
}
```

**Response:**
```json
{
  "status": "disconnected",
  "deviceId": "camera-1"
}
```

### GET /api/devices/connected

Get list of currently connected devices.

**Response:**
```json
{
  "devices": [
    {
      "id": "camera-1",
      "name": "ZWO ASI294MC Pro",
      "deviceType": "camera",
      "driverType": "native"
    }
  ]
}
```

## Equipment Capabilities

These endpoints expose per-device capability responses for connected hardware or
simulator-backed devices. The top-level `/api/info.platformCapabilities` matrix
reports platform/backend availability for ASCOM COM, Alpaca, INDI, native SDK,
and simulator backends; each equipment capability response is device-specific
and should be used by clients to disable unsupported controls or parameter
ranges after a device is selected.

Available capability endpoints:

- `GET /api/equipment/camera/capabilities?deviceId=<id>`
- `GET /api/equipment/mount/capabilities?deviceId=<id>`
- `GET /api/equipment/focuser/capabilities?deviceId=<id>`
- `GET /api/equipment/filter-wheel/capabilities?deviceId=<id>`
- `GET /api/equipment/rotator/capabilities?deviceId=<id>`

If a device is missing or capabilities are unavailable, the endpoint returns a
JSON error. Clients should treat that as capability unknown and keep controls
disabled until a successful capability response is available.

**Example camera response:**
```json
{
  "deviceId": "camera-1",
  "maxWidth": 4144,
  "maxHeight": 2822,
  "pixelSizeX": 4.63,
  "pixelSizeY": 4.63,
  "canCool": true,
  "hasShutter": false,
  "supportedBinning": ["1x1", "2x2"]
}
```

## PHD2 Guiding

### POST /api/phd2/connect

Connect to PHD2.

**Request Body (optional):**
```json
{
  "host": "localhost",
  "port": 4400
}
```

**Response:**
```json
{
  "status": "connected"
}
```

### POST /api/phd2/disconnect

Disconnect from PHD2.

**Response:**
```json
{
  "status": "disconnected"
}
```

## Sequence Control

### GET /api/sequencer/status

Get sequence status.

**Response:**
```json
{
  "state": "running",
  "currentNodeId": "node-1",
  "currentNodeName": "Exposure",
  "totalExposures": 100,
  "completedExposures": 45,
  "totalIntegrationSecs": 3600.0,
  "elapsedSecs": 1620.0,
  "estimatedRemainingSecs": 1980.0,
  "currentTarget": "M42",
  "currentFilter": "L",
  "message": "Exposing frame 45/100"
}
```

### POST /api/sequencer/start

Start a sequence.

**Request Body (optional):**
```json
{
  "sequenceId": "seq-1",
  "targetName": "M42"
}
```

**Response:**
```json
{
  "status": "started",
  "sequenceId": "seq-1"
}
```

### POST /api/sequencer/stop

Stop current sequence.

**Response:**
```json
{
  "status": "stopped"
}
```

## Image Management

### GET /api/images/recent

List recent images.

**Query Parameters:**
- `limit` (optional) - Maximum number of images to return

**Response:**
```json
{
  "images": [
    {
      "id": "img-1",
      "filename": "M42_L_001.fits",
      "path": "/path/to/image.fits",
      "timestamp": "2025-11-30T12:00:00Z",
      "exposureTime": 60.0,
      "filter": "L",
      "target": "M42"
    }
  ],
  "count": 10
}
```

## Darkroom Delivery (peer pull)

A rig publishes each dawn job's artifacts for a paired desktop to collect. The
rig never uploads to a peer: artifacts are served by authenticated GET with RFC
7233 `Range`/`If-Range`/`ETag`, so a desktop resumes a multi-gigabyte master
rather than restarting it.

Every request identifies the calling machine with the `peer` id configured on
the rig's delivery destination. A manifest is per peer; an id from one peer's
manifest does not resolve for another.

### GET /api/darkroom/delivery/manifest/{jobId}?peer={peerId}

The signed list of what this job published for that peer.

```json
{
  "manifest": {
    "version": 1,
    "jobId": 12,
    "peerId": "office-pc",
    "generatedAt": "2026-08-16T06:12:30.000Z",
    "entries": [
      {
        "artifactId": "<sha256 of the rig-side path>",
        "targetId": 3,
        "fileName": "M31_Ha_master.fits",
        "bytes": 4194304000,
        "checksum": "<sha256 of the bytes>"
      }
    ],
    "unavailable": []
  },
  "signature": {"algorithm": "hmac-sha256-token-v1", "value": "<hex>"}
}
```

`signature` is an HMAC over the manifest's canonical (recursively key-sorted)
JSON under a key derived from the calling token's digest, which a paired client
re-derives from the token it holds. A server running with no token configured
answers with `"signature": null` and a `signatureAbsentReason`; a client that
authenticated with a token treats that as a refusal.

`unavailable` lists files the job published that the rig cannot serve right
now, each with the reason — an absence stated rather than an entry omitted.

`404 unknown_delivery_peer` when no enabled peer destination carries that peer
id.

### GET /api/darkroom/delivery/artifact/{jobId}/{artifactId}?peer={peerId}

The bytes. Answers `200` with `accept-ranges: bytes` and a strong `etag`,
`206` with `content-range` for a satisfiable single range, and `416` with
`content-range: bytes */N` for anything malformed, multi-range or out of
bounds. `artifactId` comes from the manifest and resolves only through the
journal rows this job published for this peer; a path used as an id is a `404`.

### POST /api/darkroom/delivery/ack/{jobId}

```json
{"peerId": "office-pc", "artifactId": "<from the manifest>", "checksum": "<sha256>"}
```

Records that the file arrived and verified, which is what turns the rig's
journal row from awaiting-pull into delivered — the rig served bytes, and only
the puller knows they landed intact. `409 checksum_mismatch` when the
acknowledged digest is not the one the rig's own copy hashes to.

## WebSocket Support

### WebSocket Connection

Connect to `/events` (preferred) or `/api/ws` for real-time updates.

**Connection:**
```javascript
const ws = new WebSocket('ws://localhost:8080/events?ticket=<ticket>');
```

Authentication options (in order of preference):

| Query parameter | Notes |
| --- | --- |
| `?ticket=<value>` | One-shot 60-second ticket from `POST /api/ws/ticket`. Preferred — does not leak the bearer to HTTP/proxy logs. |
| `?token=<bearer>` | Legacy; still accepted with a deprecation warn-log. |

**Ping / Pong:**

```json
{ "type": "ping" }
```

Server responds with `{ "type": "pong" }`. The server also sends unsolicited
pings; clients must respond with a `pong` carrying an ISO-8601 `timestamp` or
the connection will be closed after the heartbeat window elapses.

### Server-pushed event envelope

Every server-pushed event is encoded as:

```json
{
  "type": "event",
  "timestamp": 1746816000000,
  "severity": "info",            // info | warning | error | critical
  "category": "guiding",         // see below
  "eventType": "GuideStep",
  "data": { /* event-specific payload */ }
}
```

Categories: `equipment`, `imaging`, `guiding`, `sequencer`, `safety`, `system`,
`polarAlignment`.

### Event payloads (selected)

The full list of `eventType` strings is large; the most commonly consumed
payloads are documented here. Unspecified fields are reserved for future use.

#### `category: guiding`

| eventType | Payload fields |
| --- | --- |
| `Connected` | `{}` |
| `Disconnected` | `{}` |
| `GuidingStarted` | `{}` |
| `GuidingStopped` | `{}` |
| `Paused` | `{}` |
| `Resumed` | `{}` |
| `Settled` | `{ "rms": number }` |
| `Settling` | `{}` |
| `LoopingExposures` | `{}` |
| `Calibrating` | `{}` |
| `CalibrationComplete` | `{}` |
| `DitherStarted` | `{ "pixels": number }` |
| `DitherCompleted` | `{}` |
| `StarLost` | `{}` |
| `StarSelected` | `{ "X": number, "Y": number }` |
| `AppState` | `{ "State": string }` |
| `GuideStats` | `{ "SNR": number, "StarMass": number }` |
| `GuideStep` | `{ "raPx": number, "decPx": number, "RADistanceRaw": number, "DECDistanceRaw": number, "RADistance": number, "DECDistance": number }` |

`GuideStep.raPx` / `decPx` are the canonical pixel offsets emitted alongside
the legacy PHD2 field names. Clients should prefer the canonical names;
older clients consuming `RADistanceRaw` / `DECDistanceRaw` continue to work.

#### `category: sequencer`

| eventType | Payload fields |
| --- | --- |
| `Started` | `{ "sequence_name": string }` |
| `Paused` | `{}` |
| `Resumed` | `{}` |
| `Stopped` | `{}` |
| `Completed` | `{}` |
| `NodeStarted` | `{ "node_id": string, "node_type": string }` |
| `NodeCompleted` | `{ "node_id": string, "status": "success"\|"failed"\|"cancelled"\|"skipped" }` |
| `Progress` | `{ "current": int, "total": int }` |
| `TargetChanged` | `{ "target_name": string, "ra": number?, "dec": number? }` |
| `TargetCompleted` | `{ "target_name": string }` |
| `ExposureStarted` | `{ "frame": int, "total": int, "filter": string?, "duration_secs": number }` |
| `ExposureCompleted` | `{ "frame": int, "total": int, "duration_secs": number }` |
| `Error` | `{ "message": string }` |
| `TriggerFired` | `{ "trigger_id": string, "trigger_name": string, "action": string }` |
| `InstructionProgress` | `{ "node_id": string, "instruction": string, "progress_percent": number, "detail": string }` |

#### `category: imaging`

| eventType | Payload fields |
| --- | --- |
| `ExposureStarted` | `{ "duration_secs": number, "frame_type": string }` |
| `ExposureStartedWithFrame` | `{ "duration_secs": number, "frame_type": string, "frame_number": int, "total_frames": int? }` |
| `ExposureProgress` | `{ "progress": number, "remaining_secs": number }` |
| `ExposureCompleted` | `{ "file_path": string?, "hfr": number, "stars_detected": int }` |
| `ExposureCompletedWithFrame` | `{ "frame_number": int, "total_frames": int?, "hfr": number, "stars_detected": int }` |
| `ExposureComplete` | `{ "success": bool }` — **not a typo, and not the same event as the row above.** See below. |
| `ImageReady` | `{ "width": int, "height": int }` |
| `ImageSaved` | `{ "file_path": string }` |
| `TemperatureChanged` | `{ "temp_celsius": number, "cooler_power": number }` |
| `ExposureFailed` | `{ "error": string }` |
| `ExposureCancelled` | `{}` |

##### Three names, two of them one character apart

Filtering an exposure-finished event by name alone will get this wrong. There are three, and which
ones you see depends on **which code path took the exposure**, not on how the exposure went:

| event | emitted by | when you see it |
| --- | --- | --- |
| `sequencer` / `ExposureCompleted` | the sequencer's own frame counter | every frame of a sequence run |
| `imaging` / `ExposureComplete` | `unified_device_ops` — the capture path the **sequencer** drives | every frame of a sequence run |
| `imaging` / `ExposureCompleted` | `imaging_ops` — the **ad-hoc** capture path (Imaging screen, quick capture) | single captures, *not* sequence frames |

So during an unattended sequence run you receive `ExposureCompleted` **and** `ExposureComplete` per
frame — different subsystems reporting different things, not a duplicate emission — and you do
**not** receive the rich `imaging` / `ExposureCompleted` with `file_path`/`hfr` at all.

Observed on a live rig, 2026-08-09, over `GET /api/run-watch/events` during a 3-frame run:

```
3 ExposureCompleted   3 ExposureComplete   3 FrameAccepted   6 ExposureStarted
```

**Always match on the `(category, eventType)` pair.** A client that filters on `eventType` alone
silently receives the imaging layer's bare `{"success": true}` and never sees the sequencer's frame
counter, or the reverse — and the difference is invisible when scanning a log.

For per-frame progress use `sequencer` / `ExposureCompleted` (it carries `frame`/`total`). For the
saved file and its measured quality, use `FrameAccepted` / `FrameRejected`, which carry the path and
the grading result for sequencer-captured frames.

#### `category: equipment`

| eventType | Payload fields |
| --- | --- |
| `Connecting` | `{ "device_type": string, "device_id": string }` |
| `Connected` | `{ "device_type": string, "device_id": string }` |
| `Disconnected` | `{ "device_type": string, "device_id": string }` |
| `Error` | `{ "device_type": string, "device_id": string, "message": string }` |
| `MountSlewStarted` | `{ "ra": number, "dec": number }` |
| `MountSlewCompleted` | `{ "ra": number, "dec": number }` |
| `MountTrackingStarted` / `MountTrackingStopped` | `{}` |
| `MountParkStarted` / `MountParkCompleted` / `MountUnparked` | `{}` |
| `FocuserMoveStarted` / `FocuserMoveCompleted` | `{ "target_position"\|"position": int }` |
| `FocuserTemperatureChanged` | `{ "temperature": number }` |
| `FilterChanging` / `FilterChanged` | `{ "from_position"?: int, "to_position"\|"position": int, "filter_name": string? }` |
| `RotatorMoveStarted` / `RotatorMoveCompleted` | `{ "target_angle"\|"angle": number }` |
| `CameraCoolingStarted` | `{ "target_temp": number }` |
| `CameraCoolingReached` | `{ "temperature": number }` |
| `HeartbeatStarted` / `HeartbeatStopped` / `HeartbeatStatusChanged` / `HeartbeatReconnecting` / `HeartbeatReconnected` | See `skotiq_bridge/event.dart`. |

#### `category: safety`

| eventType | Payload fields |
| --- | --- |
| `WeatherUnsafe` | `{ "reason": string }` |
| `WeatherSafe` | `{}` |
| `EmergencyStop` | `{ "reason": string }` |
| `ParkInitiated` | `{ "reason": string }` |
| `ParkCompleted` | `{}` |

#### `category: system`

| eventType | Payload fields |
| --- | --- |
| `Initialized` / `ShuttingDown` | `{}` |
| `Error` | `{ "message": string }` |
| `DiskSpaceLow` | `{ "available_gb": number }` |
| `Notification` | `{ "title": string, "message": string, "level": string }` |
| `EventsDropped` | `{ "droppedCount": int, "totalDropped": int }` |

## Error Responses

All endpoints may return error responses using a single, unified envelope:

**Error Response:**
```json
{
  "error": "Region 42 not found",
  "code": "region_not_found",
  "message": "Region 42 not found",
  "details": { "regionId": 42 }
}
```

Field semantics:

| Field | Meaning |
| --- | --- |
| `code` | **Machine-readable** error code (lower_snake_case, e.g. `region_not_found`, `rate_limited`, `pairing_required`). Clients should branch on this. |
| `message` | Human-readable message intended for direct display. |
| `error` | Legacy display field. Carries the same human-readable string as `message` so older clients that read `body["error"]` keep working. **Not** a machine code. |
| `details` | Optional structured, endpoint-specific context, spread inline alongside the envelope keys. |

The envelope is backward-compatible: new clients read the machine `code`,
while clients that historically read `error` as a display string still receive
a human-readable message there. Some endpoints still emit the older prose-only
`{ "error": "..." }` shape during the ongoing migration; clients parsing the
envelope treat a missing `code` as a status-derived fallback (e.g. `not_found`
for `404`).

**HTTP Status Codes:**
- `200 OK` - Success
- `400 Bad Request` - Invalid request
- `404 Not Found` - Endpoint not found
- `413 Payload Too Large` - Request body exceeds the endpoint limit
- `429 Too Many Requests` - Per-endpoint control rate limit exceeded
- `500 Internal Server Error` - Server error
- `501 Not Implemented` - Handler not registered

## Request Body Limits

The server rejects oversized requests before handlers read the body when the
client supplies a `Content-Length` header.

| Endpoint class | Limit |
| --- | --- |
| Default control/API requests | 1 MiB |
| Image-processing JSON endpoints (`/api/imaging/stats`, `/api/imaging/stretch`, `/api/imaging/debayer`, `/api/imaging/save-fits`) | 64 MiB |
| Backup restore upload (`/api/backup/upload-restore`) | 256 MiB |

## Control Rate Limits

Mutation endpoints under device, camera, mount, focuser, filter wheel, rotator,
guiding, sequencer, framing, dome, safety, switch, cover, backup, and remote
filesystem APIs are rate limited per client and endpoint. High-risk actions
such as slew, park/unpark, device connect/disconnect, sequence start/stop, dome
movement, and backup restore are limited more tightly. A rejected request
returns `429` with a `Retry-After` header.

## Audit Logging

High-risk remote commands are logged through `HeadlessApiAudit` with the request
ID, client key, method, path, action name, and completion status. Audited actions
include device connect/disconnect, mount/framing slew, park/unpark, dome
movement, backup restore/upload-restore, sequence start/stop/resume, and remote
file browsing.

## CORS

The server includes CORS headers to allow cross-origin requests:

- `Access-Control-Allow-Origin: *`
- `Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS`
- `Access-Control-Allow-Headers: Content-Type`

## Example Usage

### JavaScript/TypeScript

```javascript
// Get device list
const response = await fetch('http://localhost:8080/api/devices');
const data = await response.json();
console.log('Devices:', data.devices);

// Connect to camera
await fetch('http://localhost:8080/api/devices/connect', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({
    deviceType: 'camera',
    deviceId: 'camera-1'
  })
});

// Get sequence status
const statusResponse = await fetch('http://localhost:8080/api/sequencer/status');
const status = await statusResponse.json();
console.log('Sequence state:', status.state);
```

### Python

```python
import requests

# Get device list
response = requests.get('http://localhost:8080/api/devices')
devices = response.json()
print(f"Found {len(devices['devices'])} devices")

# Connect to camera
requests.post('http://localhost:8080/api/devices/connect', json={
    'deviceType': 'camera',
    'deviceId': 'camera-1'
})

# Get sequence status
status = requests.get('http://localhost:8080/api/sequencer/status').json()
print(f"Sequence state: {status['state']}")
```

## Server Configuration

The web server can be configured when creating an instance:

```dart
final server = SkotiqWebServer(
  port: 8080,
  webRoot: '/path/to/web/build', // Optional: for serving static files
  devicesHandler: () async => {...},
  deviceConnectHandler: (type, id) async => {...},
  // ... other handlers
);

await server.start();
```

If `webRoot` is not provided or doesn't exist, the server runs in API-only mode.

