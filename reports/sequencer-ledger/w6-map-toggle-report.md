# w6-map-toggle — the canvas bar's overview toggle does something in every density

Branch `agent/w6-map-toggle`, base `f1f739da1`.

## The owner's report, confirmed (not assumed)

In the release build, in Ledger — the shipped default density — the canvas bar's
"Show the map" action "does literally nothing".

Confirmed by reading the code AND by driving the base build:

- `sequence_toolbar.dart` toggled `minimapVisibleProvider`, a
  `StateProvider<bool>` declared in `sequence_minimap.dart`.
- The only consumer was the 80 px strip mounted at the bottom of
  `sequence_tree.dart`, and that block already refused to render in Ledger
  (`canvasDensity == SequencerDensity.ledger` → `SizedBox.shrink()`).
- Ledger draws the always-on 34 px gutter (`sequence_tree/gutter_map.dart`)
  instead, and the gutter never read the provider.

So in Ledger the control moved a boolean nothing on screen was watching — and
worse, it lied about it: after one press the glyph was `selected` and its
tooltip read "Hide the map" while no map had appeared or disappeared anywhere.

## Reproduced in the running app (base build, before the fix)

Bundle built in this worktree at `f1f739da1` (`flutter build linux --release`
then the bridge `.so` copied in — the flutter build wipes it every time).
Harness: `tools/ui_audit/drive_linux.py --profile w6map`, `NS_AUDIT_DISPLAY=:94`,
profile seeded from `/home/scdouglas/.cache/skotiq-ledger-preview/data`
(lock file removed). Navigated Sequencer → Saved → "NGC 7000 + M31 · full night"
→ Load, then switched to Ledger density and clicked the Map glyph in the canvas
bar.

Measured off raw 1920x1200 captures: the gutter as the run of saturated colour
columns at the tree's right edge, and the ledger rows' own right edge as the
right edge of the "ETA" column heading (the rightmost row ink, bounded left of
the gutter).

| base build (bug), Ledger | gutter x-range | gutter width | ETA column right edge |
| --- | --- | --- | --- |
| before the click | 1426–1459 | 34 px | 1382 |
| after the click  | 1426–1459 | 34 px | 1382 |

Pixel diff of the two captures over the gutter columns: `None` — byte-identical.
The only change anywhere on the canvas was the tooltip that had moved with the
pointer. Evidence: `/tmp/ns-audit/w6map/before-ledger-A.png`,
`before-ledger-B.png`, and `before-tooltip.png`, which shows the glyph lit
`selected` with the tooltip "Hide the map" over a canvas that has no map to hide
and a gutter that never left.

## Verified in the running app (this build, after the fix)

Same profile, same night, same canvas width, same measurements. (The shared
cargo-target `libskotiq_bridge.so` was rebuilt from another commit mid-run
and the app refused to start on the frb hash; the campaign-hash copy from
`ns-worktrees/seq-ledger` was used, per the coordinator's correction. The base
run above had the matching bridge already.)

| fixed build, Ledger | gutter x-range | gutter width | ETA column right edge |
| --- | --- | --- | --- |
| gutter on (default)  | 1426–1459 | 34 px | 1382 |
| after one click      | none      | 0 px  | 1416 |
| after a second click | 1426–1459 | 34 px | 1382 |

The ledger columns move right by exactly 1416 − 1382 = 34 px, the gutter's width
to the pixel, and back again. The tooltip reads "Show the overview gutter" with
the glyph unselected while it is off (`after-tooltip.png`) and the glyph is lit
with the gutter back after the second press (`after-ledger-C.png`).

Then, in Comfortable (`comfy-*.png`):

| fixed build, Comfortable | 80 px strip |
| --- | --- |
| before the click (tooltip "Show the map", glyph unselected) | absent |
| after the click | a saturated band at canvas y 939–1016, 78 of the strip's 80 px |

And the per-density memory, live: with Ledger left OFF and Comfortable left ON,
switching back to Ledger draws no gutter (0 saturated columns in 1426–1459) and
switching back to Comfortable still draws the strip at y 939–1016. The settings
row after the session reads exactly

    sequence_overview_visible_v1 | {"ledger":false,"comfortable":true}

— `compact`, never chosen in, is absent and still follows its default.

## The model, and why

**One preference per density, stored as a JSON object under
`sequence_overview_visible_v1`.** `SequenceOverviewPrefs` holds
`Map<SequencerDensity, bool>` of the densities the user has *actually chosen
in*; a density they have never touched is absent from the map and answers with
`defaultVisibleIn` (Ledger on, Comfortable and Compact off — today's defaults).

Alternatives weighed:

- *One shared bool with a density-dependent default.* Rejected: it cannot
  satisfy requirement 4. Hiding the gutter in Ledger and switching to
  Comfortable would arrive with the strip already hidden — which is also its
  default, so it reads fine — but coming back from a Comfortable session where
  the strip was ON would force the gutter on in Ledger, throwing away the choice
  the operator made there. The two shapes cost different things (the strip takes
  height from the rows, the gutter takes width from the ledger columns), so one
  number cannot stand for both trades.
- *An explicit tri-state (`on` / `off` / `default`).* Same problem: still one
  value for three densities.
- *One settings row per density.* Rejected: densities come and go with the spec
  and a key per mode leaves orphan rows behind; one JSON object is the shape
  `thumbnail_strip_prefs_v1` already uses for a multi-knob preference.

Storing only the deviations (rather than materialising all three defaults on
first write) means a later change to a default still reaches every user who
never disagreed with it.

## What changed

- **New** `packages/skotiq_app/lib/screens/sequencer/widgets/sequence_overview_prefs.dart`
  - `SequenceOverviewPrefs` (per-density map, JSON round-trip, tolerant of keys
    that name no density),
  - `sequenceOverviewPrefsProvider` — `AsyncNotifier` over `settingsDaoProvider`,
    modelled on `sequencerDensityPrefsProvider`,
  - `sequenceOverviewVisibleProvider` — the synchronous derived view, resolved
    against `canvasSequencerDensityProvider` so a canvas too narrow to host
    Ledger toggles the strip it is really drawing,
  - `sequenceOverviewToggleLabel` / `sequenceOverviewButtonLabel` — the shared
    wording, so the three toolbar tiers cannot drift apart.
- `sequence_minimap.dart` — `minimapVisibleProvider` (the `StateProvider`) is
  gone; the widget's doc now points at the provider that governs both shapes.
- `sequence_tree/gutter_map.dart` — new `_GutterMapSlot` wraps the gutter in a
  `TweenAnimationBuilder` width factor on
  `animationDuration(context, SkotiqTokens.durationSmooth)` with
  `SkotiqTokens.curveStandard` (no bounce; zero-length under
  `MediaQuery.disableAnimations` via the shared helper). `ClipRect` + a
  left-anchored `Align(widthFactor:)` rather than an animated `SizedBox`, so the
  painter is not re-laid-out and repainted on every frame of the close. At rest
  closed the gutter is not built at all — an invisible map has no business
  repainting on every scroll tick.
- `sequence_tree.dart` — the Row's gutter column and the strip below both read
  the same preference; the strip's `Consumer` is gone (the whole subtree already
  rebuilds on the preference).
- `sequence_toolbar.dart` — all three tiers (labelled buttons, glyph buttons,
  overflow menu) share one `overviewLabel`, one `showOverview` and one
  `toggleOverview()`; the glyph's `selected` and the labelled button's variant
  now track the visibility of whatever the current density actually draws. The
  labelled tier's button is named "Gutter" in Ledger and "Map" elsewhere, with
  the full phrasing carried as its `semanticsHint`.

### Decisions that deviate from the brief, and why

1. **The provider is renamed**, `minimapVisibleProvider` →
   `sequenceOverviewVisibleProvider`, and lives in its own file. It no longer
   governs only a minimap, and the brief's own requirement 1 ("one provider
   governs the overview in every density") is exactly what the old name denied.
   Three call sites and one test referenced it; all are updated.
2. **`sequence_tree.dart` reads `sequenceOverviewPrefsProvider` against its own
   locally resolved density** rather than the derived
   `sequenceOverviewVisibleProvider`. The derived provider reads
   `resolvedSequencerDensityProvider`, which the tree can only publish *after*
   the frame (`_syncCanvasDensity` is a post-frame write), so on the one frame a
   narrow canvas clamps Ledger to compact rows the derived value would still be
   Ledger's and would flash the strip on for that frame. The toolbar, which has
   no local answer, uses the derived provider — that is what it is for.
3. **The Ledger affordability test still subtracts the gutter's 34 px
   unconditionally** (`contentWidth - _gutterMapWidth < _ledgerColumnsMinWidth`),
   even when the gutter is hidden. Making it conditional oscillates: at a width
   between the two thresholds, hiding the gutter would make Ledger affordable,
   which restores Ledger's own "gutter on" answer, which makes it unaffordable
   again. Keeping it fixed also means the toggle never changes which density the
   canvas hosts — pressing "hide the gutter" must not reformat every row.

## Verification (unpiped, exit codes recorded)

| command | exit |
| --- | --- |
| `flutter test test/screens/sequencer --concurrency=3` (skotiq_app) | 0 — **729 passed** (721 on base + 8 new) |
| `cd packages/skotiq_app && dart analyze` | 2 — **890 issues, identical to the base count**; zero new |
| `dart format` on the seven touched files | clean (3 reformatted, then committed formatted) |

`dart analyze` exits 2 on the pre-existing 890 infos (deprecations across the
package); the count is unchanged from the base commit, which is the gate the
brief sets.

## Tests added

`packages/skotiq_app/test/screens/sequencer/sequence_toolbar_map_toggle_test.dart`
(8 cases), pumping the canvas bar over the tree it governs so the toggle is
tested as the contract it is:

- Ledger: the toggle hides the gutter, `selected` follows, the wording flips
  between "Hide/Show the overview gutter", and the rows' scroll viewport grows
  by exactly 34.0 px and shrinks back.
- Comfortable: the toggle shows the 80 px strip and says "Hide/Show the map".
- Per-density memory: Ledger off + Comfortable on, switch back and forth, and
  neither choice reaches the other; the stored row holds both.
- The labelled tier names the thing it toggles ("Gutter" + the hint).
- Wording helper, fresh-store defaults, persistence round-trip through a second
  container, and a stored key that names no density.

`sequence_gutter_map_test.dart` updated: its two strip cases now drive the real
notifier instead of overriding the deleted `StateProvider`.

## Left undone

Nothing in scope. The gutter's own behaviour (drag, tap, semantics) is
unchanged and still covered by `sequence_gutter_map_test.dart`.
