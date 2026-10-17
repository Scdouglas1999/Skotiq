# app-screens-b — implementation log

Baseline: b07d91c9d. Predecessor left nothing of this batch on the tree except a
stray `stack_result_screen.dart.tmp.5604.de4da0067575` (identical to HEAD minus
one comment block) — deleted.

## Item 6 — DELETE four dead files + two stale doc mentions — DONE

Re-proved zero callers across `packages/ apps/ native/ tools/ docs/` (excluding
`graphify-out/` caches, which store the source text verbatim and poison a naive
grep):

- `SelectedObjectHud` — 2 self-references + one comment at
  `planetarium_screen/layouts.dart:532` recording its removal.
- `MosaicPlannerSkyView` — self-references + one doc-comment mention.
- `TargetPickerSkyView` — self-references + one doc-comment mention.
- `weather_widgets` (barrel) — nothing outside the file.

No barrel `export`/`part` referenced any of the four; no test referenced them.
Deleted the four files and trimmed the two stale names from the
`AdaptiveInteractiveSkyView` doc comment (`FullScreenSkyView`, verified live at
`layouts.dart:57,360` and `redesign/planetarium_shell.dart:87`, stays).

## Item 2 — DEDUP+BUG TransientTypeStyle — DONE

Failing test written first:
`test/screens/transients/transient_type_presentation_agreement_test.dart`.
Against baseline code, 2 of its 9 cases failed:

- `gammaRayBurst is named the same on every alert surface` — suggestions panel
  said 'GRB Afterglow', card and status-bar dropdown said 'Gamma-Ray Burst'.
- `a type is drawn in one severity colour on every surface` — variableStar chip
  was `#7ab8d4` (accent) in the dropdown and `#d49a3a` (warning) in the panel.

New canonical `lib/utils/transient_type_style.dart`. The severity palette is
**banded off the priority the app already computes** in
`TransientAlertService._calculatePriority` (supernova 1, GRB 2, nova 3,
cataclysmic 4, comet 5, asteroid 6, variableStar 7, other 8) so colour and queue
order cannot drift apart. Recorded in the class doc comment.

Converted all ten switch sites: `transient_card.dart` (icon/colour/label),
`transient_alerts_panel.dart` (`_TypeBadge` icon+colour, tile label, settings
chip → shortLabel), `transients_screen.dart` (filter chip → shortLabel),
`transient_alert_badge.dart` (icon/colour/label). Removed `_TypeBadge.priority`,
which no branch of the deleted switch ever read.

Note for the verifier: the work order listed `SkotiqIcons.sparkle` vs
`LucideIcons.sparkles` as a supernova-icon disagreement. They are the same
glyph — `skotiq_icons.dart:462` aliases one to the other. Not a defect.

Result: `flutter test test/screens/transients/ test/widgets/transient_alert_badge_test.dart`
→ **35 passed, 0 failed** (9 of them new).

## Item 1 — PERF science analytics tab rebuild scoping — DONE

Failing test first:
`test/screens/analytics/widgets/science_tab_device_tick_scope_test.dart`.
It pumps the tab with one science product (so the full nine-section layout
renders), captures the widget instances of `ScienceSurfaceExplorer` and
`ScienceInsightsPanel`, then fires the real heartbeat
(`CameraStateNotifier.updateCommunication`) and pumps one frame. Widget instance
identity across the pump is an exact record of what rebuilt.

Against baseline: FAILED — the surface explorer (and with it every chart on the
tab) was rebuilt by the heartbeat.

Fix: extracted `_EquipmentHealthSection` (a `ConsumerWidget` at the tail of
`science_analytics_tab.dart`) that watches `cameraStateProvider`,
`guiderStateProvider` and `mountStateProvider` itself and renders
`ScienceInsightsPanel`. Both call sites (narrow and wide layout) now pass data
instead of a pre-computed report.

`DateTime.now()` is gone from the analysis input. Provably behaviour-preserving:
`EquipmentHealthService.analyze` reads only `deviceId` and `isHealthy` off a
`DeviceHealthSnapshot` — `lastSuccessfulTimestampMs` is never consulted
(`equipment_health_service.dart:190-310`). Stamping the clock only guaranteed the
input differed on every rebuild. Camera keeps its real
`lastSuccessfulCommunication`; mount/guider pass 0 (no heartbeat tracked).

Result: the new test passes; `flutter test test/screens/analytics/` → 219 passed,
2 failed, both `captures_landscape_test.dart` golden captures — **pre-existing**,
confirmed by running that file against the baseline `science_analytics_tab.dart`
recovered with `git show b07d91c9d:…` (same 75% pixel diff). Golden-tagged tests
are excluded from `melos run test`.

## Item 7 — RELIABILITY bound the eleven mosaic hub actions — DONE

Failing test first: `a hub that never answers still releases the action button`
in `test/screens/mosaic/mosaic_project_controller_test.dart` (new `hangOnPublish`
on the existing `_FakeCollab`). Verified against pre-fix code by removing just
the `.timeout(hubTimeout)` on `publishToHub`: the test **hung and was killed at
the 30 s framework timeout** — which is the finding, exactly.

Two bounds, because one number would be wrong for both halves:
- `defaultHubTimeout` = 60 s — control plane: publish, `_runClaim`, release,
  force-release, discover, join, refresh status.
- `defaultHubTransferTimeout` = 10 min — anything moving image bytes or
  stitching server-side: `uploadPanelMaster`, `uploadAllIntegrated` (applied
  **per panel**, so a twenty-panel batch is not capped as one call),
  `assembleFromHub`, `downloadOutput`.

Both are constructor parameters defaulting to those constants so a test can trip
them without wall-clock time. Every action gained an `on TimeoutException`
branch clearing its busy flag and surfacing an actionable message, matching the
treatment `load()` already gave the local read at `:366`.

Result: `flutter test test/screens/mosaic/mosaic_project_controller_test.dart`
→ **24 passed** (1 new).

## Item 4 — PERF cache sub-rail thumbnails — DONE

Failing test first:
`test/screens/session_review/sub_cull_rail_thumbnail_cache_test.dart` — counts
`getImageThumbnail` calls per image id across an empty-then-repopulate cycle of
the subs list (what `GridView.builder` does to a cell on scroll-out/scroll-back).
Against baseline: FAILED, 2 requests for the same sub.

Fix, confined to `sub_cull_rail.dart`: `subThumbnailProvider`
(`FutureProvider.autoDispose.family<Uint8List, int>`) with `ref.keepAlive()`
registered in a container-scoped `_ThumbnailRetention` that closes the oldest
link past 128 entries. `_SubThumbnailState` lost its `initState` fetch and now
watches the provider. The retention map is held by a `Provider`, not a global, so
two `ProviderContainer`s in a test run cannot close each other's links.

Result: `flutter test test/screens/session_review/ test/golden/cull_and_compare_golden_test.dart`
→ **85 passed**.

## Item 3 — PERF move the stretch off the build path — PARTIAL (half blocked)

Failing test first: `test/screens/stack_result/stretch_off_build_test.dart`,
`the first frame does not carry the stretched image`. Against baseline: FAILED —
`AstroImageViewer` was already mounted on the first pump, i.e. the whole image
was rendered inside `build`.

Done:
- `_linearGray` / `_linearColor` are now the top-level `renderLinearGrayRgba` /
  `renderLinearColorRgba` and run in `Isolate.run`.
- `_renderStretch` returns a `Future`; `_resolveDisplayRgba` *schedules* instead
  of computing, guarded by a (buffer, stretch) in-flight pair and a generation
  counter so a rebuild does not queue a second pass and a stale result cannot
  paint over a newer one.
- The viewer shows a progress indicator while the first render is in flight
  rather than the "Image not available" empty state.

**Blocked half:** "make the `autoStretchImage` seam async". Both STF seams are
synchronous and live in `skotiq_core`
(`backend/roles/imaging_backend.dart:131` plus the three backend
implementations, and `services/stacking_engine_seam.dart:119,182`). Making them
async ripples through `stack_and_share_service.dart:515,575`,
`first_light_orchestrator.dart` and their tests — outside this batch's scope.
The STF branches therefore still occupy the UI isolate, but now after the frame
is on screen rather than during layout. Recorded in the code comment on
`_renderStretch`.

Result: `flutter test --exclude-tags golden test/screens/stack_result/ …`
→ **16 passed**, including three new parity tests proving the linear stretches
are byte-identical across the isolate hop.
`captures_landscape_test.dart` fails, **pre-existing** — verified by running it
against the baseline `stack_result_screen.dart` from `git show b07d91c9d:…`
(identical 1.78% / 4.37% diffs).

## Item 5 — DEDUP seven CSV row builders — DONE

Parity test written **before** the refactor and passing on the pre-refactor code:
`test/screens/analytics/widgets/science_export_hub_csv_parity_test.dart` — seeds
one row into each of the seven standalone export providers, taps each dataset's
CSV button, and asserts the produced CSV **character for character** (header row
+ data row, including the `\r\n` and the UTC/JD columns).

Refactor, in place, no file split: one `_ExportDataset<T>` descriptor (header,
standalone provider, per-session provider builder, timestamp accessor, row
projection) and one `_rowsFor<T>` carrying the five-step recipe. The seven
`_build*Rows` methods are gone; seven top-level `final` descriptors replace them.
1448 → 1361 lines, and the header of a dataset now sits adjacent to the row
projection it describes.

Result: parity test + the four existing export-hub suites → **16 passed**, CSVs
unchanged.

## Batch verification

`flutter analyze` (whole package): **0 errors, 0 warnings**; 25 `info` lints, all
pre-existing (`deprecated_member_use` on `clampPanelWidth`, `prefer_const_*` in
untouched test files).

`flutter test --exclude-tags golden` across every suite this batch can reach —
`test/screens/{transients,suggestions,session_review,mosaic,collaborative_sky,planetarium,stack_result}/`,
`test/screens/stack_result_screen_test.dart`,
`test/screens/stack_result_astrobin_date_test.dart`, `test/widgets/`,
`test/screens/analytics/widgets/` — → **849 passed, 0 failed**.

Golden-tagged capture tests (`captures_landscape_test.dart` under `analytics/`
and `stack_result/`) fail on this machine and failed identically against the
baseline sources recovered with `git show b07d91c9d:…`. They are excluded from
`melos run test`. Not this batch's.

Also removed: `stack_result_screen.dart.tmp.5604.de4da0067575`, a tracked editor
temp committed in 565cc1f37.
