# Alpaca Troubleshooting

Alpaca is ASCOM's network protocol. Skotiq can use Alpaca devices directly
or through bridges such as ASCOM Remote.

## Quick Checks

1. Confirm the Alpaca device or bridge is powered on.
2. Confirm the client and device are on the expected network.
3. Confirm the IP address and port. Many Alpaca servers use port `11111`, but
   the server may be configured differently.
4. Confirm the Alpaca server reports the device type Skotiq is trying to
   use.

## Discovery Does Not Find the Device

- Try entering the IP address and port manually.
- Confirm UDP discovery is not blocked by the local firewall, router, VPN, or
  guest Wi-Fi isolation.
- Check whether the client and device are on different subnets.
- Disable VPN split-tunnel rules temporarily for testing on a trusted network.

## Manual Connection Fails

- Open the Alpaca server's own status or management page if it provides one.
- Verify the port in the Alpaca server configuration.
- Check whether the server requires authentication or only accepts local
  clients.
- Confirm another client is not holding exclusive control of the device.
- Restart the Alpaca bridge after changing ASCOM driver settings behind it.

## Device Connects But Features Are Missing

Alpaca servers vary by device and driver. A connected device can still lack
optional capabilities such as parking, dome slaving, rotator movement, cooling,
or weather/safety fields.

When a feature is not exposed by the Alpaca server, Skotiq should disable the
control or show an actionable error rather than pretending the command is
available.

## Release-Gate Evidence

For public-release sign-off, record the Alpaca server implementation, version,
IP/port, device numbers, device models, tested operations, and any missing
capabilities documented as known limitations.
