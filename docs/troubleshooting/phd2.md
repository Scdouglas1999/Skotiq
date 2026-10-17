# PHD2 Troubleshooting

Skotiq uses PHD2 as the primary public-release guiding path. PHD2 must be
running and its server must be enabled before Skotiq can connect.

## Quick Checks

1. Start PHD2.
2. Connect the guide camera and mount inside PHD2.
3. In PHD2, enable the server from Tools > Enable Server.
4. Confirm the host and port in Skotiq. The common default is
   `localhost:4400`.
5. Confirm the firewall allows local traffic to PHD2.

## Cannot Connect

- Try `127.0.0.1` instead of `localhost`.
- Confirm no other app changed the PHD2 server port.
- Restart PHD2 after enabling the server.
- Check PHD2 logs for server startup errors.
- If Skotiq runs on another machine, open the configured PHD2 server port
  only on the trusted observatory network.

## Guiding Starts Then Fails

- Recalibrate PHD2 near the target area.
- Check that the mount is tracking and unparked.
- Increase guide exposure time if stars are noisy or lost.
- Check for cable drag, wind, poor polar alignment, or guide-scope flexure.
- Let PHD2 settle before starting long exposures or dithering.

## Dither Or Settle Problems

- Increase dither settle timeout.
- Loosen settle thresholds during poor seeing.
- Confirm the sequencer is waiting for PHD2 to report a settled state before
  the next exposure.

## Release-Gate Evidence

For public-release sign-off, record PHD2 version, host/port, guide camera, mount
connection method, connect/start/stop/dither behavior, lost-star behavior, and
how Skotiq surfaces PHD2 errors.
