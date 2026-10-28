# October 27–28 overnight recovery follow-up

The Ha run completed. This investigation used the laptop's native, Dart and
PHD2 logs, copied to `~/.cache/skotiq-deploy-20261028/logs/`. Times below are
EDT. These changes follow the separate deployment of `a01c5366b`; they were
verified locally without restarting the laptop or issuing equipment commands.

## Confirmed defects and fixes

- **Device poll bursts after long recovery actions.** The trigger monitor
  awaits autofocus/flip actions on the same task as its one-second timer.
  Tokio's default missed-tick behavior then replays every missed poll. The
  PHD2 log contains bursts of hundreds of RPCs per second. A paused-clock
  regression reproduces the backlog after a five-minute action. The monitor
  now skips missed ticks and resumes its normal cadence. This removes a
  demonstrated source of request bursts; it does not prove the initiating
  cause of every Windows/PHD2 socket stall.
- **False dither failure after a recovered status request.** At 23:34:26 a
  timed-out `get_app_state` replaced the socket, abandoning the active settle
  waiter. PHD2 completed the acknowledged dither at 23:34:38 with status 0.
  The logical settle now follows bounded read-only transport recovery. It
  still requires `SettleDone`, preserves failure/timeout outcomes, rejects
  retired-reader events, and never replays `dither` or `guide`. An explicit
  reconnect/disconnect continues to end the old wait. A local TCP stand-in
  reproduces the original stalled socket while the settle continues.
- **Calibration frames sent to the star solver.** The annotation pipeline
  lacked a frame-type gate, causing all 200 bias and 20 dark captures to
  generate futile solves and warnings. Automatic annotation now skips bias,
  dark, flat and dark-flat images, clears their stale overlay, and continues
  to handle light frames and snapshots. Tests exercise all six frame types.
- **Immediate autofocus retry on old HFR.** The failed 01:57 sweep advanced
  its interval anchor, but its HFR trigger retained the pre-sweep bad-frame
  verdict. A completed sweep now consumes the HFR samples already available.
  Fresh degraded frames can trigger another sweep using the user's existing
  consecutive-frame setting; the failed sweep does not invent a new baseline.
- **Misleading settle advice during star loss.** A 134.89-pixel RMS excursion
  generated a recommendation of roughly 202 pixels. Advice now requires a
  held guide lock within the existing recovery quality bound, reports the
  current measurement, and avoids claiming a single reading establishes the
  rig's normal performance or a suitable new tolerance.

## Other observations

The original empty-looking Dart log was readable after the graceful app
close and contains the overnight records; a logging gap was not established.
The two-frame difference between the runtime tally (97) and current accepted
rows (95) is accounted for by later Science auto-grading of Ha frames 105 and
109 for guiding RMS. This patch does not change that summary bookkeeping or
repair historical counters. Final integration used the frame acceptance
records, not the larger runtime tally.

## Regression evidence

Each defect above was reproduced before its corresponding fix: calibration
images reached the solver, a recovered dither lost its waiter, the timer
replayed missed ticks, an HFR verdict immediately retriggered after a sweep,
and the lost-star RMS produced a tolerance recommendation.

PHD2 tests additionally cover a nonzero settle result, no completion event,
retired-reader isolation, uncertain-command non-replay, explicit disconnect,
disabled reconnection, fragmented responses and bounded transport retries.
These are local tests, not evidence of a new successful night on hardware.

Validation: 24 imaging/PHD2 tests, 26 bridge/PHD2 tests, and 19 annotation
tests passed. The sequencer run passed 1,324 tests with two assertions still
matching the retired advice text; after updating those assertions, all 12
settle-related tests passed. The new cadence and HFR regressions passed in the
full run. Dart static analysis, Rust formatting and diff whitespace checks
passed. Local logs are in `~/.cache/skotiq-overnight-fixes-20261028/`.
