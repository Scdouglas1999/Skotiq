# D-fix batch: imaging-guiding-polar-2

Source of truth for the items: `reports/release-pass/waveD-result.json` (still_broken
evidence + new_findings repros) and `reports/release-pass/gui/waveD-imaging-spine.md`.
Ladder: reproduce at HEAD first (failing test), then fix, then green. Where a claim
turned out to be partly wrong, that is recorded rather than papered over.

The live session log the audit produced (`/tmp/ns-audit/waveD-imaging-spine/app.log`)
was re-read directly; several verdicts below rest on it.

---

## ND-1 — P1 — Live Stacking counters freeze while frames are consumed

**What the log actually shows.** 179 `Adding frame to stack:` lines and **179**
`Frame rejected: alignment residual 37.11px exceeds max 2.00px` warnings — the engine
refused **every** frame it was handed. So the stack really did contain one frame (the
reference), and `Stacked Frames 1` was true; the Stop dialog was not under-reporting.

**The real defect, same shape, worse.** `Stacker::add_frame`
(`native/skotiq_native/imaging/src/stacking.rs`) increments
`total_frames_attempted` and `rejected_alignment_failures` **before** returning its
error. The Dart side threw that error away (`catch (e) { log warning }`), so the panel
kept the statistics of the last ACCEPTED frame: `Total Attempted 1 · Rejected
(Alignment) 0` while the engine had attempted 180 and rejected 179. The single number
that would have told the operator their match settings were rejecting everything was
the number that never moved.

Fix:
* `LiveStackingService` re-labels a refusal as `LiveStackingFrameRejected`, carrying
  the engine's tally read back immediately after the refusal (best effort: if the
  read-back also fails the original error propagates unchanged).
* `LiveStackingNotifier._publishRejectionStats` publishes that tally for both the
  local and the remote (host-polled) paths.

Ladder: `packages/skotiq_core/test/services/live_stacking_rejection_stats_test.dart`
— with the publish disabled the counter test fails `Expected: <180> Actual: <1>`,
which is the live symptom exactly.

## IMG-4 / ND-2 — the annotate chip, and the annotate solve path

Two of IMG-4's three pieces of evidence do not survive re-reading:
* "no `.wcs` on disk" — since the SCI-48 fix each attempt runs in
  `/tmp/skotiq-solve-<pid>-N/`, so the sidecar is no longer written beside the
  operator's frame. The verifier's own report notes that change.
* "no outcome line in the log" — `app.log` carries only the Rust tracing stream; the
  solve outcome is logged Dart-side. It was, however, genuinely absent for the
  annotate path, because that path never went through the service that logs it (below).

What remained is real: a green success chip reading `Found 0 objects` beside a viewport
that said `Sky --`.

Fixes:
1. **Field size** (`annotation_pipeline.dart`). The catalog search radius is derived
   from `PlateSolveData.fieldWidth/Height`. The local ASTAP/astrometry parsers recover
   position and scale only and leave the field at **zero**, so a solve with a perfectly
   good centre searched a cone of radius 0 and came back empty — "Found 0 objects" as a
   statement about the operator's sky. The field is now reconstructed from the solved
   scale and the frame's own pixel dimensions, and a solve with neither is reported as
   a failed solve.
2. **The chip** (`annotation_panel_parts/status_widgets.dart`). A completed run that
   matched nothing no longer wears the green tick: it takes the neutral treatment and
   says `No catalog objects in this frame` with a hint naming both possible causes.
3. **ND-2 — one solve path** (`annotation_pipeline.dart`). Annotate called
   `backend.plateSolve` directly: the only solve in the app that skipped
   `PlateSolveService`, and therefore skipped the operator's configured search radius,
   solver-choice validation, the ASTAP→astrometry fallback, the single-flight gate, and
   the one log line that records a solve's outcome. (The live log shows the consequence:
   two ASTAP processes launched 45 ms apart over the same frame.) It now uses
   `solveWithFallback`, like centering, framing and the polar wizard's Dart callers.

Ladder: `annotation_solve_geometry_test.dart` gains a scale-but-no-field case, and the
fixture object was moved 0.01° OFF the solved centre first — an object exactly on the
centre is inside even a zero-radius cone, so the old fixture could not tell a real
field from a field of zero size. With the derivation disabled the new test fails with
`objectsFound: 0`. `annotation_service_test.dart` was updated for the shared path (the
mock backends now answer the solver probe; the "late solve" test now expects ONE
backend solve because the gate refuses the overlap — its actual invariant is unchanged).

## IMG-14 — field-scale hint (PARTIAL, native half BLOCKED)

Dart half done: `PlateSolverConfig.fieldHeightDegrees` → `-fov` in the local ASTAP
argument builder (`PlateSolveService.astapArguments`, now a tested seam).
`_solveWithFallbackInternal` reads the hint itself from the equipment profile
(`OpticalConfig.fieldOfView.height`, the same number onboarding computed), so EVERY
caller of that entry — annotate, centering, framing, the polar wizard's Dart callers —
hints identically and no caller can forget. Nothing is guessed when the profile has no
focal length or pixel size.

(First attempt added a `fieldHeightDegrees` parameter to `solveWithFallback`; that
broke two test doubles including a generated `.mocks.dart`, which this batch may not
regenerate. Reading the profile inside the service is both smaller and better: the
hint cannot go missing at one call site.)

**BLOCKED (native).** The path that runs in production is Rust, and it drops the hint
on purpose: `native/skotiq_native/imaging/src/platesolve.rs:832` —
"hint_scale: ASTAP expects -fov in degrees (field of view), not arcsec/pixel. We don't
have sensor pixel size here, so skip it." The image height IS available (the solver has
the FITS path), so the fix is `-fov = hint_scale × NAXIS2 ÷ 3600` there. It needs no FRB
change — `hint_scale` is already threaded to `AstapSolver::solve` — but it is Rust, it
is outside this batch's scope, and verifying it needs a rebuild this batch was told not
to do. The polar wizard already computes and logs the number
(`Polar alignment solve scale hint: … 1.29"/px unbinned`) and then loses it at that line.

## IMG-13 — the slew headline was off by one

`_runActivityLabel` built the headline from `state.currentPoint`, which is the point
that has been MEASURED; during the move it still reads the point behind, while the
published status names the destination ("Slewing to point 2..."). `_effectiveRunPoint`
takes the number out of the status when it names one, and the progress list uses the
same resolution so the two cannot disagree.

## IMG-16 — the bullseye denied a measurement that was on screen

`hasMeasurement` gated on `phase == adjusting`, so a COMPLETED run — the moment the
operator most wants to see where they ended up — snapped the marker back to dead centre
and captioned itself "No measurement yet" beside `Azimuth 3.2" · Altitude 0.6" · Total
3.2"`. The gate is now the measurement itself (`error != null`, any phase but idle),
and the caption's condition matches it.

## ND-3 — "Alignment Complete" beside a red "Worse"

Both errors render to a tenth of an arcsecond, and the run was being graded off a
hundredth: Before 3.19" → After 3.22" earned a red **Worse** under a green headline.
`polarAlignmentImprovementSign` now treats anything below the displayed resolution
(`kPolarImprovementResolutionArcsec = 0.1`) as no change. A real regression still reads
Worse (pinned by its own test).

## IMG-10 — Pause on the built-in guider

Re-checked against the code: with the built-in guider the screen passes no pause
handler and a reason, so `onPressed == null`, the button IS disabled and its semantics
node publishes `button + hasEnabledState + !isEnabled`. The Wave D tree read is
explained by the neighbour: during guiding `Loop Exposures` is disabled too, so the two
buttons legitimately look identical.

What was genuinely broken is the part the verdict named: **the click was silent.** A
hover tooltip is no explanation to the operator who clicks, and none at all on touch.
Pressing an unavailable control now raises a dismissible inline notice carrying the
reason, and the tooltip no longer publishes a second, state-less semantics node over
the button's own (`excludeFromSemantics`, the reason is already in the label).

## IMG-9 residual — Auto Select was silent

`onFindStar` handed the notifier's Future straight to the panel, which only surfaces
THROWN failures, so a successful selection produced nothing: no message, no log line,
and on an already-locked frame nothing on screen moved either. `_autoSelectStar` logs
the attempt, logs and reports the star it locked (with coordinates), and reports the
"no star found" outcome explicitly. (The Frame Count label half of IMG-9 remains an
owner-decision item per the Wave D adjudication.)

## ND-6 — the master save silently swapped .fits → .png

`saveMaster` normalised any extension to `.png`, so typing `stack_master.fits` produced
`stack_master.png` — the operator asked for a FITS master (header, WCS, integration
metadata) and got a picture, undisclosed. It now refuses a non-PNG extension with
`LiveStackingMasterFormatUnsupported`, BEFORE reading anything out of the stacker, and
the panel renders that as its own dialog ("Live-stack masters are saved as PNG") while
keeping the stack running. The chooser's type label and the Stop prompt now name the
format up front.

## ND-4 — the narrow capture bar

The geometry claim does **not** reproduce: at 900 dp with a seven-filter wheel and the
stats readout, every control (gain chip, `SII`, `Stretch`) is laid out inside the bar
and reachable — the bar has scrolled horizontally since the threshold fork was removed.
What was missing is the **affordance**: it scrolled silently, so a screenshot reads as
"cut off with nothing to do about it" (the same complaint IMG-19 raised about the flat
wizard's row, which was given a scrollbar). The bar now draws one.

## ND-5 — bottom-bar semantics

Confirmed at HEAD by test: `Snapshot` reached assistive tech as a panel, not a button.
Fixed locally in the banner (role + enabled state published per action, and the gain
chip published as the button it is) rather than in the shared `SmallButton`, so this
bar's contract is pinned by its own test. The filter chips' selected state was already
correct — that half of ND-5 no longer reproduces.

**Not done here:** the same shape on the Guide Graph's two dropdowns
(`panel: Time: 5m [DISABLED]`, `panel: Scale: ±2" [DISABLED]`). They live in
`packages/skotiq_ui/lib/src/widgets/phd2/guide_graph_advanced.dart` — the shared
design-system package, outside this batch's scope and the natural property of whoever
owns the a11y/design-system batch.

---

## Verification

* `skotiq_core`: `test/services` + `test/providers` — **4373 passed, 4 skipped, 0
  failed**.
* `skotiq_app`: `test/screens/{imaging,guiding,polar_alignment}` + `test/widgets/phd2`,
  `--exclude-tags golden` — 323 + 23 green. The two `captures_landscape_test.dart`
  golden failures are host-specific baselines, `@Tags(['golden'])`, excluded by
  `melos run test`, and fail at HEAD on this machine too.
* `skotiq_app` FULL suite, `--exclude-tags golden` — **3378 passed, 4 failed**. All
  four failures are in `screens/onboarding` and `screens/settings`
  (`device_picker_backend_failure`, `filter_wheel_slot_cap` ×2,
  `remote_access_pairing_phrase`), whose production files
  (`onboarding/steps/device_picker_step.dart`, `onboarding/steps/filter_wheel_step.dart`,
  `settings/widgets/remote_access_settings/lan_pairing_panel.dart`) are being edited
  right now by the concurrent onboarding/settings batch. Nothing in this batch touches
  them.
* `dart format` clean on every file touched (two app files and five core files were
  reformatted after editing).
* `dart analyze` clean on every file touched.
