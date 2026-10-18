# F1 — Configurable focuser backlash calibration

**Branch state:** worktree on `879a4133b477adc546d8ceefc70562fde2efa961` (verified
with `git rev-parse HEAD`).

**Reported problem:** "Backlash measurement appears to have no configurable
settings." True — Dart sent only `center_position` and `app_version`, so every
run silently used the Rust `BacklashCalibrationConfig` defaults tuned for a
different focuser.

## What was built

### Settings model (skotiq_core)

`FocuserBacklashCalibrationSettings` in
`packages/skotiq_core/lib/src/models/focuser_backlash_calibration.dart` —
the 16 operator-tunable fields of the native config (`step_size`,
`steps_out`, `clearance_steps`, `exposure_duration`, `exposures_per_point`,
`binning`, `gain`, `offset`, `min_star_count`, `r_squared_threshold`,
`outer_crop_ratio`, `inner_crop_ratio`, `use_brightest_n_stars`,
`focuser_settle_time_ms`, `method`, `outlier_rejection_sigma`,
`max_duration_secs`).

- `seededFromAutofocus(AutofocusSettings, {activeFilter})` seeds every field
  from the autofocus settings the operator already tuned — including the
  active filter's per-filter overrides exactly where autofocus itself applies
  them (exposure, binning, gain, offset; same precedence as
  `autofocus_controls.dart`). Where autofocus has no equivalent:
  - `steps_out` takes the AF sweep's `initialOffsetSteps` (clamped to 3–50);
  - `clearance_steps` (run-up) is derived as `3 × stepSize`, which satisfies
    the validator's run-up-must-exceed-step-size rule and leaves a reversal
    budget of `2 × step × points` — several times the worst backlash measured
    on the owner's rig;
  - `method` stays `Quadratic` deliberately: the calibration scan is narrow
    and either-side-of-focus, which is a parabola's job — the AF screen's
    curve-fitting option answers a different question and is a different
    enum, so it is not mapped across;
  - `min_star_count` 10, `outlier_rejection_sigma` 3.0,
    `max_duration_secs` 1200 — native's shared autofocus defaults.
- `toJson()` emits the exact snake_case keys the Rust struct deserializes;
  `binning` maps to the `Binning` variant names (`"One"`–`"Four"`) and
  throws `ArgumentError` on an unmappable value rather than silently sending
  `"One"`.
- `tryParse`/`resolve`: a parseable-but-invalid stored blob is kept so the
  dialog can show the offending values with their problems named; a corrupt
  or missing blob falls back to the autofocus seed.
- `problems` mirrors `validate_backlash_calibration_config` rule-for-rule,
  in the same order, in native's own wording.
- `copyWith` uses a `_unset` sentinel so nullable gain/offset can be cleared.

`focuserBacklashCalibrationConfigJson` now spreads `settings.toJson()` under
`center_position`/`app_version`. Plan and run build the identical string.

### Persistence

One JSON blob under DB key `focuser_backlash_calibration_settings`, on the
existing `app_settings` row plumbing — `AppSettingsState`, `copyWith`, stored
snapshot, partial persistence, remote mapping (remotable, matching the
repo's remote-parity convention), `default_settings.dart`, and the freezed
remote `AppSettings` wire model (regenerated). Empty string = "no choices
stored" = seed from autofocus.

Setters on the autofocus settings section:
- `setFocuserBacklashCalibrationJson(value)` — raw write; `''` is how
  reset works.
- `updateFocuserBacklashCalibrationSettings(update, fallback:)` —
  read-modify-write serialized behind a dedicated write tail
  (`_focuserBacklashCalibrationWriteTail`), because several field editors
  can commit over one in-flight write and each commit rebuilds the whole
  blob.

### Provider / service

- `focuserBacklashCalibrationSettingsProvider` (in
  `focuser_backlash_provider.dart`) resolves the stored blob against
  `autofocusSettingsProvider` and the connected filter wheel's current
  filter.
- `_planFocuserBacklashCalibration` and `_calibrateFocuserBacklash` in
  `device_service/focuser_backlash_calibration.dart` both pull from
  `_admissibleFocuserBacklashCalibrationSettings()`, which refuses with the
  shared problem list before the backend is ever asked — so an invalid
  combination cannot start, and the plan states the travel/time of the
  settings that will actually run.
- `FocuserBacklashCalibrationNotifier` listens to the settings provider:
  while idle with a plan or an error on screen, a settings change re-reads
  the plan; a failed re-plan drops the stale plan (`clearPlan`) rather than
  leave travel figures for settings no longer in force. Mid-run changes do
  not re-plan.

### Dialog (skotiq_app)

`focuser_backlash_calibration_dialog.dart` gains a `_CalibrationSettingsSection`
on the intro surface: a two-column grid of `FormRow`/`SettingsNumberInput`
cells (step size, points a side, run-up, exposure, frames/point, binning
dropdown, gain, offset — blank gain/offset = "camera default", matching the
AF convention), an "Advanced" disclosure (min stars, R² floor, crops,
brightest-N, settle, outlier σ, max run time), a warning banner naming every
violation, and a "Reset to autofocus settings" ghost button. "Measure
backlash" is gated on `settings.isValid` in addition to the plan; the intro
also surfaces a plan that could not be worked out (e.g. invalid settings) as
a warning banner where the plan would have been quoted.

## Tests

- `calibration_settings_test.dart` (new): seeding incl. per-filter
  precedence and clamping, JSON roundtrip, backward-compat for a missing
  `method`, corrupt/mistyped-blob fallback, invalid-blob retention, and one
  unit test per native validation rule.
- `calibration_parsing_test.dart`: the config group now pins the full
  19-key wire map and enum spellings instead of the old two-key payload.
- `run_notifier_test.dart`: backend records the plan's config; new group
  asserts plan/run send byte-identical JSON, persisted tuning reaches the
  wire, idle edits re-plan, mid-run edits don't, invalid settings never
  reach the backend, and a failed re-plan clears the stale plan.
- `focuser_backlash_calibration_dialog_test.dart`: `_openHarness` exposes
  the harness handle; new group covers seeded display, the disclosure,
  persist-as-wire-map, invalid-gating, re-plan on edit, reset, and the
  binning enum name.
- Rust: three contract tests in `focuser_calibration.rs` deserialize the
  exact JSON Dart emits (typical config, null gain/offset/center, and an
  out-of-rules config) and run it through the real validator.

## Verification (all from the worktree, `TMPDIR=$HOME/.cache/ns-tmp/f1-backlash`)

| Command | Result |
|---|---|
| `melos bootstrap` | exit 0 (previous session) |
| `dart run build_runner build --delete-conflicting-outputs` (skotiq_core) | exit 0, ~38s, 2209 outputs |
| `melos run analyze` | SUCCESS, exit 0 — 914 info-level lints, no errors/warnings (repo's existing posture; none in touched files) |
| `dart format --set-exit-if-changed packages/skotiq_core packages/skotiq_app` | exit 0, 0 changed |
| `flutter test test/focuser_backlash/ --concurrency=4` (core) | 138 passed, 0 failed |
| `flutter test test/providers/ test/models/ --concurrency=4` (core) | 2639 passed, 0 failed |
| `flutter test test/database/ test/services/ --concurrency=4` (core) | 3585 passed, 4 skipped (pre-existing), 0 failed |
| `flutter test test/widgets/focuser_backlash/ test/screens/settings/ --concurrency=4` (app) | 651 passed, 0 failed |
| `CARGO_TARGET_DIR=$HOME/.cache/ns-tmp/f1-backlash/target cargo test -j 8 -p skotiq_sequencer focuser_calibration` | 36 passed, 0 failed |

## Notes / deliberate choices

- `packages/skotiq_core/test/services/profile_device_resolution_test.dart`
  was committed unformatted at this HEAD; `dart format` normalized it
  (formatting-only change, included so the touched packages format clean).
- The blob is remote-synced (`focuserBacklashCalibrationJson` on the
  wire model), matching the repo's explicit remote-parity convention for
  unattended-night settings.
- `method` is carried in the blob and on the wire but not offered in the
  dialog — `Quadratic` is the right model for this scan and the AF screen's
  curve-fitting enum is a different type answering a different question.
- Nothing left undone. No golden tests touch this dialog.
