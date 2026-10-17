# Stage-2 sweep — batch `stacking`

Items: SCI-27 (black stacked preview), SCI-28 (Stop destroys the stack),
SCI-47 (frame counts and pixel counts in one unitless list).

All three reproduced at HEAD before any edit. No item was a false positive.

## SCI-27 — stacked preview rendered black

**Reproduced at HEAD.** Temporary unit test against the then-current
`stackedPreviewGrayRgba` (synthetic 1000 ± 50 ADU sky with saturated stars, the
histogram of every real stacked light):

```
Expected: a value greater than or equal to <24>
  Actual: <0>          // median output byte
```

Root cause was as located: the preview computed its own LINEAR min/max stretch
(`stackedPreviewGrayRgba` / `stackedPreviewColorRgba`,
`screens/imaging/widgets/stacking_panel/stacked_preview.dart`). With a saturated
star as the max and the sky floor as the min, every background pixel and every
faint star maps to 0–3 of 255.

**Fix.** Deleted both local stretch functions and routed the preview through the
app's shared auto-stretch — the MAD-based PixInsight STF in Rust
(`imaging/src/stretch.rs`, via `apiAutoStretchImage` /
`apiAutoStretchColorImage`), which is the same curve the viewer and
Stack-and-Share render with. It is reached through a new
`LiveStackingService.autoStretchPreview({width, height, data, channels})` and a
`stackedPreviewStretchProvider` injection point.

Deliberately NOT reimplemented in Dart: the Rust STF's own docstring states that
display paths delegate to it "rather than being reimplemented in Dart, so the
curve is computed in exactly one place", and a second copy is the
two-implementations trap.

Consequence for verification: the stretch math itself is Rust-tested and cannot
be exercised from a Dart widget test (no test in this repo loads the native
library). The permanent Dart test therefore pins what Dart owns — that the
preview asks the shared stretch for the right channel layout and displays
exactly the bytes it returns (read back out of the rendered `ui.Image`). The
"is it black" half of the proof is the reproduction quoted above plus the Rust
STF tests. **Wave D should look at the Stack panel preview on a live stack.**

## SCI-28 — Stop destroyed the stack, nothing on disk

**Reproduced at HEAD**: tapping Stop with `stackedFrameCount: 32` called
`LiveStackingNotifier.stop()` immediately (`stopCalls == 1`, no prompt), which
releases the native accumulator.

**Fix** (`stacking_panel.dart` + `live_stacking_service.dart`):

- Stop on a session with frames in it now opens a **Keep this stack?** dialog:
  *Save master* / *Discard* / *Cancel*. Stop with zero frames is unchanged.
- *Save master* asks for a destination
  (`stackingMasterDestinationPickerProvider`, suggested
  `live_stack_<UTC>Z_<N>frames.png`) and calls the new
  `LiveStackingService.saveMaster`, which reads `getCurrentResult()` FIRST and
  writes it, then the panel releases the stacker. Order is asserted in the test
  (`['save', 'stop']`).
- A cancelled picker or a failed write leaves the stack **running** — the
  operator never loses the integration to a mis-click or a bad path.
- Format: mono stacks are written as the linear 16-bit PNG (`apiSavePngFile`) —
  the integration verbatim, re-stretchable elsewhere. OSC stacks are written as
  the auto-stretched RGBA PNG (`apiSaveRgbaPngFile`) because every 16-bit writer
  in the pipeline is single-plane; a colour master through the mono FITS path
  would be a scrambled plane. FITS was rejected for this path because its writer
  requires an `EXPTIME`/`DATE-OBS` header the live stacker cannot supply
  truthfully — fabricating one is the defect class this pass exists to remove.

Reset Stack is left as-is: it is the deliberate discard, and it is now the only
control that discards without a prompt, which is what the finding asked for
("Stop is indistinguishable from Reset Stack").

## SCI-47 — frames vs pixels in one list

**Reproduced at HEAD**: no row carried a unit except Avg Alignment Residual.

**Fix**: the Statistics list is now split by unit with a rule + caption
(`_StatGroupHeader`): **FRAMES** (Stacked Frames / Total Attempted / Rejected
(Alignment) → `N frames`; Avg Matched Pairs → `42.5 stars`; Avg Alignment
Residual → `0.37 px`) and **PIXELS REJECTED BY SIGMA CLIPPING** (Sigma-Rejected
Total / Last Frame → `7.3M px`, `271.8K px`; Rejection Rate unchanged). Empty
states still render `—` with no unit.

## Files

- `packages/skotiq_core/lib/src/services/live_stacking_service.dart`
  (+`autoStretchPreview`, +`saveMaster`, +`LiveStackingMasterSave/Format`)
- `packages/skotiq_app/lib/screens/imaging/widgets/stacking_panel.dart`
- `packages/skotiq_app/lib/screens/imaging/widgets/stacking_panel/stacked_preview.dart`
- `packages/skotiq_app/lib/screens/imaging/widgets/stacking_panel/status_widgets.dart`
- tests: `stacking_panel_preview_stretch_test.dart` (new),
  `stacking_panel_stop_and_units_test.dart` (new),
  `stacking_panel_osc_test.dart` (dropped the now-deleted linear-map group),
  `imaging_panels_no_measurement_test.dart` (`42.5` → `42.5 stars`)

## Test status

- `flutter test test/screens/imaging` in `skotiq_app`: all green except
  `imaging_landscape_capture_test.dart` (3 golden captures, 21–22% whole-screen
  pixel diff on all three device sizes). That file is `@Tags(['golden'])` and is
  excluded from `melos run test`; the baselines are host-specific (Windows-captured)
  and it renders the Capture tab, not the Stack panel — pre-existing, not this batch.
- `skotiq_core`: `live_stacking_service_config_test`,
  `stacking_engine_seam_test`, `stack_and_share_service_test` — 36 green.
- `dart format` run on the touched files only; `flutter analyze` clean on them.
