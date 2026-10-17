# w21-recovery-and-contention

Branch `agent/w21-recovery`, based on `f9c9c899a`.

Note on the base: `briefs/common-w15.md` names `5b2235cc7` as the required HEAD. The
coordinator brief for this workstream names `f9c9c899a`, which is what the worktree was
created at and what I worked from. I did not re-detach.

Specification: `briefs/evidence-2026-09-14-night.md` — the owner's own log and API
measurements. Every number quoted below is from that file, not from my own reasoning.

## What went wrong, proved

### 1. `operator_present` had no writer, so "UNATTENDED" was a constant

`RuntimeConfig::operator_present` gated the whole abandonment decision. It appeared 16
times in the tree and **not one of them was a write** outside two test fixtures — no
bridge call, no API route, no setting, no UI. It read `false` on every run ever made.

So the 03:01:55 line

```
ERROR monitoring: [RECOVERY] Escalated ConsecutiveRejectsExceeded to operator Pause
  after 1 attempt on an UNATTENDED rig: ... - abandoning safely (park + close cover
  + close dome)
```

was not a judgement about the owner's presence. It was a hard-coded branch. He was
sitting at the telescope, an HTTP client was polling every 25 s, and the desktop UI was
open — and none of that could ever have mattered, because nothing could set the flag.

The escalation's own message said `sequence paused for inspection. Resume once
conditions clear.` The code then parked the mount instead.

### 2. Autofocus's CRITICAL cleanup failure was classified as a missed curve fit

`resume_guiding_after_autofocus` produced `NodeStatus::Failure` with
`CRITICAL CLEANUP FAILURE: guider accepted resume but did not report guiding` — as a
message string only. The trigger monitor's autofocus arm has exactly one failure path,
`autofocus_trigger_continuation`, whose documented policy is "keep imaging on the
last-good focus" because soft subs beat a stopped night. That policy is right for a
focus failure and catastrophic for a guiding failure, and nothing in the result let the
arm tell them apart. Three 180 s lights followed, all trailed to HFR 15.61 px against a
3.50 px limit, all rejected, zero accepted.

It also left `TriggerState::guiding_enabled` set. The monitor's guide-poll block arms
`guide_star_lost` from that latch against PHD2's `is_guiding`, and PHD2 answered *true*
throughout — it was still emitting GuideStep frames while chasing a star it had lost at
RA -56.8 px / Dec -54.4 px, SNR 126.7 -> 11.8. So the one device that could have
contradicted the run was confirming it.

### 3. The `Retry` trigger action retried nothing

`RecoveryAction::Retry { max_attempts: 3 }` is the standard action for `guiding_failed`.
On the trigger side that arm incremented a counter and logged
`Trigger '...' requested retry attempt 1/3`. There is no failed node for a trigger to
re-run, so it performed no retry, took no action, and did not stop the exposures. The
log's 02:59:10 / 03:00:11 / 03:01:11 spacing is the trigger's own 60 s cooldown, i.e.
two full minutes of known-dead guiding during which the run kept exposing.

Worse, `recover_guide_star` — the real recovery for that cause — had a fast path that
returned `Succeeded` on `is_guiding` alone, with no bound on RMS. Had the trigger
reached it, it would have declared success on the exact reading that was lying.

### 4. The imaging train was arbitrated on the camera only

`TriggerState::camera_busy_until_ms` guarded the camera. The filter wheel had **four
unarbitrated writers** (`instructions/filter.rs`, `instructions/autofocus.rs`,
`instructions/expose.rs`, `flat_wizard/mod.rs`). Autofocus commanded position 0 ("L")
while the Smart Exposure node had already commanded position 5 ("SII") — the exposure
path changed the filter *before* the per-frame camera gate, not after — and autofocus
then polled a healthy, idle, responsive wheel for 120 s for a position nothing was going
to move it to. The wheel was never broken.

The camera claim had a second flaw: one deadline (`duration + 20 s`) served as both the
estimate a waiter reads and the instant the token became free. A 180 s light whose
readout overran therefore released the camera mid-integration; the drift-recenter trigger
took the "free" camera and failed on
`did not complete within 65.0s timeout (5.0s requested exposure plus safety margin)` —
a bound derived from its own 5 s request, with no relationship to the 180 s frame it was
queued behind.

The old API proved this itself under test: `mark_camera_busy_for` overwrote a live claim
unconditionally, with no check. A pre-existing test only passed because of that stomp.

## What I changed

### Halt semantics for a failed guider resume: operator Pause

`instructions/autofocus.rs` stamps `AUTOFOCUS_GUIDING_NOT_RESTORED_KEY` on the result and
clears `guiding_enabled` when its cleanup could not prove guiding running again.
`executor::autofocus_trigger_failure_cost` classifies the two failures
(`SoftFramesOnly` vs `EveryFrameUnguided`), and the trigger arm halts on the latter:
node tree frozen, `ExecutorState::Paused`, progress stamped, a loud Error naming the
cause and what was *not* done. The stale-focus latch is dropped so it cannot re-fire and
re-stop the guider on Resume. A sweep that left the guider down is no longer retried
across attempts.

**Pause, not park, not cancel** — the exposure burst's between-frame gate stops the next
frame, so the waste stops immediately; and a dead guider is not evidence about who is
standing at the telescope. One button undoes it.

### `guiding_failed` now reaches the recovery driver

`trigger_recovery_cause` is extracted (shared with the `Pause` arm so the two cannot
drift) and maps `guiding_failed -> GuideStarLost`. A `Retry` trigger with a cause
mapping is handed to the recovery driver on the **first** firing, because the driver
freezing the node tree is the only thing that actually stops the next frame. Triggers
with no cause keep the firing-count path, reworded to say what it really does.

`guiding_is_settled` replaces the bare `is_guiding` check in both the fast path and the
post-restart poll: locked AND inside `REACQUIRE_SETTLE_PIXELS`, which is the bound a
fresh re-acquisition was already held to. (Also corrected a log line that labelled
`rms_total` in arcseconds; it is guide-camera pixels — PHD2 `RADistanceRaw`.)

### "Unattended" is no longer decided; it is configured

`operator_present` is gone. `UnattendedEndPolicy` (`HoldForOperator` default,
`ParkAndClose` opt-in) is derived by `from_recovery_config` from one new operator
setting, `RecoveryRuntimeConfig::park_and_close_when_recovery_gives_up`, default
`false`. **Both** irreversible sweeps — the `PauseForOperator` escalation and the retry
ladder's give-up branch — go through that single gate, so parking cannot reappear under
another name. Under the default the give-up branch still ends the run (a 90-minute
budget really is exhausted and the night needs a terminal event) but moves nothing, and
says so.

I chose **the operator setting, off by default** rather than hunting for evidence of
absence, because there is no such evidence available at that point in the code and
inventing a proxy would recreate the same defect with a better name.

### Safety triggers keep evaluating while paused

This is what makes the hold defensible, and it was the real defect behind the park. The
monitor loop returned early on any non-`Running` state, so a paused run had **no**
weather, dawn, altitude or dome-shutter evaluation at all — the old code's stated reason
for refusing a passive pause ("dome+cover OPEN with safety monitoring OFF until dawn")
was accurate. It was choosing between two defects.

Now `Paused` keeps polling and evaluating, and `is_safety_class_trigger` lets only
rig-protecting triggers act. The predicate is exhaustive over `TriggerType` on purpose:
a `_ => false` would silently leave a future rain/roof trigger unwatched during a hold,
and `_ => true` would let a future autofocus-ish trigger drive hardware under one.
`CloudOpeningIn` is deliberately *not* safety class — a hold placed for a human must not
be auto-resumed by better weather. `Recovering` is still skipped; the driver owns the
hardware for its own bounded ladder.

### Device arbitration: one claim on the imaging train

`ImagingTrainClaim` replaces `camera_busy_until_ms` and covers **camera + filter wheel as
one resource**, because every contending operation takes both.

* **Two deadlines, not one.** `expected_finish_ms` is what a waiter reads to size its
  wait; `expires_at_ms` (+`IMAGING_TRAIN_CLAIM_OVERRUN_GRACE_SECS`, 300 s) is the
  self-heal backstop. A wrong estimate now delays a log line instead of transferring
  ownership mid-frame. This is the fix for the 65 s-vs-180 s failure, and it is not a
  longer timeout: the waiter's bound is *derived from the operation in flight*, and the
  hold message prints both numbers and the holder's name.
* **Token identity.** Release is `release_imaging_train(token)`, checked against the
  installed claim, so a stale or duplicated release cannot free someone else's claim.
  Tokens are never reused.
* **Ordering fixed.** `instructions/expose.rs` takes the claim **before** it commands the
  wheel (previously the wheel moved first and the gate came later, per frame), and holds
  it across the filter-identity read. `instructions/filter.rs` takes it for the whole
  ChangeFilter move. Both use `ImagingTrainClaimGuard` with a single release point, since
  releasing needs the async lock and those bodies have many failure exits.
* Borrowing the wheel mid-burst is still allowed — autofocus needs it — with the restore
  obligation documented; `execute_autofocus_once` and the flip executor already honour it.
* `move_autofocus_filter` now reports the position the wheel is actually sitting at, so a
  future timeout reads as arbitration rather than broken hardware.

## Verification (unpiped, exit codes recorded)

Run from the worktree with `TMPDIR=$HOME/.cache/ns-tmp/w21-recovery`.

| Command | Exit |
| --- | --- |
| `cargo check -p skotiq_sequencer --all-targets` (baseline, before any edit) | 0 |
| `cargo check --workspace --all-targets` | 0 |
| `cargo clippy --workspace --all-targets` | 0 (zero warnings) |
| `cargo fmt --all -- --check` | 0 |
| `cargo test -p skotiq_sequencer` | 0 — 891 lib + all integration targets |
| `cargo build -p skotiq_bridge --release` | 0 |
| `flutter build linux --release` | 0 |
| `dart format --output=none --set-exit-if-changed packages/skotiq_bridge` | 0 |
| `dart format --output=none --set-exit-if-changed packages/skotiq_core` | 0 |
| `dart format --output=none --set-exit-if-changed apps/desktop` | 0 |
| `dart analyze` in `packages/skotiq_bridge` | 0 — "No issues found!" |
| `dart analyze` in `packages/skotiq_core` | 0 — 19 pre-existing infos, none in files I touched |
| `dart analyze` in `apps/desktop` | 0 — 9 pre-existing infos (deprecated wave-4 tokens), none in files I touched |
| `flutter test test/headless_api/sequencer_handlers_test.dart --concurrency=4` | 0 — 40 tests |
| `flutter test test/backend --concurrency=4` (core) | 0 — 306 tests |
| `flutter test test/providers --concurrency=4` (core) | 0 — 1710 tests |
| `flutter_rust_bridge_codegen generate` (with `CC=clang CPATH=$(clang -print-resource-dir)/include:/usr/include`) | 0 |

`dart analyze` initially reported 87,208 issues in `skotiq_core`. That was an
unbootstrapped worktree — no `.dart_tool`, so every cross-package import was unresolved.
After `melos bootstrap` (exit 0, 11 packages) it is the 19 pre-existing infos above.

FRB regen is only idempotent with that `CPATH`. Without it, ffigen cannot find
`stdbool.h` and silently rewrites `frb_generated.io.dart` with broken bindings (415 lines
changed). I hit that, reverted it, and regenerated correctly; the real regen is 6 files,
26 insertions.

## Live verification

The defect itself was reproduced in a running app before I touched anything — the
owner's, on 2026-09-14, and the evidence file is that reproduction.

For the fix I verified against the binary I built:

1. `cargo build -p skotiq_bridge --release` into
   `native/skotiq_native/target/release` (where `apps/desktop/linux/CMakeLists.txt`
   looks), then `flutter build linux --release`. Confirmed the **bundle's**
   `lib/libskotiq_bridge.so` carries the new strings (`park-and-close policy`,
   `holding the run for a human`, `stopped guiding for its sweep`,
   `is using the camera and filter wheel`) and that `UNATTENDED rig` and
   `requested retry attempt` are gone from it — 0 occurrences.

2. Ran that bundle headless and drove the route live:

```
SKOTIQ_PORT=18123 SKOTIQ_DATABASE_DIR=<scratch>/nsdb \
SKOTIQ_DATA_DIR=<scratch>/nsdata SKOTIQ_ALLOW_UNAUTHENTICATED=true \
LIBGL_ALWAYS_SOFTWARE=1 ./skotiq_desktop --headless
```

  * payload **without** `parkAndCloseWhenRecoveryGivesUp` (an older client):
    `HTTP=200`, native logged `park_and_close_on_give_up=false`
  * explicit `true`: `HTTP=200`, native logged `park_and_close_on_give_up=true`
  * explicit `false`: `HTTP=200`, native logged `park_and_close_on_give_up=false`

  So the setting reaches the live native config, and a missing value means "hold",
  never "park". No panics or unhandled exceptions in the log; clean SIGTERM shutdown.

I did not launch anything on `DISPLAY=:0`, and did not touch the owner's imaging laptop
or its API.

## Tests added

Escalation matrix, cause by cause (`executor/tests/recovery_tests.rs`):
`the_escalation_matrix_is_pinned_cause_by_cause`,
`recovery_escalation_defaults_to_holding_and_abandons_only_on_opt_in`,
`consecutive_reject_storm_escalation_promises_and_performs_a_pause`,
`stepping_is_not_guiding` (the owner's -56.8 / -54.4 px offsets as the fixture),
`only_rig_protecting_triggers_evaluate_while_paused`,
`the_guiding_failure_trigger_maps_to_a_recovery_cause`.

Scenario 7c (`executor/scenario_sim_tests.rs`) is the owner's failure as a regression
test: it drives the real `apply_recovery_escalation` against real device-ops with his
numbers (`ConsecutiveRejectsExceeded`, attempt 1, his verbatim escalation message) and
asserts **no** `mount_park`, **no** `cover_close`, **no** `dome_close`, tracking
restored, and a resumable `Paused`. 7a/7b were renamed off the attended/unattended
vocabulary and 7b now pins the explicit `ParkAndClose` policy.

Guider-resume halt (`instructions/tests/autofocus.rs`), against a new mock builder
`with_guider_resume_that_never_guides` that reproduces PHD2 accepting a resume and never
reporting guiding: `a_failed_guider_resume_is_marked_not_just_described` (marker stamped
AND the latch cleared), `a_successful_guider_resume_leaves_the_result_alone`,
`the_two_autofocus_failure_costs_are_distinguishable`,
`the_unguided_hold_message_says_what_happened_and_what_did_not`,
`a_guiderless_sweep_is_not_retried_across_attempts`.

Device arbitration (`instructions/tests/expose.rs`) at the level where the race happened:
`the_capture_loop_does_not_move_the_wheel_under_a_trigger_claim` drives the real
`execute_exposure` with a trigger holding the train and asserts the wheel is untouched
until release, then moved; `a_trigger_action_cannot_take_the_train_mid_frame` asserts a
5 s recenter cannot take a camera mid-180 s frame and that the wait it is told to expect
comes from the 180 s frame.

Claim mechanics (`executor/tests/runtime_tests.rs`):
`an_overrunning_exposure_keeps_the_imaging_train` (the 65 s-vs-180 s defect),
`the_imaging_train_claim_covers_the_filter_wheel_too`,
`a_stale_release_cannot_free_a_newer_claim`,
`imaging_train_claim_expires_rather_than_wedging`.

Headless route (`apps/desktop/test/headless_api/sequencer_handlers_test.dart`): a payload
omitting the new flag must not 400, so an older mobile client can still save recovery
settings.

## Process note

I ran `git stash --include-untracked` once by mistake (the common brief forbids it).
Caught it in the same minute, `git stash pop`ed it back, and verified the tree: 31 files
changed, 891 sequencer tests still green. The pre-existing `stash@{1}` from `main` was
not touched. No work was lost.

## Left undone / needs the rig

* **On-sky re-validation of the halt.** A real guider-resume failure on the owner's rig
  is the only thing that can confirm the halt fires and the run stays resumable there.
  The unit and scenario tests drive the production functions, but they cannot prove PHD2
  behaves as the mock does on his hardware.
* **On-sky re-validation of the arbitration.** I closed the interleaving on the seams the
  evidence names. Only a real EFW + ASI1600MM under a real trigger-fired autofocus can
  confirm no fourth writer sneaks in — `flat_wizard/mod.rs` is the remaining
  unarbitrated wheel writer, left alone because the wizard does not run concurrently
  with a sequence and bringing it in would have widened this change into the wizard's
  lifecycle.
* **Pre-existing, reported not fixed: nothing in the app pushes recovery settings to
  native.** `updateRecoveryConfig` has no in-app caller — nor do its siblings
  (`updateDitherConfig`, etc.). `Settings > Recovery Mode` persists to the DB and reaches
  native only via the HTTP route or the FFI API. So all five recovery fields, mine
  included, are reachable over the API (verified live above) but not from the desktop
  settings page. That affects the four pre-existing fields identically and is a
  settings-push wiring gap, not a w21 defect. I deliberately did **not** add an
  `AppSettings` field and a UI toggle: a control that persists and reaches nothing is
  exactly the dead-config pattern this workstream exists to remove, and offering the
  owner a switch that parks his mount is a product call that is his to make. **Route to
  the owner.**
* **Not touched, per the brief:** the image grader and every HFR threshold. The grader was
  right; 15.61 px is a ruined frame.

## Notes for w22-reporting

* `runVitals` reporting `framesCaptured: 0, framesRejected: 0` while the grader had
  captured and rejected 3 is untouched here — yours.
* The preflight ASTAP false negative (`detect_astap_catalog(None, None)` relying on an
  empty `ACTIVE_SOLVER_PREF` instead of resolving next to the installed exe) and the
  missing field-scale hint are untouched — yours.
* Failure-cause selection: I added a new terminal shape you may want to surface. Under
  the default policy an exhausted recovery now ends `Failed` with progress message
  `Recovery exhausted after N attempts` and an Error event saying nothing was parked or
  closed. And the new guider halt ends in `Paused` with
  `Paused: autofocus left the guider stopped`, plus a `SystemEvent` decision row
  `AUTOFOCUS_TRIGGER_UNGUIDED_HOLD_SUMMARY` ("Autofocus left the guider stopped — run
  held, no unguided frames"). Both are worth a distinct cause rather than a generic one.
