# PHD2 command connection stalled during the October 26–27 imaging run

## Evidence

Times below are EDT (UTC minus four hours).

- PHD2 2.6.14 processed Skotiq requests through `get_pixel_scale`, request
  60536, at 00:25:08.799. The PHD2 debug log has no subsequent requests from
  that client, including the later `stop_capture` requests.
- Skotiq first logged a `get_app_state` response timeout at 00:25:29.077,
  request 60538. Its response-timeout branch is reached only after both the
  JSON and newline writes have returned successfully. That proves local
  write acceptance, not delivery to PHD2's application.
- PHD2's guide log continues throughout the failure. The guiding engine was
  alive; the application had not crashed.
- At 00:30:54 the mount's tracking-limit stop triggered an early flip. At
  00:33:04 it failed in **Pausing guider**, before any flip slew. Skotiq
  incorrectly treated this as a mount refusal and waited for its configured
  flip window. Four scheduled attempts also failed while pausing the guider;
  the sequence paused at 01:31:09.
- At 07:24:37 a separate, read-only TCP connection obtained `Stopped` from
  `get_app_state` immediately. PHD2 logged that request and response, id
  900001. Windows still reported the original Skotiq/PHD2 TCP connection as
  established at 07:33.

The debug log initially appeared empty and became available after it flushed.
The copied logs are in the investigating machine's
`~/.cache/skotiq-flip-20261027/`. The pertinent sources are
`PHD2_DebugLog_2026-10-26_195833.txt`,
`PHD2_GuideLog_2026-10-26_195833.txt`, and `skotiq.log.2026-10-27`.

## Diagnosis and limits

The command path on the existing connection stalled. Skotiq kept an open
writer and a running reader flag, so it continued calling that connection
healthy after every timeout. Neither status polling nor stop retries replaced
it. This is the confirmed application defect that prolonged the interruption
for the rest of the night.

The evidence favors a connection-specific input problem over a globally
unresponsive PHD2 or a blocked Skotiq response reader: PHD2 stopped logging
requests, kept guiding, and answered a new connection. It does **not** establish
which Windows/PHD2 socket event or transport condition initiated the stall.
No overnight packet trace or PHD2 socket-internal diagnostic exists. A short
morning Packet Monitor capture recorded no packets and adds no evidence about
that cause. Do not describe this as proof of a particular PHD2 or Windows bug.

PHD2 logs parsed requests in its event server, rather than acknowledging every
TCP byte: [PHD2 2.6.14 event server source](https://github.com/OpenPHDGuiding/phd2/blob/v2.6.14/src/event_server.cpp).

## Changes

- A request timeout, failed write or closed response channel retires the
  connection. Writes have a finite timeout and send JSON with its delimiter.
- Read-only `get_*` calls and idempotent `stop_capture` get at most one retry
  on a fresh connection. Application-level RPC errors are returned directly.
  Dither, guide and other state-changing commands are not implicitly replayed.
- Each connection owns its reader state, response waiters and settle tracking.
  A retired reader cannot disconnect its replacement or satisfy a new settle.
  Socket EOF/errors immediately wake pending requests. Explicit disconnect and
  disabled automatic reconnection remain respected.
- A recovered in-flight request does not emit a terminal disconnect event:
  that event makes the UI delete the client and would undo the recovery.
  Failed recovery still reports disconnection.
- Stop-guiding returns success only after PHD2 reports `Stopped`. A stop
  acknowledgement followed by capture continuing past its grace period is an
  error, so a flip cannot treat it as permission to slew.
- Timeout diagnostics identify the method, request id, bytes accepted by the
  local writer and incoming line count during the wait. Recovery is logged.
- An early flip treats only slew/pier-verification failures as mount refusal.
  Guider failures follow the configured retry/failure policy with their actual
  cause retained.

## Verification

A real local TCP stand-in reproduces an open, nonresponsive connection while
accepting requests on a replacement. The original implementation failed with
`Request 'get_app_state' timed out (id=2)`. The revised client recovers and also
recovers `stop_capture`, then reads `Stopped`.

Additional tests cover socket EOF, bounded retries, disabled reconnect,
explicit disconnect, no replay of an uncertain dither, isolation of old settle
waiters, application errors, and responses fragmented across a read timeout.
Bridge tests exercise recovery through the public stop-guiding API, require
capture to finish after its acknowledgement, and check that recovery does not
emit a disconnect that would trigger UI teardown. A separate test reproduces
an acknowledged stop that never finishes; the original bridge incorrectly
returned success.
The early-flip regression originally returned `Aborted { reason: "the mount
did not take the east side: Pausing guider: PHD2 stop_capture timed out" }`;
it must instead retry and report the guider failure without issuing a slew.

Validation passed: 20 imaging/PHD2 client tests, 26 bridge/PHD2 tests, and
43 meridian-flip executor tests (89 total), plus Rust formatting and diff
whitespace checks. The stop-confirmation regression failed before the bridge
fix and passed afterward.

These are local fault-injection tests, not a claim of a successful physical
meridian flip. No application deployment or hardware command was made during
this investigation.
