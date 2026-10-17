# Firewall Troubleshooting

Firewall issues usually affect remote dashboard access, headless API access,
Alpaca discovery, INDI connections, and PHD2 connections.

## Ports To Check

| Port | Protocol | Used by |
|------|----------|---------|
| `8080` or `SKOTIQ_PORT` | TCP | Skotiq headless REST API, dashboard, and WebSocket |
| `45679` | UDP | Skotiq LAN discovery advertisements |
| `7624` | TCP | INDI server default |
| `11111` or server-configured port | TCP/UDP | Alpaca device or bridge |
| `4400` or PHD2-configured port | TCP | PHD2 server default |

Only open ports needed by the deployment, and only on trusted networks.

## Skotiq Headless Or Dashboard Cannot Connect

- Confirm the server is bound to LAN, not only loopback.
- Confirm authentication is enabled before exposing the API beyond localhost.
- Confirm the client is using the right host, port, and token.
- Check OS firewall rules on the host running Skotiq.
- Check router, VLAN, VPN, or guest Wi-Fi isolation rules.

## Alpaca Discovery Fails

- Try manual IP and port entry.
- Allow discovery traffic on the trusted local network.
- Put the client and Alpaca server on the same subnet for testing.
- Disable VPN routing temporarily on a trusted network.

## INDI Or PHD2 Cannot Connect

- Confirm the server process is listening.
- Confirm the configured port matches Skotiq settings.
- Prefer `localhost` or `127.0.0.1` when the server is on the same machine.
- Open the port only if the server is intentionally remote.

## Release-Gate Evidence

For public-release sign-off, run the firewall smoke from a second physical
device on the same LAN, not localhost, an emulator alias, or the host browser.
Record the server LAN URL, client IP, bind mode, ports, Windows Defender
Firewall rule name/profile, router or VLAN path, authenticated and
unauthenticated responses, discovery result, dashboard asset load result, and
WebSocket reconnect result.

Evidence fields to include:

- `second physical device`
- `server LAN URL`
- `client IP`
- `Windows Defender Firewall`
- `authenticated and unauthenticated responses`
- `WebSocket reconnect`

Use `docs/headless-secure-setup.md` for the authenticated LAN setup rules that
the firewall smoke evidence must satisfy.
