# Driver Troubleshooting

Driver issues can look like discovery failures, connect timeouts, unsupported
controls, corrupted frames, or device disconnects during long sessions.

## Choose the Right Backend

- Use ASCOM COM only on Windows.
- Use Alpaca for network devices and ASCOM bridges.
- Use INDI when a supported INDI server and driver are available.
- Use native SDK paths only when the needed vendor library is installed on the
  system or supplied in a legally cleared custom bundle. Official 5.0.0
  artifacts do not redistribute vendor SDK binaries.
- Use simulator paths to separate Skotiq workflow issues from hardware
  issues.

## Install And Verify

1. Install the platform runtime first, such as ASCOM Platform or INDI.
2. Install the device-specific driver or vendor SDK.
3. Reboot or reconnect hardware if the vendor installer requires it.
4. Test the device in the vendor utility or platform diagnostic tool.
5. Start Skotiq after the device works outside Skotiq.

## Common Driver Failure Modes

- Another app has exclusive access to the device.
- A stale driver service is still running after an update.
- The device firmware requires a newer driver.
- A USB-to-serial adapter is using the wrong COM port or missing its driver.
- A native vendor SDK DLL/shared library is not installed or is outside the
  loader's search path.
- The driver exposes fewer capabilities than the UI control expects.

## When To Reinstall

Reinstall or update the driver when:

- The device does not appear in the OS device list.
- The vendor utility cannot connect.
- ASCOM Diagnostics, `indi_getprop`, or the Alpaca status page cannot see the
  device.
- The driver crashes or disappears during basic commands.

## Release-Gate Evidence

For public-release sign-off, record backend, driver version, vendor utility test
result, Skotiq discovery result, connect result, and any native library that
must be bundled or deliberately excluded.
