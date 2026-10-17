# ASCOM Troubleshooting

ASCOM COM support is Windows-only. On Linux and macOS, use Alpaca or INDI
instead of ASCOM COM.

## Quick Checks

1. Confirm Windows is the host running Skotiq.
2. Install the ASCOM Platform before installing device drivers.
3. Install the device manufacturer's ASCOM driver for each device.
4. Restart Skotiq after installing or updating ASCOM drivers.
5. Test the device outside Skotiq with ASCOM Diagnostics, ASCOM Device Hub,
   or the manufacturer's utility.

## Driver Not Listed

- Reinstall the device-specific ASCOM driver.
- Check whether the driver is installed for the same Windows user account that
  launches Skotiq.
- Start Skotiq after the ASCOM Platform and driver installers finish.
- If a device only ships an Alpaca server, connect through Alpaca rather than
  expecting it to appear in ASCOM COM discovery.

## Connect Fails

- Close other astronomy apps that may already own the driver.
- For serial mounts, confirm the COM port in Device Manager and in the driver
  properties.
- Check baud rate, mount type, site, and hand-controller mode in the driver
  setup dialog.
- Unpark the mount before issuing movement commands.
- Try a simulator driver. If the simulator works but the real device does not,
  the issue is driver, cabling, power, or device configuration.

## Runtime Disconnects

- Disable USB selective suspend in Windows power settings.
- Avoid unpowered USB hubs for cameras and mounts.
- Use shorter, higher-quality USB cables.
- Check Windows Event Viewer and Skotiq logs for USB reset or COM-port
  errors.

## Release-Gate Evidence

For public-release sign-off, record the Windows version, ASCOM Platform version,
driver name/version, device model, tested operations, and whether failures were
handled as disabled controls or actionable errors.
