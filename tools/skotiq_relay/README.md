# Skotiq Relay

Self-hostable relay for "check my rig from work" — remote access to a
Skotiq appliance from anywhere, with **no VPN, Tailscale, or port
forwarding** required at the observatory.

```
appliance ──outbound WebSocket──► relay ◄──WebSocket── phone(s)
        (dials OUT, NAT-friendly)        /connect/<appliance-id>
```

The appliance keeps one outbound WebSocket to the relay. Phones connect to
`/connect/<appliance-id>` and the relay splices the two sockets, multiplexing
many concurrent logical streams (REST calls, the event WebSocket, JPEG live
view) over the single uplink using a tiny length-prefixed framing protocol
(`lib/src/mux/frame.dart`).

## One-command deployment

```sh
docker build -t skotiq-relay .
docker run -d --name skotiq-relay --restart unless-stopped \
  -p 9777:9777 -v skotiq-relay-state:/data skotiq-relay
```

Or without Docker:

```sh
dart pub get
dart run bin/relay.dart --port=9777 --state-file=/var/lib/skotiq/relay_state.json
```

Check it is alive: `curl http://your-host:9777/healthz`

## Connecting an appliance

Start the headless server with the relay URL:

```sh
SKOTIQ_RELAY_URL=wss://relay.example.com ./skotiq_desktop --headless
# or: --relay-url=wss://relay.example.com
```

On first contact the relay mints an **appliance id** (e.g. `k7mp-q2vx-9rtn`)
and a secret. The id is printed to the daemon's stdout/log; the secret is
persisted next to the appliance's other state (`relay_credentials.json`) and
is only ever shown to the relay again. In the mobile app choose
**Connect via Relay** and enter the relay URL + appliance id.

## Configuration

| Flag | Env | Default | Meaning |
| --- | --- | --- | --- |
| `--port` | `SKOTIQ_RELAY_PORT` | `9777` | Listen port |
| `--bind` | `SKOTIQ_RELAY_BIND` | `0.0.0.0` | Bind address |
| `--state-file` | `SKOTIQ_RELAY_STATE_FILE` | `relay_state.json` | Registered-appliance persistence (id → SHA-256 of secret) |
| `--tls-cert` / `--tls-key` | `SKOTIQ_RELAY_TLS_CERT/_KEY` | – | Serve WSS directly (PEM); usually leave unset behind a reverse proxy |
| `--max-appliances` | `SKOTIQ_RELAY_MAX_APPLIANCES` | `50` | Cap on registered appliance identities |
| `--max-clients` | `SKOTIQ_RELAY_MAX_CLIENTS` | `8` | Simultaneous phones per appliance |

For Internet deployments put the relay behind a TLS terminator (Caddy,
nginx, Traefik) or pass `--tls-cert/--tls-key`, so uplinks and phone tunnels
ride `wss://`.

## Security model (v1, honest)

* The relay authenticates **appliances only**, via the registration secret
  (stored hashed). Failed registrations are rate-limited per source IP
  (5/minute).
* The relay does **not** authenticate phones. Knowing an appliance id lets
  anyone reach the appliance's HTTP front door **through** the relay — the
  same exposure as the appliance's LAN port. Real authentication stays
  end-to-end: the existing 6-digit pairing + HMAC bearer tokens between
  phone and appliance, which the relay never sees in plaintext.
* If the appliance itself serves plain HTTP, the relay host can technically
  observe tunnel bytes, like any reverse proxy. Run the appliance with
  `--tls` (and connect with scheme `https` in the app) for true end-to-end
  encryption through an untrusted relay.
* Stream multiplexing has no per-stream flow-control window yet; one bulk
  transfer can add latency to sibling streams on the same uplink.

## Live view over relay

The API channel (and therefore WebRTC signaling) works through the relay,
but WebRTC media itself negotiates a direct peer-to-peer path via ICE — with
both ends behind NAT and no TURN server, that negotiation may fail. The
mobile app's live view automatically falls back to the WebSocket JPEG path
(`subscribeLiveViewAuto`) when WebRTC cannot connect, so live view still
works over the relay, just at WS-JPEG quality/latency. This relay
deliberately does **not** implement TURN.

## Endpoints

* `GET /healthz` — JSON liveness + counters.
* `GET /uplink` (WebSocket) — appliance registration + tunnel uplink.
* `GET /connect/<appliance-id>` (WebSocket) — phone tunnel.

## Tests

```sh
dart test
```

Covers the mux frame codec/session (interleaving, half-close, backpressure
ordering), registration/auth/rate-limit behaviour, and a full end-to-end
tunnel: relay + fake appliance HTTP server + tunnel client, including a
WebSocket upgrade and concurrent transfers through one uplink.
