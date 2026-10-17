# D-fix batch: sky-planetarium-2

Source of items: `reports/release-pass/waveD-result.json` (`still_broken`:
SKY-4 / SKY-10 / SKY-16; `new_findings`: D-1..D-4) and the cluster narrative
`reports/release-pass/gui/waveD-sky-discovery.md`.

Scope honoured: `packages/skotiq_planetarium/**`,
`packages/skotiq_app/lib/screens/{planetarium,your_sky}/**` plus the owning
packages' test dirs. No GUI harness was launched and no bundle was rebuilt (per
the batch charter), so every claim below is pinned by a test that was **proved
failing at HEAD behaviour** before the fix, by reverting the one line under test
and re-running.

---

## SKY-4 (P2) — "Create region" clickable with no target, silently no-ops — FIXED

Wave B called this a false positive at HEAD ("`_canSubmit` gates `onPressed`");
Wave D re-drove it on the fresh 18:31 bundle and it still reproduced. Both are
partly right, and that is the whole finding:

- The gate **is** at HEAD — `_canSubmit` is `_source != target || _selectedTarget
  != null`, so with an empty library `onPressed` is null and the button renders
  dim. Confirmed by reading the widget and by the existing
  `name_region_sheet_validation_test.dart`.
- And it **did not reach the user**. The live AT-SPI tree reported
  `button: Create region` with **no `[DISABLED]`**, and clicking produced no
  error, no toast and no new node. Both signals a screen reader or an automated
  driver gets said "actionable"; the only signal that said otherwise was a
  colour.

I could not settle *why* the disabled flag does not survive to AT-SPI without
the GUI harness (`SkotiqButton` does set `Semantics(enabled: !isDisabled)`,
and the harness prints `[DISABLED]` correctly for other node classes). So the
fix does not depend on the answer: in the one state where the mode can never
succeed — `From a target` with a loaded, empty library — the sheet no longer
offers that action at all. The slot carries the escape hatch its own empty-state
copy already names, `Switch to Custom RA/Dec`, and that control is live. With
targets present but none picked, the button stays gated and now carries a
`Semantics(hint:)` saying what is missing, because dimming carries no reason.

The prior contract test asserted the opposite ("enabling it only to explain
afterwards is the original bug") and was updated with the live evidence as the
reason. Running it against my change is what proved HEAD rendered a
`Create region` button in that state.

Files: `screens/your_sky/widgets/name_region_sheet.dart`.
Tests: new `test/screens/your_sky/name_region_sheet_dead_action_test.dart`
(3 cases, encodes the refuter's exact drive: empty library, `From a target`,
press the primary action, look for a visible consequence);
`name_region_sheet_validation_test.dart` updated. Whole `test/screens/your_sky/`
green (46).

## SKY-10 (P3) — wheel zoom ignores the pointer — FIXED

Measured live twice: 23 notches took the field 60.0° → 2.0° with
`Center RA: 0h 42m 44s / Center Dec: +41° 16'` byte-identical.

Root cause: `Listener.onPointerSignal` threw the pointer position away and called
`_zoomByStep`, which only ever changed the FOV.

Fix: the wheel now takes an anchor. `_zoomByStep(focalPoint:)` unprojects the
cursor to a sky coordinate through the SAME `SkyFovProjector` the painter and the
hit-tester use, and `_onZoomAnimation` re-pins that coordinate under that screen
point **at the FOV each frame actually landed on** — so the sky under the cursor
is stationary throughout the 300 ms glide, not just at its end. The re-centre is
solved by iteration (shifting the image by `err` px means re-centring on the sky
that currently lies `err` from the centre) rather than by inverting the
projection, which keeps it correct in all three projections and in the alt/az
frame. The anchor is dropped on pan start, on fly-to and on the double-tap reset,
each of which owns the centre deliberately.

Files: `widgets/interactive_sky_view.dart`,
`widgets/interactive_sky_view/view_motion.dart`,
`widgets/interactive_sky_view/hit_testing.dart`.
Test: `test/wheel_zoom_anchor_test.dart` (3 cases). Proved failing at HEAD by
dropping `focalPoint` from the Listener: the anchor landed **562 px** from the
cursor and the centre moved by exactly 0.0.

## SKY-16 (P4) — desktop UI says "tap" — FIXED

The coordinate-mode tooltip read `Equatorial view — tap for Alt/Az` on a build
driven with a mouse. Rewritten to name the action, not a gesture
(`… — switch to Alt/Az`), which is also the only wording that is true for a
screen-reader user driving the bar from the keyboard. The same wording bug in the
legacy `view_controls.dart` toggle was fixed with it.

Files: `screens/planetarium/widgets/redesign/command_bar.dart`,
`screens/planetarium/widgets/view_controls.dart`.
Test: `test/screens/planetarium/command_bar_pointer_verb_test.dart` — no
command-bar tooltip may name a touch gesture. Proved failing at HEAD by restoring
the old string.

## D-1 (P3) — status bar shows a simulated LST beside a real clock — FIXED

`localSiderealTimeProvider` was keyed on `observationTimeProvider`, the
planetarium's *preview* clock. The shell status bar and the dashboard header both
render it, so scrubbing the planetarium six hours forward rewrote a number an
imager plans by, 15 px from a live wall clock, with nothing marking the
difference. Worse: a held observation clock stops publishing, so the wrong value
then froze (the live table shows `LST 21:14` and `21:24` against a true 15:14 /
15:22).

Fix, entirely inside the planetarium package so no out-of-scope file had to
change:

- new `wallClockProvider` — a real 1 s clock the transport cannot move;
- `localSiderealTimeProvider` now reads it (the shell and dashboard therefore get
  the truth with no edit at their end);
- new `observationSiderealTimeProvider` for readouts that *should* follow the
  scrub, wired into the planetarium's own two top overlays.

Files: `providers/planetarium_providers/observer_time.dart`,
`providers/planetarium_providers/catalog_astronomy.dart`,
`screens/planetarium/widgets/top_overlay.dart`,
`screens/planetarium/widgets/mobile_widgets/top_overlay.dart`.
Test: `test/sidereal_time_scope_test.dart` (3 cases). Proved failing at HEAD by
re-pointing the provider at the observation clock: 2 of 3 failed, off by
**14.98 sidereal hours**.

## D-2 (P3) — planetarium tooltips never leave the a11y tree — BLOCKED (out of scope)

Every string Wave D listed (`Search the sky`, `Reset view (zenith, FOV 60)`,
`Equatorial view — …`, `Layers`) is produced by `SkotiqTooltip`, and the
planetarium call sites pass nothing but a message and a position — there is
nothing wrong on this side to fix. The lifecycle lives in
`packages/skotiq_ui/lib/src/components/skotiq_tooltip.dart`:
`_hideTooltip()` (~line 134) hangs the actual `_overlayController.hide()` off
`_animController.reverse().then(...)`, and a `TickerFuture` that is interrupted by
a later `forward()` **never completes** — so a tooltip re-shown during its own
fade-out keeps its `OverlayPortal` mounted for good, with the bubble's `Text` (and
therefore its semantics node) still in the tree. Nothing is painted because
`_TooltipOverlay` returns `SizedBox.shrink()` once its target render box is gone,
which is exactly the reported signature: clean screenshot, stale nodes.

Same owner as the SKY-8 half that Wave B recorded blocked. No code changed.

## D-3 (P3) — transport buttons have no accessible names — FIXED

`IconButton(tooltip:)` does not name anything: Flutter's `Tooltip` publishes its
message as `SemanticsProperties.tooltip`, a field distinct from the label. A
semantics dump of `TimeControlPanel` at HEAD confirmed it exactly — five nodes
with `btn=true tap=true label=""`, no toggled state anywhere, and the date chip a
bare `InkWell` with no button role and no enabled state (which is why the live
tree called it `[DISABLED]`).

Fix: an `_accessibleControl` helper puts a real `Semantics(label:)` — and, for
play/pause, a `toggled:` state — on each control and merges the subtree, the same
idiom the Layers rows use (the one Wave D verified reaches AT-SPI). The date chip
became a real `Semantics(button: true, enabled: true, hint: 'Choose a date')`.
After the fix the same dump reads `Slower / Back 1 hour / Pause / Forward 1 hour
/ Faster`, with `toggled=true/false` on play/pause.

Files: `widgets/time_control_panel.dart`.
Test: `test/time_transport_semantics_test.dart` (3 cases) asserts the property an
assistive client actually consumes: ONE node carrying the name, the button role
and the tap action together. Observed failing at HEAD with `label=''`.

## D-4 (P4) — Layers drawer covers the transport at 900 px — FIXED

The bottom chrome was laid out across the FULL stack (`right: 0`) while the
drawer floated over its right edge, so at 900 px the clock rendered `18:46:` with
the seconds behind the panel and the fast-forward button took no clicks.

Fix: the shell computes a `dockedWidth` (the docked panel's width, 0 when none is
open) and insets the time transport, the bottom info bar, the minimap and the
catalog-fallback banner by it — which is what makes "docked" true, i.e. the panel
takes space instead of covering controls. The transport slot was extracted as
`PlanetariumTransportSlot` so the geometry is testable without pumping the whole
screen (which fans out to ~30 providers and a GPU renderer).

Files: `screens/planetarium/widgets/redesign/planetarium_shell.dart`.
Test: `test/screens/planetarium/transport_docked_panel_overlap_test.dart`. Proved
failing at HEAD behaviour (`dockedWidth: 0`): transport right edge **652.75** vs
the drawer's left edge at 620.

---

## Gates run

- `packages/skotiq_planetarium`: `flutter test test/ --exclude-tags golden` →
  **558 passing**. `flutter analyze lib test` → 6 infos, all `hasFlag`
  deprecations, the same idiom five existing app tests already use.
- `packages/skotiq_app`: `flutter test test/screens/planetarium
  test/screens/your_sky` → **204 passing**. `flutter analyze` on the four touched
  dirs → clean apart from 4 pre-existing `clampPanelWidth` deprecation infos in
  `planetarium_screen/layouts.dart`.
- `test/screens/shell test/screens/dashboard --exclude-tags golden` → 284
  passing, to cover the `localSiderealTimeProvider` consumers I changed the
  meaning of.

### Failures seen that are NOT this batch's

- `test/screens/dashboard/captures_landscape_test.dart` — 4 golden pixel diffs of
  ~41%. `@Tags(['golden'])`, host-specific baselines, excluded from
  `melos run test`; a clock digit cannot move 96 000 px.
- `test/screens/dashboard/edit_dashboard_refusal_test.dart` — an **untracked**
  test file from a concurrent D-fix batch, failing against its own in-flight edit
  to `dashboard_header_actions.dart`. It passed in my first run of that directory
  and failed in the next, with no change of mine in between.
- Mid-session, `skotiq_core`'s `SchedulerEngine` briefly did not compile
  (`ownsRun` / `_ownsDispatchedRun` undefined) — another batch's SEQ-12 work
  landing. It cleared on its own.

## Formatting note

`dart format` was run only on the three planetarium files whose new code it
touched (that package is format-clean, so the diff is my additions only). The
`skotiq_app` package is **not** `dart format`-clean at HEAD — formatting
`planetarium_shell.dart` straight from `git show HEAD` rewrites it — so its edits
were hand-matched to the surrounding style rather than formatted, per the
no-repo-wide-formatter rule.
