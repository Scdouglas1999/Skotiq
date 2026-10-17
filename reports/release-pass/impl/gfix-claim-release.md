# gfix-claim-release — the camera-claim release hole

Batch: `claim-release`
Scope: `native/skotiq_native/sequencer/src/executor/**`
Source: `reports/release-pass/waveG-result.json`, refuter entry
*"camera-claim-serialization incl. the must-NOT-wait list (ffix-exposure-integrity, WF-STOP-N1)"*

## What the refutation said

The must-NOT-wait list holds (`camera_driving_trigger_action` returns `None` for
Pause / ParkAndAbort / Dither, and the existing test passes at HEAD). The
INVARIANT does not:

> "The flip and recenter arms hand the camera back ... including on the paths
> where they do not run at all, so the capture loop never waits out the
> ten-minute expiry."

The claim is taken unconditionally above the action match
(`executor/start.rs:3403-3414`) for every camera-driving action, but the
Autofocus arm released it in exactly one place — `start.rs:3786`, inside the
`(Some(_), Some(_))` camera+focuser branch. Its sibling `_ =>` branch
(`start.rs:3954-4014`), reached when the camera or focuser id is absent, logs
*"skipping the refocus and continuing the run"* and falls through with no
`clear_camera_busy`. There were five release sites in the crate
(`start.rs:3786/4106/4309/4463/4500`, plus `instructions/expose.rs:455/479`) and
none of them run on that path.

Consequence: the hold expires only at `TRIGGER_CAMERA_CLAIM_SECS = 600 s`, and
for those ten minutes the capture loop's pre-frame gate
(`instructions/expose.rs:412-434`) blocks EVERY frame while the run goes on
reporting itself as imaging. The arm's own comment records the scenario as
live-reproduced: a rig with camera + wheel connected and no focuser, where the
filter change invalidates focus and the always-armed HFR trigger force-fires.

The refuter's evidence was line-anchored static control flow, explicitly NOT
executed, because the leak is inside a private closure in `start.rs`.

## Failing test first

Transcribed the `_ =>` arm's body against HEAD's API (acquire the claim the way
the monitor does, run the branch's whole body — warn, `clear_autofocus_invalidation`,
Error event — then ask whether the camera is free):

```
test executor::tests::runtime_tests::the_autofocus_skip_branch_hands_the_camera_back ... FAILED
panicked at sequencer/src/executor/tests/runtime_tests.rs:1332:5:
the skipped refocus must hand the camera back; a hold left to expire blocks
every frame for TRIGGER_CAMERA_CLAIM_SECS while the run still reports itself
as imaging
```

## The fix

Restructured so the release is a property of the dispatch rather than a habit of
each arm. `executor/trigger_context.rs`:

- **`TriggerCameraClaim`** — an RAII guard. `acquire(state, is_cancelled, action)`
  takes the claim iff the action drives the camera; `release().await` is the
  explicit hand-back the exposing arms still call the instant they are done with
  the sensor; `Drop` is the backstop for the exits that never reach a release
  point (the skip branch, `continue`, `return terminate_with(...)`).
- **Release is once-only and identity-checked.** The token is one shared
  deadline, so a second or late release would clear a claim the *capture loop*
  now holds and destroy the frame the protocol exists to protect. The guard
  records the deadline it installed and clears only while that deadline is still
  in place.
- **A cancelled wait no longer counts as held.** `claim_camera_for_trigger_action`
  now returns `Option<i64>` (the deadline taken, `None` on cancel). Previously
  `camera_claim_taken` was `true` for any camera-driving action even when the
  wait exited early on Stop without ever owning the token — the arms would then
  clear a claim belonging to whoever took it next.
- **`autofocus_trigger_skip_reason(camera_id, focuser_id)`** — the arm's
  device-availability branch, lifted out of the closure so the enumeration of
  "every exit" is real code a test can call instead of a match no test can reach.

`executor/start.rs`:

- The flag becomes the guard at the single acquire point.
- All five `clear_camera_busy()` call sites become `camera_claim.release().await`
  (the four `if camera_claim_taken { ... }` wrappers drop out — the guard knows).
- The Autofocus arm matches on `autofocus_trigger_skip_reason(..)`, so the
  `(Some, Some)` / `_` pair becomes `None` / `Some(missing)` and the duplicated
  `let missing = match (..)` inside the skip branch is deleted.
- A **single release point after the match** (`start.rs:5004`) that every
  fall-through exit reaches, including the skip branch.
- `debug_assert!(camera_claim_taken)` removed: it asserted a tautology before,
  and would now fire spuriously when an operator Stop cancels the wait.

## Tests (all in the existing `every_camera_driving_trigger_action` neighbourhood)

| Test | Branch it pins |
| --- | --- |
| `the_autofocus_skip_branch_hands_the_camera_back` | the refuted branch, as the invariant: acquire, take the skip exit, camera free |
| `every_autofocus_device_gap_hands_the_camera_back` | all four `(camera, focuser)` combinations the arm can see — the leak was not specific to the missing focuser |
| `every_camera_driving_action_hands_the_camera_back_on_a_silent_exit` | Autofocus / MeridianFlip / Recenter, both the silent exit and the explicit release |
| `a_stale_release_cannot_steal_the_capture_loops_claim` | a late release must not clear the capture loop's own hold |
| `a_cancelled_wait_never_claims_and_never_releases` | Stop mid-wait: the guard holds nothing and releases nothing |
| `non_camera_actions_take_no_claim` | the must-NOT-wait list, unchanged |
| `the_trigger_dispatch_releases_the_camera_only_through_the_guard` | zero bare `clear_camera_busy(` in `start.rs` — the previous fix was a per-arm release plus a comment claiming full coverage, and the comment was what was wrong |

## Verification

- `cargo test -p skotiq_sequencer` — **793 passed, 0 failed** (786 at HEAD +
  the 7 above; the pre-existing ignored integration test stays ignored).
- `cargo clippy -p skotiq_sequencer --all-targets` — no new warnings (the 3
  `doc list item overindented` are pre-existing in `skotiq_imaging`).
- `cargo fmt -p skotiq_sequencer -- --check` — clean. Only
  `runtime_tests.rs` needed formatting and only that file was run through
  `rustfmt`; no repo-wide formatter.
- `cargo check --workspace` — clean.

## Not done / honest limits

- **Not exercised end to end.** The leak lives in a private closure inside
  `start.rs`; the tests pin the guard, the branch enumeration and the
  release-mechanism invariant, but no test drives a real trigger firing through
  the executor. Same limitation the refuter recorded.
- **The `Drop` backstop's contended path is deferred**, not inline: if the state
  lock is held at drop time the release is spawned on the current runtime. The
  identity check is what makes the delay safe. With no runtime at drop it logs an
  error and the claim expires as before.
- No bundle rebuild, no FRB regen (nothing crossed the bridge — every changed
  item is `pub(super)` inside `executor`), no git writes.
