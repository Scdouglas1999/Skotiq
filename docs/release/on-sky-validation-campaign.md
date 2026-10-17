# On-sky validation campaign — v4 release

A structured, night-by-night plan to validate the subsystems whose
correctness can only be proven under real sky: Night Doctor thresholds,
drizzle `pixfrac`, deconvolution regularization, the predictive autofocus
model, meridian flip, and weather-gate behavior. Each night specifies what
to fly, what evidence to capture, and what "pass" means.

Run nights in order where possible — later nights assume the earlier
subsystems are trustworthy (you can't validate weather-gate recovery if
autofocus is still suspect). Cloudy-night fallbacks are listed at the end.

## Evidence capture — the tooling that already exists

Every claim in this campaign must be backed by one of these artifacts, not
by memory of "it looked fine":

1. **Decision log** (primary forensic record). The native executor emits a
   `DecisionEvent` for every scheduler pick, trigger firing, recovery
   transition, budget milestone, adaptive swap, frame accept/reject
   verdict, plugin invocation, manual action, and system event
   (`native/skotiq_native/sequencer/src/decision.rs`). Events are
   bridged as `SequencerEvent::DecisionLogged` and persisted to the
   `sequence_decisions` Drift table — they survive restarts and are the
   source of truth. Filter by the wire-stable categories:
   `scheduler_pick`, `trigger_fired`, `recovery_entered`, `budget_met`,
   `adaptive_swap`, `frame_accepted`, `frame_rejected`,
   `plugin_node_invoked`, `manual_intervention`, `system_event`.
2. **Mobile session replay** (how you review a night from the couch).
   `apps/mobile/lib/screens/replay/session_picker_screen.dart` lists past
   runs; `session_replay_screen.dart` renders one run as a scrub-able
   timeline (event ticks colored by severity, a diamond per captured
   frame, snapshot panel showing target/filter/HFR/frame counts at the
   playhead). It reads over the network backend
   (`NetworkSessionReplayDataSource`), so a headless/Pi run is reviewable
   without touching the rig.
3. **Night Doctor report**
   (`packages/skotiq_core/lib/src/services/night_analysis_service.dart`
   → `NightReport`/`NightFinding`, surfaced in the session-review screen's
   night report panel). Night 1 validates this tool itself; later nights
   use it as a cross-check.
4. **Headless journal**: `journalctl -u skotiq-headless` (trigger
   logs, disk watchdog, push delivery) — export per night.
5. **The frames** — keep ALL raw frames from validation nights, including
   rejected ones; the reject verdicts in the decision log are only
   auditable against the actual FITS.

Per-night routine: after shutdown, export the decision log for the run,
screenshot/screen-record the replay timeline at each incident, save the
Night Doctor report, and file frames under
`validation/<date>-<night-N>/`. Record ambient conditions (seeing
estimate, moon phase, transparency) in a one-line header note — every
threshold below is condition-sensitive and the notes are what makes a
later re-tune defensible.

---

## Night 1 — Night Doctor threshold calibration (deliberately bad data)

**Goal:** the report flags real problems and stays quiet on a clean run.
The detectors in `night_analysis_service.dart` are statistical and need a
per-rig sanity pass:

* HFR regression: robust threshold `baseline − 3σ`, with a relative
  fallback when σ degenerates;
* guiding excursions: `rmsThreshold = baseRms + 3·(MAD·1.4826)` AND
  eccentricity above `max(baseEcc + 0.12, 0.55)` (both must trip);
* tilt / collimation: warn + critical levels from `OpticalHealthScore`
  (`tiltWarnThreshold` / `tiltCriticalThreshold`, collimation
  equivalents).

**Procedure:** one healthy target sequence (60–90 min) as control. Then
inject known faults, one at a time, ~20 min each: (a) defocus by ~2×
critical focus and let frames accumulate; (b) sandbag the guiding (drop
aggressiveness or bump exposure) to force elongation; (c) if a tilt shim
or loose-clamp test is safe on your rig, induce mild tilt; (d) end with a
dew/cloud segment if nature cooperates.

**Pass:** every injected fault produces a `NightFinding` of at least
warning severity attributing roughly the right time range; the control
segment produces zero serious findings. **Fail handling:** record which
detector missed/over-fired with the measured values from the report —
the constants above are the tuning surface, and changes belong in a
follow-up commit referencing this night's data.

## Night 2 — Autofocus + predictive focus model

**Goal:** validate the temperature model the sequencer trusts mid-run.
`PersistedFocusModel` (`native/skotiq_native/sequencer/src/focus_prediction.rs`)
is keyed `(equipment_profile_id, filter_name)`, accumulates up to 50
samples, fits slope/intercept/R², and `evaluate()` returns a
confidence-gated `PredictiveAfDecision`: apply / dampen / force a real
sweep. Drift detection (`record_prediction_outcome` →
`DriftStatus::ShouldWarn`) must fire when predictions go stale.

**Procedure:** start with an empty model for one filter. Run AF sweeps
every ~30 min across the night's temperature drop (aim for ≥5 °C span),
letting samples accumulate. Watch the model card
(`packages/skotiq_app/lib/widgets/focus_model_curve_card.dart`) for
the fitted curve + R². Mid-night, alternate: let one AF cycle be replaced
by the prediction, then verify with a sweep — the delta between predicted
and swept position is the headline number. Repeat on a second filter to
validate per-filter offsets.

**Capture:** decision log (AF triggers appear as `trigger_fired`, frame
HFR verdicts as `frame_accepted`/`frame_rejected`), model card
screenshots over time, the predicted-vs-swept deltas.

**Pass:** R² ≥ ~0.9 once ≥8 samples span ≥3 °C; predicted positions
within your critical-focus zone of the swept truth; the engine *dampens
or refuses* predictions while the model is data-poor (early night) rather
than confidently extrapolating. HFR across the night, plotted from the
replay snapshot panel, shows no sawtooth of slow defocus between AF runs.

## Night 3 — Meridian flip (the scary one)

**Goal:** unattended flip correctness end-to-end: pre-flip pause, flip,
re-acquire (plate solve + re-center), guider re-calibration/resume, pier
side handling, and the post-flip epoch transform (the v4 audit added the
standalone flip + epoch transform paths — both need sky time).

**Procedure:** pick a target crossing the meridian mid-session. Fly the
full sequence through the flip with hands off but eyes on (first time:
finger over the stop button). Capture the entire window in the decision
log — the flip shows up as `system_event`/`trigger_fired` entries from
the meridian machinery (`native/skotiq_native/sequencer/src/meridian.rs`,
`meridian_events.rs`). Then validate the *standalone* flip path (flip
commanded outside a sequence) on a second target. If the rig allows,
repeat once near the safety limits (late flip) to confirm the
tracking-past-limit guards.

**Pass:** no pier crash risk at any point; first post-flip subframe is
plate-solve-centered within tolerance; guiding resumes without manual
help; image orientation/epoch handling correct (compare pre/post-flip
solves); total flip overhead within the configured window. The replay
timeline should read as a clean, monotonic story — any
`recovery_entered` during the flip is a finding even if the night
survived.

## Night 4 — Weather gate + recovery

**Goal:** the `WeatherUnsafe` trigger
(`native/skotiq_native/sequencer/src/triggers.rs`) aborts/parks on
EITHER unsafe source — the hardware safety monitor or the Dart-side
weather verdict fed in via `ExecutorCommand::UpdateWeatherVerdict` — and
re-fires every poll while conditions stay unsafe; plus the structural
no-daylight gate (W1) refuses to image past dawn.

**Procedure:** (a) simulate first: with the rig parked safe, toggle the
safety monitor input (cover the rain sensor / drive the simulated weather
source unsafe) and verify the trigger fires within one poll period;
(b) on-sky, run a real sequence and force an unsafe verdict mid-frame —
confirm abort, park, and the `push_notification` reaching the phone over
LAN *and* cellular (ties into cellular-push-setup.md); (c) return the
verdict to safe and validate the resume/recovery behavior
(`recovery_entered` → Recovered in the decision log, not GaveUp);
(d) let a sequence run into astronomical dawn to watch the daylight gate
end it structurally rather than by trigger.

**Pass:** abort latency ≤ one poll cycle from unsafe signal; the rig is
in its configured safe state (parked/closed) before precipitation could
matter; phone push arrives while the phone is on cellular; recovery
resumes the right node; the dawn stop happens at the computed time. Any
path where BOTH unsafe sources had to agree before action is a release
blocker — either alone must suffice (that's the documented contract in
triggers.rs).

## Night 5 — Data product A: drizzle `pixfrac`

**Goal:** pick defensible defaults for
`drizzleScale` / `drizzlePixfrac`
(`packages/skotiq_core/lib/src/models/imaging/integration_settings.dart`;
shipped defaults `2.0` / `0.9`) for the post-session integration pipeline.

**Procedure:** needs a well-dithered set — confirm dither is enabled and
visible as per-frame offsets first (Night 2/3 data is reusable if dither
was on). Acquire ≥40 dithered subs of a star-rich field. Integrate the
same stack at `pixfrac` 1.0, 0.9, 0.7, 0.5 (at scale 2.0), and once at
scale 1.0/pixfrac 1.0 as the no-drizzle control.

**Measure:** star FWHM, aliasing/moiré on undersampled stars, background
noise per pixel, and coverage-map holes (low pixfrac + thin dither =
holes). The Night Doctor / quality metrics give FWHM; pixel-peep the
rest.

**Pass:** chosen default shows resolution gain over the control with no
visible holes or SNR collapse at your typical sub count. Expectation to
confirm, not assume: 0.9 is safe at modest dither counts; 0.7 only pays
off ≥50 well-dithered subs. Document the recommendation per
sampling-regime (undersampled vs well-sampled) in the integration docs.

## Night 6 — Data product B: deconvolution regularization

**Goal:** validate the TV-regularized Richardson–Lucy default
(`regularization` λ, default `0.01`, bounded iterations — see
`native/skotiq_native/imaging/src/deconvolution.rs`) on real stacks,
not synthetic PSFs.

**Procedure:** use the Night 5 master (and one narrowband or
poor-seeing stack if available — the failure modes differ). Run the
deconvolution at λ ∈ {0, 0.005, 0.01, 0.02, 0.05} with the default
iteration cap, then once with λ=0.01 at 2× iterations.

**Measure:** ringing around bright stars (the classic RL failure),
worm/plastic texture in nebulosity (over-regularization), FWHM
improvement, and noise amplification in background patches.

**Pass:** the default λ shows no visible ringing on the brightest
unsaturated stars and no plateau-flattening of faint structure;
iteration doubling at default λ must not diverge (TV damping is doing
its job). If the sweet spot lands away from 0.01 on both test stacks,
that's a default change with this night as the citation.

## Night 7 — Full unattended dress rehearsal

**Goal:** everything above, composed, with nobody touching anything:
headless appliance (ideally the Pi image), scheduler-picked targets, AF
on the validated model, a meridian flip, dawn shutdown, Night Doctor in
the morning — operated only from the phone.

**Pass:** zero `manual_intervention` entries in the decision log between
sequence start and dawn shutdown; morning Night Doctor report contains
no surprise findings; the replay timeline plus decision log fully
explain every non-obvious choice the rig made (every `scheduler_pick`
and `trigger_fired` has a defensible rationale in its details payload).
Anything the operator could not reconstruct from couch tooling alone is
a documentation or telemetry bug — file it even if the night succeeded.

---

## Cloudy-night fallbacks

* Nights 5 and 6 are reprocessing nights — they only need previously
  captured dithered data.
* Night 4 sub-tests (a) and the daylight-gate check run fine under
  clouds; weather-gate *abort* validation arguably prefers bad weather.
* Decision-log/replay plumbing (does every category render in the mobile
  replay timeline?) can be exercised any time with a short dark-frame
  sequence.

## Exit criteria for the campaign

All seven nights passed, every threshold/default change made along the
way has a commit referencing its night's evidence directory, and the
dress rehearsal ran clean twice (two different nights — one lucky night
proves little). At that point the defaults shipped in 4.0 are defended
by data, not vibes.
