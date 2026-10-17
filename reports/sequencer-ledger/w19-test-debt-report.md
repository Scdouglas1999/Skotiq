# W19 — test debt: two failing goldens + two tests that rewrote tracked assets

Branch `agent/w19-test-debt`, base `7bc3391318a1eadc7e05aa0a68f8083dc8bf4c8a` (confirmed by
`git rev-parse HEAD` before any work).

## Part 1 — diagnosis: the baselines were STALE, not blank and not host-broken

The brief asked which of two diagnoses applied: a Linux surface that fails to paint (a real bug),
or a legitimate platform baseline difference. The answer turned out to be neither. Evidence, in the
order it was gathered:

### 1. The Linux renders are not blank or transparent

Ran both tests, then analysed the `failures/` artefacts Flutter writes (`masterImage` = committed
baseline, `testImage` = what Linux actually rendered):

| image | size | opaque px | distinct colours | dominant colour count |
|---|---|---|---|---|
| `framing_hips_layer_wiring` master | 800x600 | 480000/480000 | 52 | `(10,12,15)` x 471700 |
| `framing_hips_layer_wiring` test | 800x600 | 480000/480000 | 46 | `(11,13,18)` x **471700** |
| `framing_canvas_registered` master | 1280x800 | 1024000/1024000 | 928 | `(24,37,48)` x 311303 |
| `framing_canvas_registered` test | 1280x800 | 1024000/1024000 | 1116 | `(25,40,52)` x 306528 |

Zero transparent pixels in any image, and the dominant-background pixel count is *identical*
(471700) between master and test for the HiPS wiring golden. A blank/unpainted surface was ruled
out numerically, then visually — a crop of the highest-delta region showed both images rendering
the same panels, chrome and text boxes.

### 2. The "100%" figure was an artefact of counting any non-zero delta

`framing_hips_layer_wiring`: 100.00% of pixels differ, but mean per-channel delta 1.89, and
**98.3% of pixels differ by <=3/255** — i.e. the entire surface re-toned very slightly.
`matchesGoldenFile` reports that as "100% of pixels differ".

### 3. The re-tone is a retired design token

The baseline background is `(10,12,15)` = `#0A0C0F`. The Linux render is `(11,13,18)` = `#0B0D12`,
which is *exactly* the current value of `SkotiqColors.background` in
`packages/skotiq_ui/lib/src/theme/skotiq_colors.dart:123`.

`git log -L` on that line shows `284a95fd9 feat(ui): the Observatory token set` (2026-09-09)
changed `#0A0C0F` -> `#0B0D12`. `packages/skotiq_ui/test/dark_contrast_test.dart:9` documents
the same move in prose. The two baselines were last captured 2026-06-01 (`fa48512fa` /
`0e18b9058`) — three months *before* the token change, and `284a95fd9` is an ancestor of HEAD.

**So the Linux render is correct against current code; the committed PNGs encode a colour the
codebase no longer contains.**

### 4. This golden class is host-INsensitive — measured, not assumed

The decisive control: `hips_tile_mosaic.png` and `framing_hips_projection_registration.png` were
committed in the **same commit** (`f038169f0`) as the failing `framing_hips_layer_wiring.png` —
same capture session, same host — and both still compare **byte-exact on Linux today**:

```
flutter test test/screens/framing/painters/hips_tile_layer_golden_test.dart --tags golden  -> All tests passed!
flutter test test/models/framing_hips_projection_render_test.dart --tags golden            -> All tests passed!
```

If these baselines were Windows-captured and Linux could not reproduce them, those two would fail
too. They do not. `matchesGoldenFile` tests here rasterise painters and themed widgets under the
bundled test font (not the host font stack), so there is no hinting to differ.

That also explains *why* the two failures survived three months: `docs/testing/golden-tests.md`
asserted that all pixel-diff baselines were Windows-captured and could not match Linux, so anyone
who saw the failure attributed it to host drift and moved on. That claim was false for this family.

### What I changed for Part 1

- Re-captured the two stale baselines on Linux
  (`flutter test ... --tags golden --update-goldens`). Both now pass. The regenerated
  `framing_canvas_registered.png` was visually inspected: rotated FOV reticle at 20 degrees,
  crosshair, survey background, controls panel — a complete, correct render.
- Left the existing per-test `tags: 'golden'` on both in place. **Both tests already carried it**
  (`framing_registration_test.dart:329` and `framing_hips_layer_wiring_test.dart:329`), which is
  why they are already excluded from `melos run test` on both hosts; they only ran in my
  reproduction because a bare `flutter test` applies no tag filter.
- Rewrote the wrong parts of `docs/testing/golden-tests.md`: replaced the blanket
  host-sensitivity claim with the measurement above, split canonical-host guidance per family
  (`matchesGoldenFile` = Linux and now valid as a set; planetarium perceptual gate = Windows and
  still owing its re-capture), and added a case study so the next large diff gets checked for
  "re-toned" before being blamed on the host.

**No assertion was weakened.** Both goldens remain full-strength `matchesGoldenFile` pixel
comparisons against a current baseline.

## Part 2 — capture is now opt-in

The brief named 2 tests / 18 files. The actual blast radius was larger: 9 app golden suites plus
the design gallery all write through the two harnesses, so the gate went into the **harnesses**,
not the two named tests.

- `packages/skotiq_ui/test/golden/golden_harness.dart` and
  `packages/skotiq_app/test/golden/surface_golden_harness.dart` gained
  `captureEnvVar` / `capturesToRepo`, and `goldensDir()` now resolves to the committed
  `docs/design/goldens/` **only** under `SKOTIQ_CAPTURE_ASSETS=1`, otherwise a per-run temp dir.
- `SurfaceGoldenHarness.screenshotsDir()` added and used by `public_screenshots_test.dart` for the
  `assets/screenshots/` set, gated identically.
- Every assertion is unchanged (`existsSync`, `lengthSync() > 16KB`, `takeException() == null`) and
  the full render -> rasterise -> encode -> write -> assert path still runs in both modes. The only
  difference is the destination directory, so nothing that was being checked stopped being checked.

This mirrors the repo's existing `SKOTIQ_LIVE_NETWORK=1` opt-in convention in
`packages/skotiq_core/dart_test.yaml`.

### How to regenerate the assets now

```sh
# design-language boards -> docs/design/goldens/
SKOTIQ_CAPTURE_ASSETS=1 flutter test test/golden/   # in skotiq_ui and/or skotiq_app

# the 12 public screenshots -> assets/screenshots/
SKOTIQ_CAPTURE_ASSETS=1 flutter test test/golden/public_screenshots_test.dart

# matchesGoldenFile pixel baselines (unchanged mechanism)
flutter test --update-goldens --tags golden
```

Round-trip proof: with the flag set, all 12 screenshots were rewritten; the Linux-rendered results
were then reverted with `git checkout --` (they are Windows marketing renders and must not be
replaced from Linux).

## Verification (all unpiped, exit codes recorded)

| command | exit |
|---|---|
| `git rev-parse HEAD` -> `7bc3391318a1...` | 0 |
| `dart format --output=none --set-exit-if-changed packages/skotiq_app packages/skotiq_ui` | 0 (after formatting the 2 edited files) |
| `dart analyze` (skotiq_app) — 873 issues, **0 errors/warnings** = documented baseline | 0 |
| `dart analyze` (skotiq_ui) — 59 issues, **0 errors/warnings** | 0 |
| `flutter test --concurrency=2` (skotiq_ui) — 538 passed | 0 |
| `flutter test --concurrency=2` (skotiq_app) — **4469 passed, "All tests passed!"** | 0 |
| `flutter test <all 6 non-golden harness consumers>` (app, 28 tests) | 0 |
| `flutter test test/golden/ --concurrency=2` (app, 20 tests, no env flag) | 0 |
| `flutter test test/golden/design_gallery_golden_test.dart` (ui, 6 tests, no env flag) | 0 |
| `flutter test test/screens/framing/{framing_hips_layer_wiring,framing_registration}_test.dart --tags golden` | 0 |

Clean-tree proof — `git status --porcelain` immediately after the full runs shows only the
intentional edits, and **no** `assets/screenshots/` or `docs/design/goldens/` entries:

```
 M docs/testing/golden-tests.md
 M packages/skotiq_app/test/golden/public_screenshots_test.dart
 M packages/skotiq_app/test/golden/surface_golden_harness.dart
 M packages/skotiq_app/test/screens/framing/goldens/framing_canvas_registered.png
 M packages/skotiq_app/test/screens/framing/goldens/framing_hips_layer_wiring.png
 M packages/skotiq_ui/test/golden/golden_harness.dart
```

### Note on the full skotiq_app suite

The package has 914 test files. The run **completed: 4469 tests, "All tests passed!", exit 0**,
with `git status --porcelain` empty immediately afterwards. It took many hours of wall clock
because a concurrent workstream was running its own `flutter test` against
`/home/scdouglas/Documents/Skotiq2` on the same memory-constrained box (3 competing
`flutter_tester` processes throughout), starving this run to a small fraction of wall-clock CPU.

The bound below was established while that run was still in flight and is retained because it
explains why the result was never in doubt.

That gap is bounded by construction, and the bound was verified rather than assumed. The only
non-test-harness files this branch changes are two golden PNGs. The two harness files it does
change are imported by exactly 20 golden tests plus 7 other test files; every one of those 7 uses
only `ensureFonts()`, which is untouched:

```
mount_tab_label_fit_test.dart:        SurfaceGoldenHarness.ensureFonts
slider_row_label_fit_test.dart:       SurfaceGoldenHarness.ensureFonts
small_button_measure_test.dart:       SurfaceGoldenHarness.ensureFonts
planetarium_hud_labels_test.dart:     SurfaceGoldenHarness.ensureFonts
solar_system_object_identity_test.dart: SurfaceGoldenHarness.ensureFonts
object_info_popup_identity_test.dart: SurfaceGoldenHarness.ensureFonts
skotiq_text_field_test.dart:      GoldenHarness.ensureFonts
```

All 20 golden tests, all 6 app-side consumers above (28 tests), the two framing golden tests, and
the entire skotiq_ui suite (538 tests, which includes the seventh consumer) were run to green
with a clean tree — and the full 4469-test app suite has since confirmed it.

## Deliberately left undone

- **No Windows confirmation of the re-captured baselines.** The host-insensitivity finding is
  strong (two same-commit baselines byte-exact across the Windows/Linux boundary) but I can only
  run Linux. One `melos run test:golden` on the imaging laptop would close it. Both tests keep the
  `golden` tag, so this cannot break a default run on either host either way.
- **Did not un-tag the `matchesGoldenFile` tests** so they would run in CI. That would give real
  regression protection and the evidence suggests it is safe, but it is a policy change that
  should follow the Windows confirmation above rather than precede it. Flagged in the doc.
- **Planetarium perceptual baselines untouched** — they are genuinely host-sensitive and carry a
  separate, pre-existing content backlog already documented in `docs/testing/golden-tests.md`.
- `assets/screenshots/` and `docs/design/goldens/` PNGs left at their committed (Windows) content;
  the gate now prevents them being replaced from Linux by accident.
