# INDI Troubleshooting

INDI support requires a reachable INDI server. Skotiq connects to the server
and uses the properties exposed by the loaded device drivers.

## Quick Checks

1. Confirm the INDI server is running on the expected host.
2. Confirm Skotiq is using the same host and port. The common default is
   `localhost:7624`.
3. Start the INDI server with the exact drivers needed for the device.
4. Confirm no other process has exclusive access to the USB or serial device.

## Useful Commands

```bash
ps aux | grep indiserver
indi_getprop
indi_getprop "*CONNECTION*"
lsusb
dmesg | tail -100
```

If `indi_getprop` cannot see the device properties, Skotiq will not be able
to control that device either.

## Server Not Reachable

- Check that the INDI server is bound to the expected interface.
- Open TCP port `7624` only on trusted networks.
- Use `localhost` when Skotiq and INDI run on the same machine.
- Use the server IP address when INDI runs on another computer.
- Check firewall rules on both machines.

## Device Appears But Commands Fail

- Verify the INDI driver exposes the required capability for the Skotiq
  control being used.
- Check INDI logs for permission, timeout, or device-busy errors.
- Confirm the device is not parked, disconnected, or in a driver-specific safe
  mode.
- Restart the INDI driver after changing cabling or USB permissions.

## Linux Permissions

- Add the user to `dialout` for serial devices.
- Add the user to `video` or `plugdev` when required by camera drivers.
- On Skotiq systemd/Pi appliances, confirm
  `/etc/udev/rules.d/99-skotiq-astro.rules` is installed. It grants the
  `skotiq` service group access to common astronomy cameras and USB-serial
  adapters without making devices world-writable.
- Install vendor udev/firmware packages when the device needs firmware upload
  or a vendor-specific driver stack beyond basic permissions.
- Log out and back in after changing group membership.
- Reload udev and reconnect devices after changing rules:

  ```bash
  sudo udevadm control --reload-rules
  sudo udevadm trigger --subsystem-match=usb --subsystem-match=tty --subsystem-match=hidraw
  ```

## Release-Gate Evidence

For public-release sign-off, record the OS, INDI server version, driver names,
host/port, device models, tested operations, and any unsupported properties that
must be disabled or documented.
