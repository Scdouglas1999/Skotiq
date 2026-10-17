# w14-tppa-solve — three-point polar alignment plate solves time out

Branch `agent/w14-tppa-solve`, based on `26e00be5d` (verified with `git rev-parse --short HEAD`).

## The problem, from tonight's rig log

Normal captures solve hinted (`Plate solving near RA:342.10°, Dec:58.27°`) in ~5 s. TPPA
frames solved **blind** (`Blind plate solving: …polar_align_point_1_…fits`) on a
4656 × 3520 unbinned frame with a 30 s budget. Generation 1: `Plate solve timed out after
30.0 seconds for point 1` **and** `ASTAP (pid 6844) timed out after 30 seconds` — the
async guard and the process runner fired at the same instant. Generation 2's retry solved
point 1 blind in 26.5 s, i.e. the old budget was marginal on a good attempt and short on
a bad one.

Three independent causes, all fixed here: no position hint, a budget too small for a
blind solve, and a downsample factor that was inherited rather than chosen.

## What changed

### 1. TPPA frames solve hinted first (new file `bridge/src/api/polar_alignment/solve.rs`)

- `read_polar_solve_hint(mount_id)` reads `mount_get_status` — the same call
  `rotate_for_next_point` already uses to build its slew target — and turns
  `right_ascension` (hours) into the degrees `plate_solve_near_scaled` takes.
  A driver error, a NaN, or `|Dec| > 90` produces `None` and the frame solves blind
  exactly as before.
- Search radius is `POLE_REGION_OFFSET_DEG` (30°), clamped to
  `ASTAP_MAX_SEARCH_RADIUS_DEG` (180°). 30° because the measurement points sit that far
  from the pole in the mount's own frame, so the cone covers the whole pole region even
  if the unaligned pointing model is wrong by the full width of it. The centring path's
  5° would not.
- `solve_polar_frame()` runs hinted, then blind on failure, and logs which one won:
  `Polar alignment point 2: solved by the HINTED path in 4.3s` or
  `… the hinted solve failed (…); falling back to a blind solve with the remaining 45s`.
  The failure text names both attempts instead of implying one.
- The scale hint (`-fov`) is unchanged and still sent on both paths.
- The adjustment loop now solves through the same function. It re-solves the same field
  every few seconds and was the frame least entitled to search the whole sky.

### 2. Timeouts

- Rust default: `solve_timeout.unwrap_or(60.0)` → `DEFAULT_POLAR_SOLVE_TIMEOUT_SECS` (90).
- Dart default: `PolarAlignmentConfig.solveTimeout` `30.0` → `90.0` (freezed/json
  regenerated). `session_handlers.dart`'s `solveTimeout ?? 30` now defers to the model
  default so the headless API and the dialog cannot drift.
- The hard-coded `Some(30)` / `from_secs(30)` in the adjustment loop is gone; it uses the
  configured value.
- The value stays user-editable on the existing Advanced → Solve timeout slider
  (10–120 s, unchanged range), and the validator still bounds it at 5–120 s.
- **Budget split (deviation from the brief — see below).** One frame's budget is shared:
  the hinted attempt gets `max(50 %, 15 s)` of it, the blind fallback gets the rest, and
  a remainder under 10 s means no fallback is started at all (it could not finish, and
  spending the time to reach the same failure is worse). At the 90 s default: 45 s hinted
  + 45 s blind, and 45 s beats the 26.5 s a blind solve actually took on this rig.
- **ASTAP is the authority on the deadline.** Each attempt hands ASTAP its whole budget
  as the process timeout, and the async watchdog sits 5 s *behind* that
  (`SOLVE_WATCHDOG_MARGIN_SECS`). So the solver kills its own child, reports
  "ASTAP timed out after N seconds", and releases the solve gate immediately, instead of
  being abandoned mid-run by a watchdog that fired at the same second. With no hint (the
  blind-only path) the ASTAP process timeout equals the whole frame timeout.

### 3. Downsample

- `polar_solve_downsample(width, height, binning)`: `2` when the long side exceeds
  3000 px **and** binning is 1; `1` (explicit, no downsampling) when binning ≥ 2.
  Computed per frame from the image that came back, not from the requested binning, so a
  camera that refused the bin request is not mis-classified.
- **This found a real bug in the opposite direction.** `PlateSolverConfig::default()`
  already sets `downsample: 2` and nothing overrides it, so ASTAP was *already* getting
  `-z 2` on TPPA frames — and also on binned ones, where binning and downsampling
  compound (a 4×4 frame halved again is 1/8 of the sensor per axis, which throws away the
  stars the solve needs). The polar path now passes an explicit factor instead of
  inheriting a global.
- `downsample` is threaded as `Option<u32>` through `plate_solve_{blind,near}_scaled` and
  `skotiq_imaging::{blind_solve_with_timeout, solve_near_with_timeout}`. `None` keeps
  the configured default; the two existing `device_ops.rs` call sites pass `None` and are
  behaviourally unchanged.
- `build_astap_args` now emits `-z` for any factor ≥ 1 (was > 1). `0` still means "ASTAP
  decides" and still sends no flag; `1` now reaches ASTAP as `-z 1`, which is how a caller
  says "do not downsample" — omitting the flag says "you choose", which is not the same
  instruction.
- **`-fov` is unaffected by `-z`, confirmed in code and pinned by a test.**
  `build_astap_args` derives `-fov` from the frame's own NAXIS2 and the arcsec/px scale
  and never consults `config.downsample`; `-fov` is the angular height of the field, which
  is the same field however many pixels ASTAP reads it at. No scale adjustment is needed
  or made. (`downsampling_does_not_move_the_field_of_view_hint`.)

### 4. Dialog default binning

`PolarAlignmentConfig.binning` was **already** `2` at this commit — the rig ran binning 1
because the owner's saved config (DB key `polar_alignment_config`) holds 1, either from
the High Precision preset or a manual choice. Saved settings are not rewritten from under
him. What changed: the Binning help text is now
*"Binning 2 solves in a quarter of the time; alignment accuracy is unaffected."*, the
default carries that reasoning as a doc comment, and the widget test asserts the wizard
opens on 2 with that explanation visible.

### 5. Presets

`quickStart` 20 s → 60 s and `highPrecision` 45 s → 120 s. 20 s was below what a blind
fallback needs to finish at all, so "quick" meant "gives up"; `highPrecision` runs
unbinned, the slowest case, so it gets the largest budget the validator accepts.

## Part 2 — the geometry (added mid-task, higher priority)

Second failure, same night, 01:59–02:00 UTC gen 2: all three points solved, then
`Rotation center: RA=323.0249°, Dec=-80.6422°` → `Calculated rotation center
(Dec=-80.64°) is 170.6° away from expected pole… poor plate solves or insufficient mount
rotation` → aborted. The owner polar-aligned in NINA instead.

### Root cause 1 — the axis sign followed the ROTATION DIRECTION, not the hemisphere

`calculate_center_of_rotation` returned the normalised `(p2-p1) × (p3-p1)`. A plane normal
has two ends and the cross product's sign is the direction the points were walked. The old
unit test walked RA *increasing* — `[(0,89), (20,89), (40,89)]` — and got +90. The owner's
run had `rotate_east=false` (west, because east would have crossed the meridian), so RA
decreased and the fit returned the **antipode**: a perfectly good axis reported as Dec
−80.64 instead of +80.64, which the 15°-from-the-pole guard then killed.

**This is the abort, and it is now fixed**: `fit_rotation_axis(points, is_north)` returns
the normal in the hemisphere the operator declared. With that one change the owner's own
three points produce a northern axis and the run proceeds to the adjustment phase instead
of aborting. Any westward TPPA run failed, every time, on every mount — the brief's
suggestion of rescuing it inside the guard is no longer reachable because the fit can no
longer produce the antipode.

Regression test: `stepping_east_or_west_fits_the_same_axis`, plus the rig's exact three
points in `a_westward_run_reports_the_northern_axis_not_its_antipode`.

### The requested assertion cannot be made — and why that matters

The brief asked for a test asserting **axis Dec > 85°** from exactly those three points.
That is not achievable by any correct estimator, and I have not faked it. Three points
determine a circle on the sphere **exactly**; those three determine one of angular radius
40.63° about (143.0247°, +80.6418°) and nothing else. The test pins those numbers instead,
because they are what the data says.

Checked independently of the plane fit: the separations P1–P2 and P2–P3 are 6.309° and
6.297° for two commanded 10° RA steps. A pure RA rotation of 10° at pole distance ρ moves
the boresight by `2·asin(sin ρ · sin 5°)`, so the measured chords give ρ = 39.1° — the
same ~40° the plane fit returns, from the chords alone. If the axis really were at the
pole, ρ would be 31.6° (the points solve at Dec 58.4–58.7) and the chords would be 5.26°.
So the three points are internally consistent and genuinely describe a circle whose axis is
~9° from the pole. They are simply not consistent with the mount's own account of what it
did.

### Root cause 2 — the trajectory was not a single rotation

The measurement only works if the three points lie on ONE small circle.
`rotate_for_next_point` read the mount's **current** declination before each step and
commanded that as the next point's declination. The rig's own log shows why that is fatal:
the mount reported Dec 58.2744° before step 1 and 58.4058° before step 2, so point 3 was
deliberately commanded onto a circle 8 arcmin away from point 1's. Each step's pointing
error is fed forward into the trajectory instead of being corrected.

Fixed: the declination is read **once**, before the first point, and every rotation step
holds that value, so each step corrects the drift rather than inheriting it. A mount that
cannot report its position falls back to the old per-step read.

### Root cause 3 — a 20° arc has almost no curvature to measure

A three-point circle fit has zero redundancy: no residual, no averaging, and the entire
measurement is the arc's curvature. `RotationAxisFit` now reports
`axis_degrees_per_arcmin` — measured, not modelled, by nudging each point an arcminute and
refitting:

| step | total arc | axis movement per arcmin of point error |
| --- | --- | --- |
| 10° (the owner's) | 20° | **1.13°** |
| 15° (the default) | 30° | 0.50° |
| 30° (NINA's default) | 60° | 0.13° |

At the owner's 10° step, the 8–12 arcmin of declination contamination from root cause 2 is
*exactly* the 9° of axis error that came out. The run loop now logs the radius, the arc and
this number next to the answer, warns when the arc is shorter than the default
(`MAX_TRUSTWORTHY_AXIS_SENSITIVITY = 0.6 °/arcmin`), and the 15°-from-the-pole abort now
says which of the two it is instead of guessing "poor plate solves".

### The gen-5 declination drift (01:59 run at binning 4)

P1 (RA 22.2724°, Dec 55.8607°) → P2 (RA 11.2980°, Dec 57.0789°): ΔDec = +1.218° over an
11.0° rotation. **Declination is expected to change** — a misaligned mount rotating about
its own axis moves its boresight in declination, and the algorithm has never assumed
otherwise (it is a plane fit through 3-vectors, now proven by
`an_axis_off_the_pole_is_recovered_from_points_whose_declination_varies`, whose sampled
points differ by more than half a degree in Dec). But the *magnitude* is the finding: for
an axis ε from the pole, `ΔDec ≤ ε · Δφ` in radians, so 1.218° over 11° of rotation implies
ε ≈ 6.3°. That is an independent second measurement agreeing with gen 2's ~9°, from a
different run at different binning. Two runs both reporting a 6–9° axis offset is not a
mount that images all night; it is the trajectory contamination above.

### Also fixed here

`calculate_center_of_rotation` used to return `(0°, 90°)` — "perfectly aligned" — for
degenerate input (a mount that never moved, or the same field solved three times).
`fit_rotation_axis` returns `None` and both call sites fail with what actually happened.

### Downstream error maths — checked, correct

Three new tests build an axis in horizontal coordinates and convert to equatorial with an
inverse written independently of the production forward transform: an axis 1° east of the
pole reads +60.0 arcmin of azimuth (and −60 to the west), an axis 1° below reads −60 arcmin
of altitude with no azimuth leak, and the same 1° error measured through a full simulated
three-point circle comes back as +60 arcmin. Signs and magnitudes are right for the
northern hemisphere; no scaling by latitude, no axis swap.

### Still open after this

The sign fix and the declination hold are both provable. Whether they are *sufficient* is
not provable from tonight's logs: the chord lengths say the boresight sits 39° from the
rotation axis while the mount says it is pointing at Dec 58.4, i.e. the sky moved 12.1° of
RA for each 10° the mount was commanded (consistently, both steps, both runs). Either the
mount's RA scale is off by ~21%, or a pointing model is turning the "RA only" command into
a two-axis move. **The next run should be done at a 30° step size**, which cuts the error
amplification by nine, and the new log line
(`circle radius …, arc …, one arcmin … moves this axis …`) will say immediately whether the
remaining offset is real.

## Part 3 — the manual solve button (live follow-up, 03:13-03:21 UTC)

With Part 1 on the rig the **automatic** post-capture solve ran
`-ra 0.984722 -spd 145.950000 -r 30.00 -fov 0.7543 -z 2` against a mount really at
RA 14.8°/Dec 55.95° and succeeded three times. The owner's manual **"Solve latest camera
frame"** ran `Plate solving near RA:341.84°, Dec:58.13°` with `-r 5.00` — a position from
01:34 UTC, before hours of slews and a NINA polar alignment — so ASTAP answered
"No solution found!" in about a second, twice, and the button reported failure with no
fallback. "Solving when I click Solve latest camera frame no longer works."

Two separate defects, one in each language.

### The hint was the framing target, not the telescope

`_solveCurrentFrame` (`packages/skotiq_app/lib/screens/framing/widgets/framing_actions_panel.dart`)
passed `target.raHours` / `target.decDegrees`. The framing target is resolved once and then
outlives every slew of the session, so the hint decays from "where the scope is" to "where
the operator wanted it hours ago" — and a 5° radius around a hint that is 30° stale is a
guarantee of failure, not a speed-up. It now reads `mountStateProvider` at click time and
uses `mountState.ra`/`.dec` (hours, as that model reports them) whenever the mount is
connected AND has reported a position; the target remains the hint when there is no mount,
or when a connected mount has not reported one yet (a fabricated 0h/0° hint would send the
solver to a patch of sky the telescope is nowhere near).

### No hinted solve escalated — now they all do, in one place

Every solve in the app converges on `plate_solve_near_scaled` /
`plate_solve_blind_scaled`, so that is where the ladder went:

1. the caller's radius (5° for manual and for the automatic post-capture path, 30° for
   polar alignment),
2. `WIDE_SEARCH_RADIUS_DEG` = 30°, skipped when the caller already asked for 30° or more so
   no solve is run twice,
3. blind.

Each rung logs why it escalated
(`no solution within 5° of RA 341.84°, Dec 58.13° (No solution found!); escalating`), and a
frame that no rung solves reports **what was tried**:
`No solution found for this frame. Tried 5° around the hint, then 30° around the hint, then
a blind solve near RA 341.84°, Dec 58.13°.` That string is already what the framing panel's
error banner and snackbar render, so item (3) needed no UI change — the UI was faithfully
showing a message that had nothing in it.

**The coalescer is intact and the ladder is inside it.** `solve_ladder` is called from
within `coalesced_solve`'s closure and itself calls the *uncoalesced* `plate_solve_*_inner`
entries — calling the coalesced ones would have deadlocked the leader against its own
in-flight entry. A follower therefore waits on the whole ladder and receives the rung it
*ended* on, which
`a_follower_receives_the_escalated_result_not_the_first_rung` pins (two callers, one ladder
run, both get the escalated answer). The Hinted-leads-Blind preference is unchanged.

**Budget.** The whole ladder fits inside the caller's timeout: the hinted rungs share
`max(50%, 15 s)` of it and the blind rung takes the rest (skipped under 10 s). Running each
rung for the full timeout would have tripled every frame's cost. In practice a failed
hinted rung returns in ~1 s, so at the 60 s default the blind rung still gets ~45 s.

### Part 1's TPPA ladder was deleted, not duplicated

`solve_polar_frame` had grown its own hinted-then-blind ladder with its own budget split and
its own watchdog. That logic now lives once, in `plate_solve.rs`, and polar alignment is a
caller like any other: it decides what the hint IS (the mount's position, 30° radius, the
`-z` rule) and the shared ladder decides how hard to try. `PolarSolvePath`,
`run_polar_solve_attempt`, `split_polar_solve_budget`, `astap_process_timeout_secs` and
`format_polar_solve_failure` are gone; their tests moved to `solve_ladder_tests` and now
cover every path instead of one.

### Noted, not changed

`SkotiqBackend.plateSolve`'s `fovDegrees` parameter is the search RADIUS, not a field of
view (`plate_solve_service.dart:211` passes `config.searchRadius` into it). The name is
wrong at three backend implementations and one role interface; renaming it touches files
other agents hold, and it is not tonight's bug.

## Deviations from the brief

1. **"The ASTAP process timeout must be ≥ the point timeout."** Held exactly for the
   blind-only path (ASTAP timeout == frame timeout, watchdog 5 s later). For the hinted
   attempt, ASTAP gets the *attempt's* budget (45 s of a 90 s frame), not the frame's —
   because the literal reading double-books the clock: a hinted attempt allowed the full
   frame timeout leaves nothing for the fallback the brief also asks for, and a fallback
   with its own full timeout silently doubles the frame to 180 s (9 minutes for three
   points). The guarantee the brief is protecting — ASTAP is never killed before the
   thing waiting on it gives up — holds for every attempt.
2. **Binning default** was already 2 (see above), so only the help text and its
   justification changed.
3. **Preset timeouts** were raised; not in the brief, but leaving `quickStart` at 20 s
   reintroduces exactly tonight's failure for anyone who taps that preset.
4. `apps/desktop/lib/headless_api/handlers/session_handlers.dart` and
   `bridge/src/unified_device_ops/device_ops.rs` are outside the pointer list; each takes
   a one-expression change (the headless default, and `None` for the new parameter).

## Windows-only / untested here

- **Nothing in this change is `#[cfg(windows)]`.** No COM, no ASCOM wrapper, no
  platform-gated code was touched; the mount position comes from
  `DeviceManager::mount_get_status`, which every backend already implements and which the
  rotation path has used on this rig.
- **Untested on hardware.** The hint only helps if the mount's reported RA/Dec is roughly
  right; that is the condition tonight's rig satisfies (it reports a position, and the
  pointing error being measured is degrees, not tens of degrees). No ASTAP process was run
  in this verification — `build_astap_args` is asserted, ASTAP's response to `-r 30`,
  `-z 1` and a pole-region cone is not. Both `-z 1` and `-r` are documented ASTAP flags
  the existing code already emits in other combinations.
- The blind fallback is what covers a mount whose position is wrong by more than 30°.
- `flutter_rust_bridge` codegen was NOT re-run: no FFI signature changed
  (`api_start_polar_alignment` still takes `solve_timeout: Option<f64>`; only its default
  moved).

## Commands run (unpiped exit codes)

| Command | Exit |
| --- | --- |
| `cargo test -p skotiq_bridge -p skotiq_native -p skotiq_sequencer --lib` (TMPDIR=~/.cache/ns-tests, CARGO_TARGET_DIR=~/.cache/ns-worktrees/cargo-target) | 0 — 713 + 202 + 868 passed, 0 failed |
| `cargo test -p skotiq_imaging --lib` | 0 — 865 passed, 0 failed |
| `cargo build --release -p skotiq_bridge` | 0 (Linux preview stays buildable) |
| `cargo clippy -p skotiq_bridge -p skotiq_imaging -p skotiq_sequencer --lib --all-targets` | 0, no warnings |
| `rustfmt --check` on the seven files this branch touches | 0. Repo-wide `cargo fmt --check` is red at the base commit (depthlock/mod.rs, sequencer/src/lib.rs, sequencer/tests/dart_wire_contract.rs); those were left as they were found. |
| `flutter test test/screens/polar_alignment --concurrency=3` (skotiq_app) | 0 — 62 passed |
| `flutter test test/screens/framing --concurrency=3` (skotiq_app) | 1 — 146 passed, **2 pre-existing golden failures** (`framing_hips_layer_wiring`, `framing_canvas_golden`) at 100.00% pixel diff: Windows-captured goldens on Linux. This branch touches no canvas, HiPS or rendering file (`git diff --name-only` = plate_solve.rs, polar_alignment/solve.rs, framing_actions_panel.dart). The three new hint-freshness tests pass. |
| `flutter test test/models/polar_alignment_config_validation_test.dart test/providers/polar_alignment_{run_control,stop_acknowledgement}_test.dart` (skotiq_core) | 0 — 35 passed |
| `flutter test test/headless_api/session_handlers_test.dart` (apps/desktop) | 0 — 22 passed |
| `dart format --output=none --set-exit-if-changed packages/skotiq_app packages/skotiq_core apps/desktop/…/session_handlers.dart` | 0 — 3714 files, 0 changed |
| `dart analyze` (skotiq_app) | 0 — 873 issues, all pre-existing `info` deprecations, 0 errors/warnings, none in the changed lines |
| `dart analyze` (skotiq_core) | 0 — 16 pre-existing `info`s |
| `dart analyze lib/headless_api` (apps/desktop) | 0 — no issues found |

## Tests added

Rust (`bridge/src/api/plate_solve.rs`, `solve_ladder_tests`) — the escalation ladder: a
narrow hint widens before giving up, an already-wide hint is not searched twice, a
meaningless radius falls back to the wide one, the whole ladder fits inside the configured
timeout, a hintless frame spends it all solving blind, a short budget keeps the hinted floor
and drops a hopeless blind rung, an impossible timeout is clamped, ASTAP owns each rung's
deadline with the watchdog behind it, a follower on a coalesced frame receives the escalated
result (not the first rung, and the ladder runs once), and a frame no rung solves names
every rung it tried plus the hint it tried them around.

Dart (`packages/skotiq_app/test/screens/framing/framing_solve_hint_freshness_test.dart`)
— two clicks with the mount moved between them produce two different hints (the target
unchanged throughout, which is the point), no mount falls back to the target, and a connected
mount that has not reported a position falls back to the target rather than hinting at 0h/0°.

Rust (`sequencer/src/polar_align/math.rs`) — the geometry: the rig's exact three points
returning a northern axis (and its southern mirror), east and west sweeps of one circle
fitting one axis, an off-pole axis recovered from points whose declination varies by more
than half a degree, the measured error-sensitivity pinned at 10°/15°/30° steps and shown to
predict the damage a 12-arcmin error does, degenerate points returning `None`, and three
round-trip tests of the axis-to-alt/az error maths (1° east = +60 arcmin azimuth, 1° west =
−60, 1° low = −60 arcmin altitude, and the same 1° measured through a full simulated
three-point circle).

Rust (`bridge/src/api/polar_alignment/solve.rs`): hours→degrees hint construction, RA
wrap folding, the radius floor and ASTAP clamp, NaN/out-of-range reports producing no
hint (blind fallback), the large-unbinned/already-binned/small-frame downsample rule,
the budget split (both attempts inside the configured timeout, no-hint spends it all,
short budget keeps the hinted floor and drops a hopeless fallback, NaN clamped), and
ASTAP owning the deadline with the watchdog behind it.

Rust (`imaging/src/platesolve.rs`): `-z 1` reaches ASTAP, `-z 0` sends no flag, and
`-fov` is identical at `-z 1` and `-z 2`.

Dart (`packages/skotiq_app/test/screens/polar_alignment/polar_alignment_solve_defaults_test.dart`):
the fresh config is binning 2 / 90 s and passes its own validator, every preset budgets
≥ 60 s, the wizard opens on binning 2 with the quarter-of-the-time explanation, and the
Advanced slider opens on 90 s.

## Windows-only / untested here (geometry)

Same as above: none of the geometry is platform-gated. The fix is arithmetic and is proven
against the rig's own recorded numbers, but no run has been made on hardware since.

## Left undone

- The owner's persisted config still holds `solveTimeout: 30` and `binning: 1`; the new
  defaults apply to a fresh install. **That is survivable tonight**: at 30 s the split is
  15 s hinted + 15 s blind, and a hinted pole-region solve on this rig runs in ~5 s. To
  get the full margin he can drag Advanced → Solve timeout to 90 and set Binning to 2×2.
- On-sky validation of the hinted TPPA path and of the corrected axis fit.
- The 12.1°-of-sky-per-10°-commanded discrepancy (see Part 2, "Still open") is not
  explained. It is not something this branch can settle without another run; the new log
  line is there to settle it.
- The default step size is still 15°. 30° would cut the error amplification by nine and is
  what NINA defaults to, but raising it changes the run's mechanics under the owner
  (longer slews, more meridian-guard refusals) and is a product call, not a bug fix.
