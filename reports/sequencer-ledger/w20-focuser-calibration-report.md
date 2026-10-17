# w20-focuser-calibration — measuring the focuser's backlash

Branch `agent/w20-focuser-calibration`, based on `38bf2b25a6223124a2db535ce3b08826f3a7c90a`
(confirmed with `git rev-parse HEAD` before any edit).

## What this workstream had to answer

`38bf2b25a` fixed the donut-star defect by always running the final autofocus approach back to
the sweep's own start, because the app had never been able to measure a focuser's backlash and
`af_backlash_in` ships as 0. That is safe but blunt. The owner asked for the app to measure the
run-up its actual focuser needs, as a calibration the operator is offered at their first attempt
at focusing.

## The measurement

`backlash = (focus optimum approached from below) - (optimum approached from above)`.

It falls out of the dead-band model now written down at the top of
`native/skotiq_native/sequencer/src/focuser_calibration.rs`: optical position `a = c + d`
with `d` in `[0, b]`, driven to 0 by upward motion and to `b` by downward motion. With the slack
taken up downward the optics sit `b` steps high, so the same focus is commanded `b` steps lower.

Hardware truth used as fixtures throughout:

| date | position | backlash | notes |
|---|---|---|---|
| 2026-09-14 | ~6600 | 105 steps | 6620 from below, 6515 from above. Landing from above measured HFR 5.60; with a run-up, 2.94. |
| 2026-09-08 | ~2500 | 83 steps | Same focuser, different answer — backlash varies along the travel. |

Because it varies, every record carries the position and temperature it was taken at, and nothing
presents the figure as exact elsewhere.

## The modelling error the simulation caught

This is the most important finding of the workstream.

The first version reasoned about a single isolated approach — run `k` past the target and back —
and concluded the fits recover `b` when `k >= b` and `2k - b` when they do not, so a run-up
shorter than the backlash had to be refused, with `b >= 2k - measured` offered as the remedy.

Driving the routine against a simulated gear train of known width
(`instructions::tests::focuser_backlash`) showed that is wrong. The scan is **monotone**: each
run-up only reverses `k - step` before the scan drives `k` forward again, and the reversal
**accumulates** as `clearance + (n - 1) * step` by the nth point. A 40-step run-up over 13 points
at a 30-step spacing therefore still takes up 105 steps of dead band — the simulation measures it
as 102 at R² 0.995. The old rule would have refused a perfectly good measurement of the owner's
own focuser.

The guard is now on the reversal the scan actually accumulates, in two tiers:

- above the **full** budget `clearance + (points - 1) * step` → refuse; nothing in the scan could
  have taken up a dead band that wide;
- above the budget accumulated **by the middle of the scan**, where the points that set the vertex
  are → report at low confidence as possibly a floor rather than the value.

Two tiers because under-reporting cannot be detected from one run: it produces a *smaller* number
and nothing in the data says how much smaller. So the honest move is to bound the figure and ask
for a bigger run-up, not to pretend certainty.

The negative-result refusal changed meaning with the model. Takeup is confined to `[0, b]`, so the
from-below optimum can never sit below the from-above one. A meaningfully negative difference is
therefore not a short run-up at all — it says focus moved between the two passes, or the focuser is
not reaching the positions it is sent to. The fabricated `implied_minimum_backlash` is gone.

A dead band genuinely wider than the scan can take up is still caught, because the unconverged
pass shifts each point's optical position along with the scan and flattens the very curve the fit
needs. At 1200 steps the stars bloat past detection and the scan is abandoned for stars; narrower
cases trip the fit-quality or bracketing gates. None of them returns a number.

## What was built

### Native

- `native/skotiq_native/sequencer/src/focuser_calibration.rs` — the model, the arithmetic, the
  refusals, the resolution limit and the confidence grading. Pure and fully unit-tested.
- `native/skotiq_native/sequencer/src/instructions/focuser_calibration.rs` — the two scans.
  Reuses `calculate_hfr_with_crops`, the one-sided outlier rejection and the curve fitters
  autofocus uses, and takes the autofocus admission gate so the two can never drive the same
  camera at once. Returns the focuser to where the operator left it, whatever the outcome.
  A direction that cannot support a vertex is refused at the fit, before the second scan spends
  three more minutes of sky on an answer it cannot change.
- `native/skotiq_native/sequencer/src/instructions/autofocus.rs` — `final_run_up_position` now
  resolves a run-up with explicit precedence and reports which figure sized it (`RunUpSource`).
- `native/skotiq_native/sequencer/src/lib.rs` — `AutofocusConfig.measured_backlash_in`, and a
  single `From<AutofocusMethod>` crossing replacing a hand-inlined match.

### Bridge

- `api_run_focuser_backlash_calibration(device_id, camera_id, config_json) -> String`
- `api_plan_focuser_backlash_calibration(config_json, center_position) -> String`
- `api_cancel_focuser_backlash_calibration()`
- `AutofocusConfigApi.measured_backlash_in`
- `one_shot_focus_context(...)` — the ~90-line one-shot `InstructionContext` literal, previously
  inline in `api_run_autofocus`, now shared with the calibration so the two cannot drift.

JSON on both sides deliberately: the outcome carries both scans' full point sets, both vertices, a
confidence with its written grounds, and — when the scans cannot support a figure — a tagged
refusal with a remedy. That is not a shape a flat FFI struct can carry, and serde lets the evidence
grow without another codegen round. Progress rides the existing event bus as a focuser
`PropertyChanged` with property `FocuserBacklashCalibrationProgress`, so no new stream was needed.

A refusal returns `Ok`: the run happened and concluded that no figure is warranted. `Err` is
reserved for the run not happening.

## Refusal cases and how each is detected

| code | detected by |
|---|---|
| `scan_abandoned_for_stars` | more than half a scan's frames found fewer than `min_star_count` stars; the scan stops mid-way rather than finishing |
| `too_few_stars_at_focus` | the minimum-HFR point — the one the vertex rests on — is under the star floor |
| `too_few_measurable_points` | fewer than 5 points in a scan cleared the star floor |
| `not_enough_points` | fewer than 5 points survived outlier rejection to the fit |
| `poor_fit` | either direction's R² below the threshold (default 0.90, stricter than autofocus's, because autofocus verifies its landing with a frame and a stored backlash figure does not get a second look). `find_best_focus` is fail-soft and returns R² 0.0 on a failed fit, which this gate turns into a refusal rather than a guess |
| `vertex_outside_scan` | the fitted vertex lies outside the positions its own scan covered — an extrapolation, not a measurement |
| `exceeds_scan_range` | the two vertices are further apart than the narrower scan is wide, so they cannot both be on the same curve |
| `exceeds_reversal_budget` | the figure is wider than the scan ever reversed the drive train |
| `negative_beyond_resolution` | a difference negative by more than the scans' resolution, which backlash cannot produce |

"No measurable backlash" is **not** in that table. A difference inside the resolution limit —
half the coarser scan's median sample spacing, floored at one step — is a legitimate outcome
reported as "no backlash larger than N steps", with `steps` 0 and the evidence retained. It is
never clamped into a fake positive, and a small negative inside the limit is noise about zero
rather than a refusal.

## The precedence rule

In `final_run_up_position` / `resolve_run_up`, and tested as its own group:

1. **Operator-entered** `backlash_compensation` (`af_backlash_in`), when non-zero — wins outright.
   Somebody who has measured their own focuser, or who knows this drive train, must never have
   their number quietly replaced.
2. **Measured** `measured_backlash_in`, consulted only when the operator has left theirs at the
   shipped 0.
3. **Sweep start** — `38bf2b25a`'s fallback, unchanged, for a focuser that has never been
   calibrated.

With a figure in hand the run-up is that figure **plus a margin**, never equal to it: a quarter of
the figure, at least one sweep step, and at least 10 steps. An exact match leaves the gear on the
edge of the dead zone. A *measured zero* is a real result and not a figure to size a run-up from,
so it falls through to the sweep-start rule.

`measured_backlash_in` is ungated by `backlash_comp_method`, unlike `backlash_in`. That selector
governs the overshoot moves during the sweep; the measured figure only sizes the final run-up,
which happens either way because best focus has to be reached from the side it was measured from.
All it does is make that unavoidable move shorter and aimed at a known clearance.

## The Dart layers

- **Persistence**, `FocuserBacklashCalibrationRecord` in `settings_dao.dart` under
  `focuser_backlash_calibrations.v1`, keyed by focuser device id, mirroring `RememberedSensorSpec`
  (short keys, LRU cap 8, `FormatException` → nothing remembered, skip-write when unchanged). No
  Drift migration — `app_settings` is an existing key-value table.
- **Precedence**, `resolveEffectiveFocuserBacklash` — the single decision, wired into all three
  paths that reach native (sequencer JSON, one-shot FFI config, runtime push-down) so a
  trigger-fired refocus gets the same figure as an explicit node.
- **The offer**, `focuserBacklashOfferProvider` — connected camera and focuser, no record for that
  focuser, no typed figure, not opted out, not dismissed this session, and fail-closed while any of
  that is still loading. Re-offered after two consecutive landing-verification failures on the same
  focuser.
- **The wizard**, with intro / progress / measured / no-measurable-backlash / refused / failed
  surfaces, both curves on shared axes, and Save / Discard / Re-run.
- **Headless routes** for start, cancel and plan, relaying the native JSON verbatim so a remote
  client reads the same message and remedy.

The V-curve painter was promoted out of `autofocus_progress_overlay.dart` into `skotiq_ui`
rather than forked, per that file's own instruction, and now takes any number of series.

## Two honesty defects found reviewing the finished feature

Both of the class the owner cares about — the UI claiming something had been applied when it had
not — and both caught by tracing the value end to end rather than by reading the new code.

1. **The field edited a setting nothing reads.** `AppSettings` has two nearly identically named
   backlash settings. The one the equipment surfaces edit, `backlashCompensation` (DB key
   `backlash_compensation`), is persisted, remote-synced and displayed — and read by nothing
   operational. Every path to the focuser takes its figure from `afBacklashIn`. So the "Backlash
   compensation" field changed a number that changed nothing, and the new "Use the measured 105"
   button wrote to it: an operator could adopt a measurement, watch the field update, and have
   autofocus carry on seeing 0. Both surfaces now read and write `afBacklashIn`, with the legacy
   setting kept in step so nothing shows a contradictory number.
2. **The resolver ignored the compensation switch.** With `af_backlash_comp_method` set to "None",
   Dart already sends `backlash_compensation: 0`, so a typed figure never reaches the engine. The
   resolver reported it as in force anyway, while native was applying the measured figure instead —
   the reverse of the precedence the UI was promising. It now takes that switch and carries the
   switched-off number so the readout says so plainly.

`backlashCompensation` is left operationally orphaned rather than merely unread; migrating or
removing it is a separate change with its own remote-sync and settings-round-trip surface.

## Verification

Run from `native/skotiq_native` with `TMPDIR=$HOME/.cache/ns-tmp/w20-focuser-calibration`.

| command | exit |
|---|---|
| `cargo test -p skotiq_sequencer` | 0 — 914 + 4 + 1 + 6 + 4 + 12 passed, 0 failed |
| `cargo test -p skotiq_sequencer --lib focuser_` | 0 — 39 passed, 0 failed |
| `cargo clippy -p skotiq_sequencer --all-targets` | 0 — 0 warnings, 0 errors |
| `cargo clippy -p skotiq_bridge` | 0 — 0 warnings, 0 errors |
| `cargo build -p skotiq_bridge` | 0 |
| `flutter_rust_bridge_codegen generate` | 0 |
| `cargo fmt --all -- --check` | 1 — six pre-existing diffs in `imaging/src/depthlock/mod.rs`, untouched by this branch (`git diff --stat HEAD -- native/skotiq_native/imaging/` is empty). Every crate this branch touches is clean. |
| `cargo build --release -p skotiq_bridge` | 0 — all three new FFI symbols present in the `.so` |

Dart, run per package:

| command | exit |
|---|---|
| `dart format --output=none --set-exit-if-changed` over skotiq_core, skotiq_app, skotiq_ui, apps/desktop | 0 — 4236 files, 0 changed |
| `dart analyze packages/skotiq_core` | 0 — 19 infos, all pre-existing, none in a touched file |
| `dart analyze packages/skotiq_app` | 0 — 873 infos, all pre-existing, none in a touched file |
| `dart analyze packages/skotiq_ui` | 0 — 59 infos, all pre-existing, none in a touched file |
| `dart analyze apps/desktop` | 0 — 9 infos, all pre-existing, none in a touched file |
| `flutter test` (skotiq_core, full) | 0 — 6693 passed |
| `flutter test test/widgets test/screens/{equipment,imaging,dashboard}` (skotiq_app) | 0 — 1096 passed |
| `flutter test` (skotiq_ui, full) | 0 — 547 passed |
| `flutter test test/headless_api` (apps/desktop) | 0 — 1144 passed |
| `flutter test test/focuser_backlash` (skotiq_core) | 0 — 104 passed |

Pre-existing flake, not from this branch: `test/database/integrity_check_test.dart` "a hot rollback
journal is replayed" fails roughly one run in three under parallel load and passes in isolation. It
builds its own raw sqlite file and hand-written journal and never touches `app_settings` or anything
in this diff; a clean re-run of the same command passed 5254 tests. Two further flakes under
full-suite load are `tearDownAll` temp-directory cleanup races. Worth a separate ticket.

### Deviations from the brief

- The brief said a result "larger than the scan range" is a failure. Implemented as two separate
  refusals — wider than the scan span, and wider than the scan's reversal budget — because the
  simulation showed the second is the physically governing bound and the first alone would miss it.
- The brief's framing of the negative case ("a run-up shorter than half the real backlash") came
  from the same isolated-approach model this branch corrected; the refusal is kept but its meaning
  and remedy are now the ones the corrected model supports.
- The end-to-end simulation lives in-crate (`instructions/tests/focuser_backlash.rs`) rather than
  in `tests/`, because `FrameContext` is `pub(crate)` and `DeviceOps` therefore cannot be
  implemented from an integration test.
- Confidence grading was added beyond the brief's "a confidence the UI can show": a written
  `confidence_reason` in every case, because a bare band is not something an operator can act on.

## What only the real rig can confirm

Everything below is honest about the limit: the simulator implements the dead-band model, so it
proves the arithmetic, the scan mechanics, the refusals and the plumbing — it cannot prove the
model matches a particular focuser.

1. **That a real ZWO EAF measures ~105 steps near 6600 and ~83 near 2500 through this routine.**
   The owner measured those by hand over the API; the routine has never been pointed at the metal.
2. **That the default scan geometry brackets focus on his optics** — 13 points at 30 steps, ±180
   from rough focus. The depth assumption (HFR ~3 at focus, ~8 at ±180) comes from his sweep, but
   whether 13 points at that spacing gives a good fit on a real night is an on-sky question.
3. **The duration estimate.** 6 s of focuser motion per point and 1.5 s of frame overhead are
   stated as an estimate in the UI, but the real figure depends on his focuser's step rate and
   download time.
4. **That the default 400-step run-up is generous enough for his drive train** — the budget maths
   says 550 steps of reversal by the vertex, which is ~5x his 105, but only the rig can confirm
   the model's constant.
5. **That the measured figure actually improves the landing** — i.e. that autofocus with a
   calibrated run-up lands at HFR ~2.94 rather than ~5.60, repeatably. This is the outcome the
   whole workstream exists for and it cannot be verified anywhere but the sky.
6. **Whether backlash drifts with temperature** over a night enough to matter. The record stores
   the temperature so this becomes answerable, but nothing here establishes the relationship.
7. **The re-offer trigger** — that repeated verification-frame failures on the same focuser really
   do indicate an uncalibrated or changed drive train.

I did not touch the owner's imaging laptop (192.168.1.100) or its HTTP API at any point.
