# B-fix batch: imaging-guiding-polar

Cluster report: `reports/release-pass/gui/imaging-spine.md`.
Ladder: failing test first, then fix, then green. Log appended as work proceeds.

## IMG-1 — capture-folder validation latches

Located at `packages/skotiq_app/lib/screens/onboarding/steps/capture_dir_step.dart`
(outside the batch's nominal scope dirs but the item is assigned here; the file is
touched only for this defect).

Read: the step commits a typed path on `onSubmitted` and on focus loss only. There is no
`onChanged`, so editing the box leaves `_check` / `_checkDetail` describing the *previous*
text — exactly the latch in the report. Clicking Next does not move focus off a Flutter
`TextField`, so the natural recovery (select-all, retype) never re-runs the validator.

Fix: `onChanged` drops a verdict that no longer describes the box and re-runs the
check 500 ms after typing settles. Tests:
`packages/skotiq_app/test/screens/onboarding/capture_dir_revalidate_on_edit_test.dart`
(both cases proved failing at HEAD first). All 7 capture-dir suites green.

## IMG-8 — guider never leaves Settling

Root cause is native, in `builtin_guider.rs::apply_settle_state`: after a settle
completed it cleared both deadlines, so the very next in-tolerance guiding frame
re-armed the settle and published `Settling` again — one frame after every
`Settled`. The screen chip (phd2StateProvider) therefore read `Settling`
essentially always, while the status bar (guiderState.isGuiding, set once by
`GuidingStarted`) read `Guiding`. The re-armed `settle_timeout_deadline` could
also fail the loop task and stop a session that was guiding fine.

Fix: settling is an explicit episode (`BuiltinGuiderState.settling`) opened by the
post-calibration settle and by each dither, closed when it completes/abandons/
times out; `apply_settle_state` is a no-op outside an episode. Proved failing at
HEAD (`a settled guider re-entered settling on the next ordinary frame`), then
green — 53 builtin_guider tests pass.

## IMG-12 / IMG-13 / IMG-16 — polar alignment

Both stop implementations read clean (screen -> controller -> notifier ->
backend; native takes a cancel flag, a 6 s cooperative grace and a force-abort),
so the reproducible defect is that a teardown taking seconds published NOTHING:
no status change, no button change. Plus the run's last act — failing the solve
it was blocked on — was published as the run's outcome, so a stopped run
presented as `Error: Plate solve timed out`.

Fixes: the notifier publishes `Stopping polar alignment…` before asking the host
and suppresses a native failure that lands inside a requested stop (logged, not
shown); the screen's Stop reads `Stopping…` and is disabled while in flight; the
measuring panel's activity line derives from the published status instead of the
hardcoded "Capturing Point N"; the bullseye draws an empty target and says
"No measurement yet" when there is nothing measured.

## IMG-4 — "Found 0 objects" on a failed solve

The pipeline branched only on `PlateSolveResult.success`, so a result carrying no
usable geometry (no field scale) still became a catalog search over a field of
zero size and reported the benign `AnnotationState.complete(0)` in the success
treatment. Guard added (`_unusableSolveGeometry`), proved failing at HEAD.

## IMG-14 — parked mount preflight

The wizard knew the mount was parked (`MountState.isParked`) and started anyway,
then blamed the solver. Start is now blocked with "Mount is parked — unpark it
before aligning", alongside the existing camera/mount/solver/site blockers.
NOT done: adjudication delta 2's second half (pointing the polar + annotate
solver calls at the hinted FITS writer in `unified_device_ops::plate_solve`).
Recorded as blocked — the polar path writes its own header via
`write_temp_fits_for_solve` with a bare `FitsHeader::new()`, so closing it means
sharing the hint-gathering block between the two writers.

## IMG-9 / IMG-10 — guiding

IMG-9: `capture_and_store_loop_frame` stored the frame's SNR/star mass in
`last_status` but published no `GuideStats`, and every one of the loop's readouts
is fed by that event. Now announced via `publish_star_measurement` (proved red by
removing the publish, then green).
IMG-10: Pause is a PHD2 command; the screen correctly passes no handler for the
built-in guider, but the disabled button gave no reason. `GuideControlsPanel`
gained `pauseUnavailableReason` (tooltip + semantics label).

## IMG-18 / IMG-19 / IMG-21 — flat wizard

IMG-18: the capture loop published `image.displayData` (bare bytes), which the
preview cannot render without dimensions, so it showed "No flat captured yet" for
the whole run. `setLastImage` is now typed to `CapturedImageResult?` and the call
site passes the frame.
IMG-19: the per-filter row is a horizontal `ListView` with no scrollbar and no
follow — it now has both, so the filter being captured is in view.
IMG-21: Stop Capture reads "Stopping…" and is disabled while the cancel is
cooperative-pending.

## IMG-2 / IMG-3 / IMG-16 — overlays and empty markers

IMG-2/3: the scale bar and compass rose anchored to the same bottom corners as
the histogram and image-stats readouts. Both painters take a `bottomMargin`, fed
from `PreviewReadoutInsets`, and a layout test measures the real readouts and
proves the painters clear them.
IMG-16: the polar bullseye draws an empty target and says "No measurement yet"
with nothing measured; the Guiding twin now passes
`showCurrentError: currentError != null` (it defaulted to true and the absent
error was coalesced to 0).

## Verification

- `skotiq_app`: 492 tests green with `--exclude-tags golden`.
- `skotiq_core`: 4285 tests green (`test/services`, `test/providers`).
- `cargo test -p skotiq_bridge --lib`: 538 green.
- `dart analyze` over skotiq_core/lib, skotiq_app/lib, apps/desktop/lib:
  0 errors, 0 warnings (17 pre-existing `info` deprecations).
- The `captures_landscape_test.dart` golden captures fail on Linux at HEAD too
  (`@Tags(['golden'])`, host-specific baselines, excluded by `melos run test`).
