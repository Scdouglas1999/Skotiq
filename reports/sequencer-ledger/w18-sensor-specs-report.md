# w18-sensor-specs — camera sensor specs are no longer "not configured"

Branch `agent/w18-sensor-specs`, base `5b2235cc7`.

## The owner's report

> "I also went to Plan and it said my camera sensor specs were unknown, despite
> knowing what camera I had, an ASI1600MM-Cool."

## The defects, both proved before anything changed

### 1. The planner consulted nothing the app already knew

`smartNightExposureContextProvider` asked exactly one source for sensor values:
`HardwareSpecsService.matchCamera`, backed by a four-row built-in catalog
(`_defaultCameraCatalog`: ASI2600MM/MC Pro, ASI533MM/MC Pro). The ASI1600 was
not in it.

Meanwhile Framing had already read the live camera, computed its physical sensor
size and written the geometry through to `SettingsDao.rememberSensorSpec`, and
`capability_provider.dart` did the same on every capability read. The planner
looked at none of it. A pixel size the app had on disk was reported on another
screen as "not configured".

### 2. The catalog matched on edit distance and answered with the WRONG sensor

`HardwareSpecsService._matchScore` accepted a Levenshtein distance up to 3, plus
any six-character substring containment. A model the catalog did not have came
back as whichever model it did — silently, and into every image-scale,
field-of-view and mosaic figure in the app, plus `science.camera.read_noise_e`
and `science.camera.gain_e_per_adu`, which `ScienceCameraAutoConfig` writes from
the same matcher.

Proved by driving the shipped matcher with real model names (scratch probe test,
removed after use; log `~/.cache/ns-tmp/w18-sensor-specs/probe-before.log`):

```
ASI1600MM-Cool     -> null                              <- the owner's camera
ZWO ASI1600MM-Cool -> null
ASI2400MC Pro      -> ZWO ASI2600MC Pro px=3.76   (the ASI2400 is 5.94 um)
ASI585MC Pro       -> ZWO ASI533MC Pro  px=3.76   (the ASI585 is 2.9 um)
ASI294MC Pro       -> ZWO ASI2600MC Pro px=3.76   (the ASI294 is 4.63 um)
ASI183MM Pro       -> ZWO ASI533MM Pro  px=3.76   (the ASI183 is 2.4 um)
ASI6200MM Pro      -> ZWO ASI2600MM Pro           (wrong sensor and full well)
```

A 57% pixel-size error stated as fact is worse than the "not configured" message
the brief asked me to remove, so both had to go.

## What was built

### The resolution chain (`packages/skotiq_core/lib/src/services/sensor_specs/`)

`CameraSensorSpecResolver.resolve(CameraSensorSpecInputs)` returns a
`ResolvedCameraSensorSpecs` in which every field carries the tier it came from
and the sentence that says so. Tiers, best first:

| tier | source | provenance phrase |
| --- | --- | --- |
| (a) | the user's own entry (`smart_night.hardware.camera_overrides.v1`) | "the value you entered" |
| (b) | the connected camera (`getCameraStatus`) | "read from the connected ZWO ASI1600MM" |
| (c) | what that camera reported last time (`RememberedSensorSpec`) | "remembered from ZWO ASI1600MM on 2026-09-12" |
| (d) | the manufacturer's published specification | "the published pixel pitch for ZWO ASI1600MM" |
| (e) | unknown — the only case anything is allowed to say so | — |

Resolution is **per field, not per tier**, because the tiers know different
things: a driver reports geometry and never read noise; the published
specification has read noise but describes the sensor's default readout mode
rather than the crop the driver is delivering.

Named types: `published_figure.dart`, `camera_sensor_entry.dart`,
`curated_camera_sensors.dart`, `camera_sensor_database.dart`,
`camera_sensor_specs.dart`, `camera_sensor_spec_resolver.dart`. Provider:
`providers/camera_sensor_specs_provider.dart`
(`activeCameraSensorSpecsProvider`, `rigCameraSettingsProvider`).

### Callers, all through the one chain

* `smartNightExposureContextProvider` (Plan Tonight, dashboard) — caveats only
  for a field that misses at every tier, each naming the camera.
* `framingFOVProvider` — keeps its live read and its write-through, and falls
  through to the chain instead of straight to "no specs". Its message now names
  the tier per origin.
* `SmartNightService._pixelSize` and `sequence_emitter._cameraSpecFromProfile`.
* `ScienceCameraAutoConfig` — read noise and e-/ADU now come from the chain, so
  photometry and Smart Night cannot disagree about the same camera.
* `HardwareSpecsService` is now only the user-override store plus an exact
  matcher; `_defaultCameraCatalog`, `matchCamera`, `CameraHardwareMatch` and the
  Levenshtein code are gone.

### Model matching: exact, never fuzzy

`CameraSensorDatabase.lookup` matches a driver string against an explicit,
reviewable per-row `driverNames` list. The only liberties taken cannot change
*which* row wins, because every candidate still has to hit a row's own name
exactly:

1. case, spaces, hyphens, underscores and dots normalised away;
2. a leading vendor token dropped (`zwo`, `zwoptical`, `qhyccd`, `canon`,
   `nikon`) — ASCOM prepends the brand and the brand is not the model;
3. a trailing serial dropped (`QHY268M-6c1d4a8e9f01` -> `QHY268M`), where a tail
   counts as a serial only at >= 6 characters containing a digit, so `-Cool`,
   `-PH` and `-Pro` survive.

A name no row claims is a **miss**, reported as a miss. Two rows claiming one
name throws at construction rather than resolving by list order.

Near-misses covered by tests as explicit non-matches: `ASI2400MC Pro`,
`ASI585MC Pro`, `ASI676MC`, `ASI2600MM-P25`, `ASI1601MM`, `QHY533`, `QHY600`.
ZWO and QHY keep separate rows for the same Sony part because they crop it
differently (IMX571: 6248x4176 vs 6252x4176; IMX183: 5496x3672 vs 5544x3684).

### Gain dependence: labelled, curved, or absent — never flattened

`PublishedFigure` stores read noise and full well in the shape the manufacturer
published them in: `atGain` (a driver gain value), `atLabel` (a dB figure or
named mode, carried verbatim), `range` (low/high across the gain axis with no
attribution), `unattributed` (a single figure with no operating point, which is
how every one of these vendors quotes full well).

The resolver then:

* uses a figure published **at the user's gain** and says so;
* **interpolates** between two published points that bracket the gain, and says
  which two — the only case where the curve itself is published;
* otherwise takes the end of a published **range** that does not flatter the
  camera (high read noise, low full well) and says that is what it did;
* otherwise uses the single published figure and states the operating point the
  manufacturer quoted it at ("which the manufacturer quotes only at 30 dB
  gain") — ZWO does not publish the dB-to-driver-gain mapping, so converting it
  would invent a number;
* omits the field where nothing publishable exists.

Deliberate omissions, each with the reason on the row:
ASI533MM Pro read noise (ZWO publishes only a best-case "1.0e-" with no gain,
which would understate noise by up to 3.8x across the gain axis);
ASI1600MC and ASI183MC QE (the manuals give a peak for the mono sensor only);
every QHY row's QE (QHY's specification tables carry QE curves, no peak number);
read noise, full well and QE on every DSLR row (Canon and Nikon publish none).

### The curated database — 29 rows, every figure sourced on the row

(The first commit's message says "30 rows"; the count is 29. Corrected here
rather than by rewriting the branch's history.)

Each `CameraSensorEntry.source` names the document, its revision and its URL.
Nothing is measured, averaged, inferred from a sibling model or taken from a
third-party sensor database. The ZWO and QHY documents were retrieved
2026-09-14; the Canon spec pages were read through the Internet Archive's
capture of Canon's own specification pages, which block automated fetches
directly.

| rows | source |
| --- | --- |
| ZWO ASI1600MM, ASI1600MC | ZWO "ASI1600 Manual" Rev 1.5, Aug 2021, ss2/4 (its model table lists ASI1600MM, ASI1600MM Pro and ASI1600MM-Cool against one sensor part and one spec table) |
| ZWO ASI2600MM Pro, ASI2600MC Pro | ZWO "ASI2600 Manual" Rev 1.3, Jul 2021, ss2/3/4 |
| ZWO ASI6200MM Pro, ASI6200MC Pro | ZWO "ASI6200 Manual" EN, ss2/3/4 (HCG at gain 100, read noise 1.5e there) |
| ZWO ASI533MC Pro | ZWO "ASI533 Manual" Rev 1.2, Aug 2021, ss1/3 |
| ZWO ASI533MM Pro | ZWO product page "ASI533 Pro Series" spec table (the manual covers only the MC) |
| ZWO ASI294MC Pro, ASI294MM Pro | ZWO "ASI294 Manual" Rev 2.2, Feb 2022, ss3/4 (separate mono/colour figures; HCG at gain 120) |
| ZWO ASI183MM, ASI183MC | ZWO "ASI183 Manual" EN, ss2/4/5 |
| QHY600M, QHY600C | qhyccd.com "QHY600M/QHY600C" spec table (standard mode, 1x1) |
| QHY268M, QHY268C | qhyccd.com "QHY268M/C PH (IMX571)" spec table (standard mode; the Extended Full Well mode is a different mode, not a different gain, and is not blended in) |
| QHY533M, QHY533C | qhyccd.com "QHY533M & QHY533C" spec table (effective area, excluding overscan) |
| QHY183M, QHY183C | qhyccd.com "QHY183M & QHY183C" spec table |
| Canon EOS 6D, 6D Mark II, Ra, R6, 60Da, 600D/Rebel T3i | Canon's own specification pages, Image Sensor + Image Size rows |
| Nikon D5300, D750, D810A | Nikon's specification pages, 撮像素子 + 記録画素数 (FX/DX, size L) |

DSLR pixel pitch is **derived** from the published imaging area and pixel count
rather than stored, so only manufacturer-printed numbers live in the file; the
provenance line says "derived from the published sensor size and pixel count",
and a test cross-checks every row that publishes both a pitch and an area
against each other (a transcription typo in either shows up as a mismatch).

### Saying where the number came from

* **Plan detail column** — `CameraSensorSpecsRow`: one line stating the
  resolved values ("3.8 um - 4656 x 3520 - 1.2 e- read noise - 20,000 e- well -
  60% QE"), a trailing tier label ("Published specs" / "Remembered" / "From the
  camera" / "Set by you"), the full provenance sentence on hover, and a tap that
  opens the correction dialog. It sits beside the exposure recommendation it
  explains, not on a settings screen.
* **Plan risks banner** — `PlanningRisksBanner` still collapses sensor caveats
  into ONE banner (02 rules 4 and 5), but now only for fields that genuinely
  miss at every tier, and it names the camera it could not identify plus the one
  action that fixes it. A profile with no camera at all says that instead. The
  collapsing is driven by `isSensorSpecCaveat`, which shares its marker phrase
  with `sensorSpecCaveat`, the function that produces the caveats — the old
  banner sniffed for the words "not configured" and would have silently stopped
  recognising a reworded caveat.
* **Framing equipment card** — one sentence per tier with the action that would
  upgrade it.
* **Smart Night builder** — `_shouldPromptForCameraSpecs` now asks
  `specs.unresolvedFields` instead of grepping caveat prose.

### Letting the user see and correct it

`SmartNightMissingSpecsDialog` (a `part` of the sequencer's Smart Night dialog,
so unreachable from anywhere else) is promoted to
`packages/skotiq_app/lib/widgets/camera_sensor_specs_dialog.dart` as
`CameraSensorSpecsDialog`, on the design system, and:

* arrives **prefilled** with what the chain resolved, each field labelled with
  where its value came from, so this is a correction surface rather than a
  datasheet transcription exercise;
* accepts a change to one field and keeps the rest of what resolved;
* takes the gain that read noise and full well were measured at, and refuses
  them without it — a figure with no operating point is exactly what the
  published database refuses to invent;
* refuses a QE above 1 with the reason;
* writes the existing `smart_night.hardware.camera_overrides.v1` key, which the
  host's `/api/smart-night/settings` endpoint already serves by prefix, so a
  paired remote client reads and writes it on the rig that owns the camera.

Precedence between the two user-entered sources is documented in
`_preferUserValue`: the **per-camera override wins over the global expert keys**
(`smart_night.camera.full_well_e`, `smart_night.camera.qe_peak`, and
`science.camera.read_noise_e` only once frozen with
`science.camera.auto_managed=false`). Specific beats general, and the per-camera
dialog is the surface the Plan screen sends people to.
`science.camera.read_noise_e` is auto-written FROM this chain, so reading it back
as an override unfrozen would be circular.

## For w16-profiles: the profile field this work wants

I did not touch `equipment_profiles_screen.dart`. If that screen grows a camera
section, the field it should carry is:

* a **"Sensor specs" row** on the camera block, showing
  `ResolvedCameraSensorSpecs.valueSummary` with
  `originLabel` as its trailing text (watch `activeCameraSensorSpecsProvider`),
  and opening `CameraSensorSpecsDialog.show(context, specs)` on tap. That is
  exactly the `CameraSensorSpecsRow` widget already built for the Plan detail
  column (`packages/skotiq_app/lib/screens/planner/widgets/planning_risks_banner.dart`)
  — it is self-contained and can be dropped in as-is.

No new DB columns are needed: overrides live in the settings key, keyed by
normalised camera model, so they survive a profile rename and do not apply one
camera's corrections to another.

## Verification

Commands run unpiped in the worktree with
`TMPDIR=$HOME/.cache/ns-tmp/w18-sensor-specs`. Exit codes recorded below.

### Gates

| # | command | exit |
| --- | --- | --- |
| 1 | `dart format --output=none --set-exit-if-changed packages/skotiq_core packages/skotiq_app` | 0 |
| 2 | `dart analyze` in `packages/skotiq_core` | 0 — zero errors, zero warnings. 16 pre-existing infos, none in a file this branch touches |
| 3 | `dart analyze` in `packages/skotiq_app` | 0 — zero errors, zero warnings. 873 pre-existing infos (820 `deprecated_member_use` from the design-system wave); the only three that land in a file I edited (`smart_night_dialog.dart` h4/h5/outline) are verified present at `5b2235cc7` in lines I did not change |
| 4 | `flutter test test/services test/providers test/models --concurrency=4` in `packages/skotiq_core` | 0 — 5796 passed, 4 pre-existing skips |
| 5 | `flutter test test/screens/planner test/widgets test/screens/sequencer test/screens/settings test/screens/framing --concurrency=4` in `packages/skotiq_app` | 1 — 1963 passed, 2 failed: both pre-existing golden failures, proved identical at `5b2235cc7` (see below) |
| 5b | `flutter test test/screens/planner test/widgets --concurrency=4` in `packages/skotiq_app`, re-run after the last banner change | 0 — 442 passed |
| 6 | `flutter test test/headless_api/science_handlers_test.dart --concurrency=4` in `apps/desktop` | 0 — 9 passed |
| 7 | `flutter build linux --release` in `apps/desktop`, at `5b2235cc7` and at the branch tip | 0 both |
| 8 | `graphify update .` | 0 |

The two failures in gate 5 are `framing_hips_layer_wiring_test`
(`goldens/framing_hips_layer_wiring.png`) and `framing_registration_test`
(`goldens/framing_canvas_registered.png`), the Windows-captured goldens this
repo's Linux runs have always failed. Proved pre-existing rather than asserted:
checked out `5b2235cc7` in this worktree and ran both files, which produced
byte-identical failures — `100.00%, 480000px` and `75.45%, 772584px`, the same
numbers as at the tip. They are also off this branch's code path: the framing
fall-through I added runs only when there is no live reading
(`if (pixelsX == null)`), and both goldens render a connected camera.

Two failures the change caused were found and fixed before the final run:
`framing_fov_camera_churn_test` and `framing_fov_remembered_sensor_test` both
asserted the word "remembered" and were getting "Sensor size **R**emembered
from …" — a sentence assembled by capitalising a phrase that was already the
tail of one. Both now pass against a per-tier sentence.

`packages/skotiq_core/lib/src/services/scheduler/rejection_labels.dart`
carries two pre-existing `curly_braces_in_flow_control_structures` infos; that
file is untouched by this branch.

### Tests added

* `test/services/sensor_specs/camera_sensor_database_test.dart` — matching
  (case/separator, vendor prefix, QHY serial, mono-vs-colour, per-vendor crops),
  seven named near-misses that must NOT match, duplicate-claim rejection, and
  data integrity: every row sourced with a URL, published pitch cross-checked
  against published area, DSLR rows carrying geometry only, every
  gain-dependent figure carrying its operating point.
* `test/services/sensor_specs/camera_sensor_spec_resolver_test.dart` — every
  tier and every fall-through, a zeroed driver reading, non-square pixels, the
  four gain-figure shapes, curve interpolation, the fields the manufacturers
  will not publish, and the provenance strings.
* `test/providers/smart_night_exposure_context_provider_test.dart` — the frozen
  science read noise winning, an unknown camera caveating four fields by name,
  a malformed override blob being reported, and a correction reaching the
  planner with no invalidation.
* `test/providers/framing_fov_remembered_sensor_test.dart` — a known camera
  model working in Framing before it has ever been connected.
* `packages/skotiq_app/test/screens/planner/planning_risks_banner_test.dart`
  — banner collapsing, the camera named, the no-camera case, the provenance row
  and its single activatable semantics node.
* `packages/skotiq_app/test/widgets/camera_sensor_specs_dialog_test.dart`
  — prefill, per-field provenance, the one-unpublished-field case, the
  nothing-published case, gain and QE validation, correcting one field while
  keeping the rest, and the remote write.

## Live reproduction (Xvfb, softpipe, scratch database)

Harness `tools/ui_audit/drive_linux.py` on `SK_AUDIT_DISPLAY=:88`,
`SK_AUDIT_RUNTIME=/tmp/ns-audit-w18`, profile `w18`. Never `DISPLAY=:0`.

The scratch database was seeded (`~/.cache/ns-tmp/w18-sensor-specs/seed.sh`)
with the owner's setup: one active profile whose camera is `ASI1600MM-Cool`
with no sensor fields, an observing site, and two targets so Plan Tonight has
something to score. No camera was ever connected, so tiers (a), (b) and (c) are
all empty and only the published specification can answer.

Both bundles were built in this worktree from the same Rust bridge; the tip
bundle's `lib/libapp.so` was string-grepped for `the published pixel pitch for`
to confirm the binary under test was the one built (1 hit at the tip, 0 in the
kernel blob).

### Before — `5b2235cc7`, `shots/before-02-plan.png`

A warning banner across the top of Plan:

> **Camera sensor specs are not configured** Scores use conservative estimates
> until you fill them in. Camera pixel size is unavailable; using a 3.76 micron
> planning estimate.   `[Open camera specs]`

The owner's report, exactly. Behind it, "Suggested exposure 30 s" and
"Estimated integration 4h" were computed from a 3.76 µm stand-in for a sensor
whose published pitch is 3.8 µm.

### After — branch tip, `shots/after-12-asi1600-final.png`, `shots/after-14-asi1600-row.png`

No banner. In the detail column, beside the exposure figures it explains:

> 📷 **Camera sensor**                                      Published specs
> 3.8 µm · 4656 × 3520 · 1.2 e⁻ read noise · 20,000 e⁻ well · 60% QE

Hover/screen-reader text carries the full provenance, including "Read noise: the
published figure for ZWO ASI1600MM, which the manufacturer quotes only at 30 dB
gain".

### After — a camera genuinely not in the database, `shots/after-03-unknown-banner.png`

Same profile with the camera renamed to `Acme SkyCam 9000`:

> ⚠ **No published sensor specs for Acme SkyCam 9000** Scores use conservative
> estimates for pixel size, sensor width, sensor height, read noise, full well
> and QE.   `[Enter camera specs]`

One banner, the camera named, the fields listed, one action.

### After — the correction loop, `shots/after-09-dialog-full.png` → `shots/after-11-corrected.png`

Clicking `Enter camera specs` opens the dialog, prefilled where anything
resolved and explaining each empty field. Typing gain 120, 4.63 µm, 4144 × 2822,
2.1 e-, 42,000 e-, 0.75 and saving wrote

```
[{"model":"Acme SkyCam 9000","aliases":[],"pixelSizeMicrons":4.63,
  "qePeak":0.75,"defaultGain":120,
  "gainPoints":[{"gain":120,"readNoiseE":2.1,"fullWellE":42000.0}],
  "sensorWidthPx":4144,"sensorHeightPx":2822}]
```

and the Plan screen immediately dropped the warning and now reads

> 📷 **Camera sensor**                                           Set by you
> 4.63 µm · 4144 × 2822 · 2.1 e⁻ read noise · 42,000 e⁻ well · 75% QE

## Two defects the live run found in this work, and their fixes

1. **The provenance line truncated.** In the 380px detail column the
   single-line `ListRow` rendered "…1.2 e⁻ r…" — a number stated and then
   hidden. Replaced with a purpose-built two-part row that wraps to at most
   three lines, carries the tier as a label, and is ONE activatable semantics
   node reading its own provenance.
2. **A correction did not reach the planner.** `rigCameraSettingsProvider` read
   the settings table once, so after saving an override the Plan screen kept
   warning about a camera the user had just described. It now rides
   `allSettingsProvider`'s stream locally (self-refreshing for any writer,
   including the headless API) and is invalidated by hand only on a paired
   remote client, where the settings are fetched from the host. Covered by a
   provider test that writes and waits with no invalidation.

A third, smaller one: the dialog printed "Not published for this camera.
Planning falls back to a conservative estimate until you fill it in." under six
consecutive empty inputs. It now says that once, at the top, when nothing
resolved, and per-field only where an empty field is the exception.

## Left undone, deliberately

* **On-sky / on-rig validation.** Everything here was exercised on Linux under
  Xvfb against a seeded database. The tier that needs real hardware — (b), a
  live `getCameraStatus` on the owner's ASI1600MM-Cool, and the write-through
  into tier (c) — is covered by unit and provider tests and by Framing's
  existing tests, but has not been run against the camera.
* **Remembered geometry in remote mode.** `camera_sensor_specs` (the remembered
  store) is not under the `smart_night.` prefix the host's settings endpoint
  serves, so a paired remote client cannot read tier (c) from the rig. It still
  gets (a), (b) and (d). Moving the key would orphan every existing install's
  remembered specs, so it wants its own migration rather than a change smuggled
  into this one.
* **QHY294 and QHY163 rows.** I could not get exact effective pixel dimensions
  for either from QHY's own pages (the QHY294 page states megapixels and two
  readout modes without the pixel counts; the QHY163M manual has no
  specification table). They are misses rather than guesses.
* **The ASI2600 2025 revision (`ASI2600MM-P25`).** ZWO's current product page
  quotes a 73 ke- full well against the manual's 50 ke- for the same model
  name. Rather than pick one, the 2025 SKU is not claimed by any row, so it
  warns honestly. It wants a row of its own once the manual for it is published.
* **The equipment profile field** described above for `w16-profiles`.

## One more thing the reviewer should know

`native/skotiq_native/target` in this worktree was a 48-byte TEXT file
containing the path `/home/scdouglas/.cache/ns-worktrees/cargo-target` — an
intended symlink that had not been made one, which made `cargo build` fail with
"Not a directory". I replaced it with the symlink it was meant to be so the
Linux release bundle could pick up `libskotiq_bridge.so`. The path is
git-ignored, so it is not part of this branch; it is noted because the next
agent to build in a fresh worktree will hit the same thing.

No Rust was changed by this workstream, so both the before and after bundles
were built against the same `libskotiq_bridge.so` from the wave's shared
cargo target directory.
