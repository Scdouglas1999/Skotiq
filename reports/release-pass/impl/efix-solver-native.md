# E-fix batch: solver-native

Items: IMG-14 (FINAL, both halves), ND-E2, IMG-9 (residual).
Tree at start: GREEN at HEAD, branch `audit/end-to-end-campaign`.
Constraints honoured: no GUI harness, no bundle rebuild, no FRB regen, no melos,
no generated files. One deviation is recorded at the bottom (accidental
`git stash`, fully recovered).

---

## IMG-14 (a) — the field-scale hint never reached the solver that runs

**Third strike on the two-implementations trap.** The `-fov` work had landed in
`PlateSolveService.astapArguments` (Dart) — a *fallback* that only runs when the
backend call throws. Every production solve goes Dart → bridge → `skotiq_imaging`,
and the native `AstapSolver::solve` accepted a `hint_scale` argument that **no caller
ever passed**. Live proof from Wave E: `grep -c -- "-fov"` over the whole session
log = 0, while the polar wizard logged `1.29"/px` one line before solving blind.

### What now carries the scale

| Call site | Before | After |
|---|---|---|
| `api/polar_alignment/run_loop.rs` (3 measurement solves) | `api_plate_solve_blind(path, timeout)` | `plate_solve_blind_scaled(path, timeout, solve_scale)` where `solve_scale = solve_hints.arcsec_per_px()` — the same number `log_scale` prints |
| `api/polar_alignment/run_loop.rs` (adjustment loop) | `api_plate_solve_blind(path, 30)` | same, with `solve_scale` |
| `unified_device_ops/device_ops.rs::plate_solve` (imaging/sequencer/centering/meridian flip) | `api_plate_solve_near(..., hint_scale.unwrap_or(5.0), None)` | `plate_solve_near_scaled(..., SEARCH_RADIUS_DEG, None, scale_hint)` / `plate_solve_blind_scaled(..., scale_hint)` |
| Dart-originated solves (imaging annotate/snapshot, science, post-session) | FFI signature carries no scale | the bridged `api_plate_solve_*` resolve one themselves — see `resolve_solve_scale` |

`resolve_solve_scale(path, explicit)` order of authority:
1. what the caller measured for this frame,
2. **the frame's own header** (`FOCALLEN` + `XPIXSZ` via the new
   `skotiq_imaging::fits_scale_arcsec_per_px`) — correct even for an imported
   frame from another rig,
3. the active profile's optics + this camera's pitch (`SolveHints::arcsec_per_px`,
   binned).

A rig supplying none of the three behaves exactly as before: no `-fov`, blind
ladder, and the pre-existing warning from `SolveHints::log_scale`.

### Second bug found on the way

`hint_scale` (arcsec/pixel) was being spent as ASTAP's **search radius in degrees**
(`hint_scale.unwrap_or(5.0)`), and `sequencer/src/polar_align/mod.rs` was passing
its `solve_timeout` (30) through that slot — a 30° search radius sourced from a
timeout. Fixed at both ends: the radius is now `SEARCH_RADIUS_DEG = 5.0` and the
polar-align steps pass `None` for a scale they do not measure.

### Why this cannot silently recur

* `build_astap_args()` extracted from `AstapSolver::solve` — the argument vector
  is now readable by a test with no ASTAP, no catalog and no frame.
  `platesolve.rs::astap_arg_tests` (5 tests) asserts `-fov 0.7353` for
  1.2926"/px × 2048 px, asserts a near solve carries position **and** scale, and
  asserts an unreadable height drops the hint rather than guessing.
* `blind_solve_with_timeout` / `solve_near_with_timeout` now **require** the
  `hint_scale` parameter — a caller that knows the scale and forgets it is a
  compile error, not a silent blind solve.
* New INFO log emitted only when the hint is actually applied:
  `ASTAP field-scale hint: 1.29"/px over 2048 px = -fov 0.7353 deg`. Its absence
  in a session log is now proof the hint did not reach ASTAP.
* `PlateSolveService.astapArguments` carries a doc block naming the Rust builder
  as the implementation production runs, so the next wave fixes the right one.

**Failing-first evidence:** the first run of
`a_scale_hint_becomes_fov_degrees_of_field_height` failed on the computed value
(expected `0.7351`, got `0.7353`), proving the assertion executes the real builder.

---

## IMG-14 (b) — the parked-mount refusal said nothing

The Wave-D fix disabled Start and put the reason in a `Tooltip`. Live: "no run,
no message, footer still 'Ready to start polar alignment', button not [DISABLED]
in the a11y tree". A hover tooltip is invisible to a click, to a screen reader
and to a photograph of the screen — and the D-fix test asserted on
`tooltip.message`, which is why it passed while the screen said nothing.

* `_screen_shell.dart`: while idle, the footer renders
  `Cannot start: <blockers>` in warning colour with a warning icon, keyed
  `startBlockedNoticeKey`, instead of the generic status line.
* `polar_alignment_screen.dart`: `_startAlignment` refuses a parked mount with a
  stated reason (covers a mount that parks between build and click).
* Tests (`polar_alignment_run_feedback_test.dart`): the footer text contains
  "parked", the screen does **not** still read "Ready to start polar alignment",
  and the Start button's semantics node has `isEnabled == false`. These could not
  compile before the fix (the key is new).
* `polar_alignment_honesty_test.dart` relaxed from `findsOneWidget` to
  `findsWidgets` for "No observing location set" — panel disclosure + footer
  blocker are two surfaces by design.

---

## ND-E2 — two concurrent ASTAP solves of one frame

The process gate serialised solves but did nothing about *the same frame being
solved twice*: a snapshot produced a hinted solve and, 4 ms later, a **blind**
solve of the same file, with a 5 ms poller counting two `astap_cli` processes.

`coalesced_solve(file_path, label, solve)` in `api/plate_solve.rs`:
* keys on the canonicalised path; the first caller leads, later callers on the
  same frame await the leader's result instead of launching a solver;
* an `InFlightGuard` releases the frame even if the future is dropped or panics,
  so one abandoned solve cannot wedge every later solve of that file;
* the follower logs
  `Plate solve (blind): <path> is already being solved; waiting for that result
  instead of starting a second solver process` — the double-caller is now named
  in the log rather than inferred from a process poller;
* `acquire_solve_gate(label)` logs how long a solve waited for the gate, so
  "the solver is slow" and "two callers are solving at once" stop looking alike.

Tests (`solve_coalescing_tests`): two callers on one frame run **one** solver and
both receive the leader's answer; two different frames still get two solves; a
finished solve releases its frame (so a re-solve after a re-point is not served a
stale answer).

Note: I could not reproduce the live intermittency without the GUI harness. The
fix is written to be correct regardless of which pair of callers races — it
dedupes at the single native funnel every solve passes through.

---

## IMG-9 — Auto Select was silent

The D-fix reported the outcome through `ScaffoldMessenger` (a snackbar on the app
shell) and a `loggingService` entry. Live: three clicks, "no notice, no toast, no
status text anywhere in the a11y tree, and no dedicated line in either log
stream". A snackbar is gone four seconds later — already gone by the time the
screen was read — which is why the widget test passed and the app looked dead.

* UI: `onFindStar` now returns `Future<String?>`; `GuideControlsPanel` renders it
  in its **own** notice banner (`noticeBannerKey`), which is part of the panel and
  persists until dismissed. `_runAction` folded into `_runReportingAction` so
  every control shares one busy/error lane. The snackbar helper is gone.
* Log, in the implementations that run:
  `api_guider_find_star` logs which backend was asked (`PHD2` / `built-in`) and
  what came back (`locked guide star at (x, y) px` or the refusal);
  `builtin_guider::find_star` logs the chosen star **and the detection count**,
  and on failure `no usable guide star among N detections` — which separates
  "the frame is empty" from "the frame is full and none are usable".
* `guiding_auto_select_feedback_test.dart` now asserts the message is a
  descendant of the panel's notice banner, not merely somewhere in the tree.

---

## Verification

| Suite | Result |
|---|---|
| `cargo test -p skotiq_imaging --lib` | 533 passed |
| `cargo test -p skotiq_bridge --lib` | 555 passed, 4 ignored |
| `cargo test -p skotiq_sequencer --lib` | 782 passed |
| `cargo check --workspace` | clean |
| `flutter test test/screens/polar_alignment/{run_feedback,honesty}` | all passed |
| `flutter test test/screens/guiding/ test/widgets/phd2/` | all passed except golden captures |
| `flutter analyze` (touched files) | no issues |
| `cargo fmt` (3 touched crates) + `dart format` (touched files) | applied |

**Pre-existing failure, not caused by this batch:** `captures_landscape_test.dart`
golden comparisons fail on Linux. Verified by running the *untouched*
`test/screens/framing/captures_landscape_test.dart`, which fails identically.
Goldens were captured on Windows; no goldens were regenerated.

## Deviation to record

While checking working-tree state I ran a `git stash push` (an accident — it was
meant to be a read-only status probe). It stashed all 53 concurrently-modified
files, mine and other agents'. Recovered immediately and fully:

* every stashed file that was still untouched was restored from `stash@{0}`;
* two files another agent had re-edited after the stash
  (`scheduler_engine.dart`, `time_control_panel.dart`) were merged by hand —
  `scheduler_engine.dart`'s post-stash change (a `rejection_labels.dart` import)
  was already present in the stashed version, and `time_control_panel.dart`'s
  post-stash hunk (the `_readoutNode` wrap around the PAUSED chip) was re-applied
  on top of the restored file;
* the index was reset so nothing is left staged.

`stash@{0}` is deliberately **left in place** as a recovery point rather than
dropped. Verified afterwards: `git diff --name-only` shows only expected files and
`cargo check --workspace` + the app test suites compile and pass.
