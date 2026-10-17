# Stage-2 batch `ui-tooltip-framing` — SKY-8, SKY-9

Both items were recorded BLOCKED (out of scope) by the Wave B-fix
sky/planetarium batch (`impl/bfix-sky-planetarium.md` §SKY-8, §SKY-9). Both root
causes were re-verified against HEAD before any edit; both were still present.

## Files claimed

| File | Item |
| --- | --- |
| `packages/skotiq_ui/lib/src/components/skotiq_tooltip.dart` | SKY-8 |
| `packages/skotiq_ui/test/skotiq_tooltip_anchor_test.dart` (new) | SKY-8 |
| `packages/skotiq_core/lib/src/database/daos/settings_dao.dart` | SKY-9 (persistence) |
| `packages/skotiq_core/lib/src/providers/framing_provider/support.dart` | SKY-9 (read-back + write-through) |
| `packages/skotiq_core/lib/src/providers/framing_provider.dart` | SKY-9 (one import line) |
| `packages/skotiq_core/lib/src/providers/capability_provider.dart` | SKY-9 (connect-time write-through) |
| `packages/skotiq_core/test/providers/framing_fov_remembered_sensor_test.dart` (new) | SKY-9 |
| `packages/skotiq_core/test/providers/framing_fov_camera_churn_test.dart` | SKY-9 (amended expectation, see below) |

No generated file was edited and no codegen was run.

---

## SKY-8 — tooltip drawn ~176 px off its control, and tooltips never retire

### Half 1: the anchor was in the wrong coordinate space

`_TooltipOverlay.build` measured the trigger with
`renderBox.localToGlobal(Offset.zero)` — **window** coordinates — and clamped
against `MediaQuery.sizeOf(context)` — the **window** size. But the widget it
builds is an `OverlayPortal` overlay child: it is laid out as a child of the
host `Overlay`'s theater, in the **overlay's** coordinate space. The two agree
only when the overlay's origin is the window origin. Wherever it is not, the
tooltip is displaced by exactly the overlay's inset, which is the shape of the
reported symptom (label 176 px right and 79 px below its button, out over the
star field beside a different control).

Measured at HEAD with a probe test — an `Overlay` inset by `(176, 79)`:

```
NESTED TRIGGER Rect.fromLTRB(176.0,  79.0, 210.0, 113.0)
NESTED TOOLTIP Rect.fromLTRB(333.0, 225.0, 405.0, 243.0)   <- +176, +~96
```

Fix: resolve the host overlay's render box and measure against it —
`renderBox.localToGlobal(Offset.zero, ancestor: overlayBox)` — and use
`overlayBox.size` as the viewport the layout delegate clamps to, so the box the
tooltip is *constrained* to and the box it is *positioned* in are the same one.
Falls back to the previous global/MediaQuery behaviour if the overlay box is
missing. This is the idiom the rest of the repo already uses for overlay
geometry (`image_thumbnail_strip.dart:863`,
`sequence_tree_context_menu.dart:56`, `planetarium_screen/actions.dart:756`).

### Half 2: no arbitration between tooltips

Every `SkotiqTooltip` owned an independent `OverlayPortalController`
retired only by its own `MouseRegion.onExit` or its own 3 s touch timer, so a
second tooltip opening left the first alive. Added a single library-private
visible-tooltip slot (`_visibleTooltip`); showing claims it and retires the
previous holder, hiding and `dispose` release it.

### Proof

`packages/skotiq_ui/test/skotiq_tooltip_anchor_test.dart`.

At HEAD (component reverted, tests kept):

* `tooltip is drawn on its trigger — overlay at the window origin` — PASSES
  (the control case: this is why the defect was invisible to the existing
  edge/lifecycle tests).
* `tooltip is drawn on its trigger — overlay inset by a nav rail and a header`
  — FAILS: `Expected: a numeric value within <1.0> of <728.0>; Actual: <904.0>`
  (904 − 728 = 176).
* `opening a second tooltip retires the first` — FAILS:
  `Expected: no matching candidates; Actual: Found 1 widget with text "Reset view"`.

With the fix: all three pass, and the whole `skotiq_ui` suite is green
(306 tests), including the pre-existing `skotiq_tooltip_edge_test` and
`skotiq_tooltip_lifecycle_test`.

---

## SKY-9 — Framing FOV gated on a CONNECTED camera

### What was actually blocking it

`framingFOVProvider` only ever filled sensor pixel dimensions from a live
`backend.getCameraStatus` call while the camera was `connected`, and otherwise
returned `EquipmentStatus.noCameraSpecs`. Every Framing gate in the app routes
through this one provider (`framing_screen.dart:137`,
`framing_actions_panel.dart:126`, the sidebar's FOV and mosaic cards,
`mosaic_project_controller.dart:1136`, `plan_tonight_sequencer_helper.dart:394`),
so closing it here closes the whole finding.

### Why this is NOT a profile schema change (the blocked-item premise, revisited)

The prior log proposed adding sensor dimensions to `EquipmentProfile`. That is
the wrong home and the expensive one:

* it needs new columns on the drift `EquipmentProfiles` table → regenerated
  `database.g.dart` + a schema-version migration, and new fields on the freezed
  `EquipmentProfile` → regenerated `.freezed.dart` / `.g.dart` — all banned for
  this batch; and
* it models the fact wrongly. **Sensor size belongs to the camera body, not to
  the profile.** Two profiles sharing one camera (an OTA swap) would each hold
  their own copy, free to disagree.

So the value is persisted per **camera device id** in the existing
`app_settings` key/value table under `camera_sensor_specs`, via new typed
methods on `SettingsDao` (`RememberedSensorSpec`, `getRememberedSensorSpec`,
`rememberSensorSpec`, capped at 16 remembered bodies, corrupt JSON read as
"nothing remembered"). `@DriftAccessor(tables: [AppSettings])` is unchanged, so
`settings_dao.g.dart` needed no regeneration.

**No FRB regeneration was required and none was performed.** Nothing crosses the
Rust bridge: the store is a Dart-side drift row, and the read/write points are
Dart providers.

### The wiring

* **Write-through at connect** — `cameraCapabilitiesProvider` is where the app
  learns a camera's geometry on connect, so it now records it. Wrapped in its
  own try/catch: remembering is a convenience for a later offline session and
  must never fail the capability read that device connection and every camera
  control depend on.
* **Write-through in Framing** — `framingFOVProvider` records what the live
  `getCameraStatus` returned. Its own try/catch, so a store failure is not
  reported to the user as `Could not query camera specs:` on an FOV that in
  fact resolved.
* **Read-back** — when no live dimensions were obtained and the profile names a
  camera, the remembered spec is used and the result carries
  `'Sensor size remembered from the last time this camera was connected.
  Connect it to confirm.'` A camera never seen connected still returns
  `noCameraSpecs`: a guessed FOV is worse than none.

### Proof

`packages/skotiq_core/test/providers/framing_fov_remembered_sensor_test.dart`
(new, 3 tests). Proven failing at HEAD with only the `SettingsDao` addition
present (so the failures are behavioural, not compile errors):

* `a camera seen once keeps Framing working after it is disconnected` —
  `Expected: EquipmentStatus.ready; Actual: EquipmentStatus.noCameraSpecs`.
  Two containers share ONE `SkotiqDatabase` instance (the shared
  `inMemoryDatabaseOverride()` builds a fresh database per container, which
  would have made this test prove nothing); the second container's backend
  throws on any `getCameraStatus`, and `verifyNever` pins that it is never
  called.
* `fetching camera capabilities remembers the sensor` — `Expected: not null;
  Actual: <null>`.
* `a camera never seen connected still reports no specs` — passes at HEAD and
  after; it is the guard against the fix over-reaching.

### One pre-existing test amended, deliberately

`framing_fov_camera_churn_test.dart` → `a disconnect still re-runs it` asserted
`EquipmentStatus.noCameraSpecs` after a disconnect. That expectation IS the
defect. The invariant the test was written for — the narrowed
`cameraStateProvider.select` must still notice a disconnect — is unchanged and
is what the amended assertion checks: the result now carries the "remembered"
message (so the disconnect was noticed and disclosed) and `statusQueries`
stays 1 (a disconnected camera is still never queried). The amendment is
commented in place with why.

### Left open, deliberately

`opticalConfigProvider` (`profiles_provider.dart:1160`) has the same live-camera
gate for sensor dimensions. It is a synchronous `Provider`, so reading the
async store from it means converting it to a `FutureProvider` and changing
every consumer — out of scope for this batch, and not part of the SKY-9 repro
(no Framing gate reads it). Worth a follow-up item.

---

## Verification run

* `skotiq_ui`: full `flutter test test/` — 306 passed, 0 failed.
* `skotiq_core`: `flutter test test/providers/` — 1528 passed, 1 failed.
  The failure is `sequence_executor_live_stacking_autofeed_test.dart`, which
  fails to COMPILE (`_FakeLiveStackingService is missing implementations`)
  because of a concurrent in-flight edit to
  `services/live_stacking_service.dart` by another agent. Not this batch — no
  file in this batch touches live stacking.
* `skotiq_app`: `flutter test test/screens/framing/` — 143 passed, 4 failed.
  All four are golden pixel diffs, and all four reproduce **identically at
  HEAD** with this batch's four `skotiq_core` library files reverted
  (6.54% / 81.48% / 11.30% / 0.17% — byte-identical diff percentages), i.e. the
  known Windows-captured-goldens-on-Linux class, not a regression.
* `skotiq_app`: `flutter test test/screens/equipment/ test/screens/imaging/`
  — 395 passed, 6 failed. These two directories are the ones that read
  `cameraCapabilitiesProvider`, so they are the exposure surface for the new
  connect-time store touch. All six failures are golden pixel diffs
  (`equipment_android_*` ×3, `imaging_android_*` ×2, `imaging_zfold6_*`) and all
  six reproduce at HEAD with byte-identical diff percentages
  (26.82% / 21.61% / 24.78% / 21.41% / 22.07% / 21.49%). No test broke on the
  added database access.
* `dart analyze` clean on every file touched; `dart format` applied to those
  files only.
