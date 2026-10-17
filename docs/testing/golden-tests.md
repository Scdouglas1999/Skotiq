# Golden / pixel-diff tests

> Owner: CI / build. Companion to `docs/ci-gates.md`.

Skotiq has two kinds of golden test. Only one of them is host-sensitive,
and the strategy below keeps CI trustworthy without throwing away the committed
baselines.

## Two kinds of "golden"

1. **Capture / review goldens** (`docs/design/goldens/`, written by
   `skotiq_ui/test/golden/golden_harness.dart` and
   `skotiq_app/test/golden/surface_golden_harness.dart`). These render a
   real surface and write a PNG for a human to eyeball. **They are NOT
   pixel-diff guards** — the test bodies assert only that a non-empty image was
   produced, so they pass on any host.

   Writing those tracked PNGs is **opt-in**. Both harnesses resolve their
   output directory through `goldensDir()` (and `screenshotsDir()` for the
   `assets/screenshots/` set), which points at the committed directory only
   when `SKOTIQ_CAPTURE_ASSETS=1` is set and at a throwaway temp directory
   otherwise. The render, rasterise, encode, write and assert steps run
   identically either way, so the tests keep proving a real non-empty image was
   produced while a plain `flutter test` leaves the working tree clean. Before
   this gate existed, running the suite rewrote 12 files under
   `assets/screenshots/` and every PNG under `docs/design/goldens/`, which made
   `git status` untrustworthy after a test run and repeatedly risked
   Linux-rendered screenshots being committed by accident.

2. **Pixel-diff / perceptual goldens** — these actually compare rendered pixels
   against a committed baseline and FAIL on a mismatch:
   - `matchesGoldenFile(...)` tests (framing/HiPS render locks, the phone
     `captures_landscape_test.dart` reflow captures, the HiPS fixture mosaic).
   - The planetarium benchmark perceptual gate
     (`skotiq_planetarium/test/benchmark/golden_compare_test.dart`), which
     fails if more than `kGoldenMaxChangedFraction` (0.2%) of pixels differ by
     more than `kGoldenChannelTolerance` (2/255).

   Host-sensitivity differs sharply between these two families. The
   difference has now been measured (2026-09-14, Linux/softpipe) rather than
   assumed:

   - **`matchesGoldenFile` baselines are host-insensitive in practice.**
     `hips_tile_mosaic.png` and `framing_hips_projection_registration.png` were
     captured in the same commit (`f038169f0`) as
     `framing_hips_layer_wiring.png`, and both still compare **byte-exact** on
     Linux today. These tests rasterise painters and themed widgets under the
     bundled test font, not the host's font stack, so there is no font hinting
     to differ.
   - **The planetarium perceptual gate is genuinely host-sensitive**: it
     rasterises through the GPU path, where the driver and rasteriser really do
     differ across operating systems.

   An earlier revision of this document asserted that all pixel-diff baselines
   were Windows-captured and could not match a Linux renderer. That claim is
   false for the `matchesGoldenFile` family, and believing it is what let two
   genuinely stale baselines sit red for three months (below).

   The planetarium baselines additionally predate their subject: they were
   frozen at `bd062b659` (before 6.0.0) and every intended render change since
   — DSO sizes, the catalog tiers, HYG depth, pointer-anchored zoom — is still
   uncaptured. Measured on Linux at `94f13cd6d` the five checkpoints report
   1.9–4.4% changed pixels against the 0.2% limit, so a large number there is
   the accumulated backlog plus host drift, NOT evidence of a regression. They
   owe a Windows re-capture; do not read the figure as a fresh break without
   one.

## Case study: the two framing baselines were stale, not host-broken

`framing_hips_layer_wiring.png` (reported as 100.00%, 480000px diff) and
`framing_canvas_registered.png` (75.45%, 772584px diff) failed on Linux for
three months and were written off as host drift. They were not:

- **Neither Linux render was blank or transparent.** Both produced full,
  correctly-composed frames - opaque throughout, with the dominant background
  occupying an identical pixel count to the baseline's.
- **The baselines encode a retired colour token.** Their page background is
  `#0A0C0F`; the Linux renders' is `#0B0D12`. `284a95fd9 feat(ui): the
  Observatory token set` (2026-09-09) retired `#0A0C0F` for `#0B0D12`, and
  `packages/skotiq_ui/test/dark_contrast_test.dart` documents that exact
  move. The baselines were last captured 2026-06-01 - three months earlier.
- **The headline percentage was misleading.** 98.3% of the
  `framing_hips_layer_wiring` diff was a sub-visual shift of <=3/255: the whole
  surface re-toned by one token, which `matchesGoldenFile` reports as "100% of
  pixels differ" because it counts any non-zero delta.

Both were re-captured on Linux and now pass. The lesson for the next large
diff: check whether the render is *blank* (a real paint bug) or merely
*re-toned* (a stale baseline) before blaming the host - the two look identical
in the percentage and have opposite fixes.

## The strategy

The pixel-diff tests are tagged **`golden`** (file-level `@Tags(['golden'])`
for whole-file golden suites; a per-test `tags: 'golden'` for the single golden
case inside a file that also holds non-golden geometry guards). The tag is
declared in each package's `dart_test.yaml`.

- **`melos run test`** (what CI's `test-dart` job runs on `ubuntu-latest`, and
  the default local command) passes `--exclude-tags golden`, so the
  host-specific pixel comparisons never run there. Everything else — including
  the non-golden geometry/wiring guards that happen to live in the same files —
  still runs and must pass.
- **`melos run test:golden`** runs ONLY the `golden`-tagged tests. Run this on
  the host the baselines were captured on (today: Windows) to actually exercise
  the pixel comparison.

This was chosen over the alternatives because:
- Mass-regenerating the *planetarium perceptual* baselines on Linux would make
  them pass on Linux but fail on the Windows release path and for any Windows
  contributor, so that suite still has no single "correct everywhere" host.
  (This reasoning was originally applied to the `matchesGoldenFile` suites too;
  the measurement above shows it does not hold for them.)
- A loose perceptual threshold large enough to absorb cross-host diffs would
  also absorb the real regressions these tests exist to catch (a dropped star,
  a de-registered FOV reticle).
- Tag-gating mirrors the existing `live-network` opt-in convention already in
  `packages/skotiq_core/dart_test.yaml`, so it is a known pattern in this
  repo.

## Re-baselining

When an intended visual change lands, regenerate the baselines **on the host
the project treats as canonical for goldens** (currently Windows), then commit
the updated PNGs:

```sh
# matchesGoldenFile baselines (per package):
flutter test --update-goldens --tags golden

# planetarium perceptual baselines:
BENCHMARK_GOLDEN_MODE=capture flutter test --tags golden \
  test/benchmark/golden_compare_test.dart
```

Canonical host, per family:

- **`matchesGoldenFile` suites — Linux.** All four baselines are Linux-valid as
  a set: two were already byte-exact on Linux, and the two stale framing
  baselines were re-captured there on 2026-09-14. Because this family is
  host-insensitive (measured above), a Linux re-capture is expected to remain
  green on Windows; if a Windows `melos run test:golden` ever shows otherwise,
  record the measured delta here rather than re-capturing blind.
- **Planetarium perceptual gate — Windows,** unchanged, and still owing the
  re-capture described above.

## Regenerating the capture / review assets

The `docs/design/goldens/` boards and the public `assets/screenshots/` set are
written only when explicitly asked for:

```sh
# the design-language boards (docs/design/goldens/)
SKOTIQ_CAPTURE_ASSETS=1 flutter test test/golden/ # in skotiq_ui / skotiq_app

# the 12 public screenshots (assets/screenshots/)
SKOTIQ_CAPTURE_ASSETS=1 flutter test test/golden/public_screenshots_test.dart
```

Both are rendered by the running app's real screens, so capture them on the
host whose renderer the published images should show, and review the diff
before committing - an accidental Linux re-capture of Windows marketing
screenshots is exactly what the gate exists to prevent.
