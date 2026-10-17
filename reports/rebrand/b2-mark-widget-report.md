# b2-mark-widget — Skotiq "Trails" mark and motion

Built the approved "Trails" mark as reusable widgets in
`packages/skotiq_ui`, porting the geometry and motion from the brand
references rather than redesigning them. Everything lives under
`packages/skotiq_ui/lib/src/components/brand/`; the only existing file
touched is `lib/skotiq_ui.dart` (one export line) plus `pubspec.yaml`
(Sora font declaration).

## What was built

| File | Contents |
|---|---|
| `lib/src/components/brand/trails_geometry.dart` | `LANES`, `LEVELS`, `PALETTES`, `lane()` ported from `trails_reference.py`; `trailsLevelForSize` picks full/mid/flat at 64/24 px; `trailsLanePath` builds each lane as two `arcToPoint` arcs matching the reference's SVG `A` commands |
| `lib/src/components/brand/skotiq_mark.dart` | `SkotiqMark` (size, motion `none|draw|loading|working`, tone `violet|light|red|mono`, tile, semanticLabel, onDrawComplete) plus `TrailsMarkPainter` |
| `lib/src/components/brand/skotiq_spinner.dart` | `SkotiqSpinner` — `SkotiqMark(motion: loading, tone: mono)`, default size 16; size/color/semanticLabel API for a mechanical `CircularProgressIndicator` swap later; no determinate variant |
| `lib/src/components/brand/skotiq_wordmark.dart` | `SkotiqWordmark` ("skotiq", Sora w600, letterSpacing −0.04em) and `SkotiqLockup` (mark + wordmark, fontSize = 1.25×mark ≈ 1.1× cap height at Sora's 0.73em cap, gap = 0.2×mark) |
| `lib/src/components/brand/brand.dart` | Barrel so `skotiq_ui.dart` needs exactly one export line |
| `example/brand_preview.dart` | Standalone preview: every motion × tone × {256, 64, 32, 24, 16}, tile, spinner, lockup |
| `test/components/brand/skotiq_mark_test.dart` | 24 tests (see below); no golden PNGs |
| `assets/fonts/Sora-VF.ttf` + `Sora-OFL.txt` | Sora variable font + OFL license; declared in `pubspec.yaml` like HankenGrotesk/SplineSansMono |

## How the brief maps to the code

- **Geometry.** Exact port: same lane table, same level specs, same
  palettes, `arcToPoint` in place of SVG `A`. The `translate(50 50)
  scale(1.08) translate(-50 -50.5)` transform is applied on the canvas;
  the tile (ground `#0E0C16`, corner radius 22.5%) draws in viewBox space.
- **Draw.** Per-lane `extractPath(0, f·len)`; lanes staggered 90 ms,
  1176 ms each (the reference demo's 28% window of its 4.2 s loop),
  cubic-bezier(.22,.7,.2,1); pole scales 0→1.25→1 at 1092/1386/1596 ms.
- **Loading.** Base lanes at 16% opacity; a 0.24-length dash travels each
  lane linearly over 2.2 s; lane phase step is −250 ms at full, −500 ms at
  mid/flat (matching the reference's `sk-c2`/`sk-c4` classes).
- **Working.** Still mark + a white dash 0.1 long, stroke 1.6, ≤75%
  opacity, sweeping all lanes in sync over 2.6 s with
  cubic-bezier(.45,0,.25,1).
- **Moving dashes wrap**: `_drawDash` extracts `[start, start+length]`
  modulo path length, splitting at the wrap point.
- **Red night.** `tone: violet` resolves to `red` when
  `context.skotiqColors.isRedNight` — the same signal the theme uses, not
  brightness. The tile also swaps to `#000` under the red colorway.
- **Reduced motion.** `animationsDisabled(context)`
  (`MediaQuery.disableAnimationsOf`) collapses every motion to the still
  mark; no ticker runs. `onDrawComplete` still fires (post-frame) so the
  splash hand-off isn't swallowed.
- **Gating.** Looping motions wrap in `OnScreenAnimationGate`
  (`repeating: true`) with the `RepaintBoundary` outside the gate; callers
  never call `repeat()` themselves. The painter's `repaint:` listenable is
  the controller, so per-frame cost is a repaint only — no widget rebuilds,
  and the only per-frame allocations are the `extractPath` sub-paths the
  dash motions are defined by.
- **Spinner.** Mono loading at mid/flat by size; default 16 px.

## Decisions and deviations

- **Draw duration 1176 ms, not "about 1.2 s".** The reference HTML wraps
  the one-shot in a 4.2 s demo loop with keyframes at 0–28% — 1176 ms is
  the unwrapped value. Pole pop timings (26/33/38% = 1092/1386/1596 ms)
  come from the same unwrapping.
- **mid/flat lane tables.** Verified against the reference `LEVELS`
  dict: `mid` = `(7.0, −38, 132) (0, −46, 140) (−7.0, −60, 118)` with
  pick `[0,2,4]`; `flat` = `(4.6, −40, 134) (−4.6, −52, 124)` with pick
  `[1,4]` — ported verbatim.
- **Path-length tolerance in tests.** Flutter's `arcToPoint` approximates
  elliptical arcs with conics, so measured path length runs ~0.5–1% under
  the analytic SVG length. Endpoints and the waist are asserted to 1e-6
  against the reference; total length gets a 2% tolerance with a comment
  explaining why.
- **`mono` color resolution.** Explicit `color` wins, then `IconTheme`,
  then `DefaultTextStyle`, matching the "currentColor" behavior in the
  brief. A non-null `color` also mono-fies non-mono tones — documented on
  the parameter.
- **Sora weight.** The bundled `Sora-VF.ttf` is a variable font;
  `FontWeight.w600` selects SemiBold on its `wght` axis.
- **Sora not added to test font loaders** (`ensureFonts`-style helpers),
  per the brief — golden images elsewhere are untouched.
- **`pubspec.lock` regenerated** by `flutter pub get` — drops stale path
  overrides from the pre-rename lock. Incidental, kept since it's what
  the toolchain produces.

## Commands run (final state)

From `packages/skotiq_ui/`, with
`TMPDIR=$HOME/.cache/ns-tmp/b2-mark-widget`:

| Command | Exit | Result |
|---|---|---|
| `dart analyze` | 0 | 59 issues, all info-level `deprecated_member_use`/`prefer_const_*` lints — identical count to the base commit; zero issues in new files |
| `dart format --output=none --set-exit-if-changed` on `lib/src/components/brand/ test/components/brand/ example/ lib/skotiq_ui.dart` | 0 | 8 files, 0 changed |
| `dart format` on the whole package | 1 | 34 pre-existing files would reformat (rename fallout in widgets/tests r2 owns); **none are mine**, left untouched |
| `flutter test --concurrency=4` | 0 | **+571 all tests passed** — 547 baseline + 24 new brand tests |

Baseline (commit `0f14e3843`, after `flutter pub get`): analyze exit 0
with the same 59 info issues; tests exit 0, 547 passing. No new warnings,
no new test failures.

## Test coverage

- Lane endpoints equal the reference's `pt()` outputs to 1e-6; waist
  continuity holds; path length within 2% of analytic (conic
  approximation).
- Level selection at 16/24/63/64/256.
- Motion constants: 90 ms stagger, 1176 ms lanes, pole overshoot, loading
  phase steps, glint timing.
- Still frames at known controller times for draw/loading/working/tile —
  verified by rasterizing and asserting raw RGBA pixels.
- Reduced motion: no ticker; `onDrawComplete` still fires.
- Gate: controller stops when the mark leaves the screen, resumes on
  return; `CustomPaint` is not rebuilt on animation ticks.
- `onDrawComplete` fires exactly once.
- Violet→red under `SkotiqTheme.redNight` (pumping past the theme lerp),
  violet under `SkotiqTheme.dark`.
- Semantics label; spinner and lockup APIs.

## Not done / notes

- Wiring `SkotiqMark`/`SkotiqSpinner` into screens is explicitly a later
  pass (r2 owns call sites).
- The preview runs as a standalone target:
  `flutter run -t example/brand_preview.dart -d <device>` from
  `packages/skotiq_ui/`.
