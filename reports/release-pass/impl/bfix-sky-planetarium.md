# bfix batch: sky-planetarium

Cluster report: `reports/release-pass/gui/sky-discovery.md`
Scope: `packages/skotiq_planetarium/**`,
`packages/skotiq_app/lib/screens/{planetarium,your_sky,framing,first_light}/**`

## SKY-2 (P0) — region-create modal never lifts — FIXED

Root cause found and proved, not guessed. `NameRegionSheet` wrapped itself in
`PopScope(canPop: !_saving)` and then closed itself with
`Navigator.maybePop(true)` — the one navigator API that asks the route's
`PopScope` entries for permission. Once `_saving` had been painted (i.e. any
write that outlives the frame that started it — every real one), the sheet was
asking a barrier it had raised itself to let it out, and was refused. Cancel was
additionally `onPressed: null` while saving, and Escape / barrier-tap route
through `maybePop` too, so every exit was closed at once while the write itself
had already committed.

Timing detail that makes the test non-obvious: a mock write that completes in
the same frame as the tap pops *before* `canPop: false` is ever built, so a
naive widget test passes against the broken code. The regression test gates the
write on a `Completer` and pumps a frame first — that is what reproduces.

Fix: no `PopScope`; Cancel always enabled; success path uses `pop(true)`.

Test: `packages/skotiq_app/test/screens/your_sky/name_region_sheet_dismissal_test.dart`
(3 cases: gated write closes; Escape mid-write; Cancel mid-write). Full
`test/screens/your_sky/` green (39 tests).

## SKY-4 (P2) — FALSE POSITIVE at HEAD

`Create region` with no target selected is already blocked at HEAD
(`_canSubmit` gates `onPressed`), and
`name_region_sheet_validation_test.dart::Create region is not offered when there
is no target to pick` asserts exactly that and passes unchanged. The audited
binary predates that fix. The a11y half (a disabled button not reported
`[DISABLED]`) is the A11Y-STATE class, owned at the `skotiq_ui` component.

## SKY-15 (P3) — Escape does not leave the region detail — FIXED

`CallbackShortcuts` + `FocusScope(autofocus: true)` around the region-detail
scaffold, matching the fullscreen image viewer's fix for the same shape (and
its FocusScope-not-Focus lesson). Test:
`test/screens/your_sky/region_detail_escape_test.dart`; proved failing by
retargeting the binding at F13 and re-running.

## SKY-1 (P1) — pause does not pause — FIXED

The tick advances simulated time by `speedMultiplier` seconds whenever the wall
clock is not being followed, and the transport's pause only cleared
`isRealTime`, leaving the multiplier at 1.0 — so "paused" ran at exactly 1x,
which is what the live 112 s measurement showed.

Fix: `ObservationTimeState.isPaused` (`!isRealTime && speedMultiplier == 0`),
`ObservationTimeNotifier.pause()`, and a transport that toggles on that state,
remembers whether to resume the wall clock or the previous rate, and — the
STOP-ACK half — labels the held state `PAUSED` instead of `1×`.

Deliberately NOT changed: `setTime` still leaves the clock running at 1x from
the new instant. Freezing it there broke
`object_details_visibility_memo_test.dart`, whose documented contract is that a
`setTime` clock advances a second per tick; TONIGHT/date-picker drift is not a
filed finding and relocating that behaviour is not this fix's job.

Test: `packages/skotiq_planetarium/test/time_transport_pause_test.dart`.

## SKY-5 (P1) — the planetarium clock rewrote the Dashboard's — FIXED

New `SimulatedTimeScope` (skotiq_planetarium) wraps `PlanetariumView`: when
the planetarium leaves the tree the observation clock returns to now, so the
Dashboard header, astro-dark countdown and moon phase can no longer inherit a
simulated instant. Deferred through a microtask — dispose runs inside the frame
tearing the subtree down, and notifying the clock's listeners there would mark
them dirty mid-build.

Scope note: the whole derived-astronomy stack (twilight / moon / LST /
sun-altitude) is keyed on `observationTimeProvider`, and its dashboard and
status-bar consumers are outside this batch's paths, so the fix is at the
boundary rather than by splitting the provider. While the planetarium is on
screen the shell's LST chip still shows the simulated value.

Test: `packages/skotiq_planetarium/test/simulated_time_scope_test.dart`;
proved failing by disabling the reset.

## SKY-6 (P1) — DSOs render with no angular size — FIXED

The draw size was `sizeArcMin/60 * scale` clamped to a 40 px ceiling, so every
extended object collapsed to the same marker. Measured at HEAD by the new test:
a 60' x 20' galaxy rendered 16 px of ink at a 20 degree field AND 16 px at a
2 degree field — a 10x zoom that changed nothing.

Fix: objects whose major axis exceeds `_extendedDsoMinPx` (24 px) leave the
batched glyph atlas — which can only place a square sprite under a uniform
scale — and draw as a soft-bodied, thin-edged ellipse on their catalogued
major/minor axes at their position angle. Everything smaller keeps the atlas
path and its legible-minimum floor. Only a handful of objects clear the
threshold in any one field.

Test: `packages/skotiq_planetarium/test/dso_angular_size_test.dart`.
Full planetarium suite green (538 tests, `--exclude-tags golden`; the golden
benchmark baseline is host-specific and excluded from `melos run test` by tag).

## SKY-3 (P2) — Your Sky asked for RA in degrees — FIXED

The field was `RA (degrees)`, hint `0–360`, digits-only, while Framing prints
`05h 35m 16s`, the planetarium readout `0h 42m 44s`, and Framing's own RA box
takes sexagesimal. Now both coordinate fields go through
`CoordinateParser.parseRa` / `parseDec` — the app's one RA/Dec reader, shared
with Framing and the mount slew box — so `05h 35m 16s`, `5.588`, `83.82` and
`83.82°` mean here what they mean everywhere else, and a caption under the
fields echoes the interpreted position in both conventions as you type.

`name_region_sheet_validation_test.dart` was updated for the new range message
(its assertions on error lifecycle are unchanged). Test:
`test/screens/your_sky/name_region_sheet_ra_units_test.dart`.

## SKY-7 (P2) — two search result lists at once — FIXED

`SearchHeader` opens its own typeahead overlay while the panel it sits above
renders the same results in its Search tab: two lists, the front one clipped
mid-row, both in the accessibility tree. New `showResultSuggestions` flag,
passed false at all three sites that compose the header over a
`SearchResultsTab` (docked plan panel, phone sheet, legacy desktop layout). The
coordinate branch has no equivalent below it and still opens — it is the only
way to fly to a typed RA/Dec.

Test: `test/screens/planetarium/search_header_single_result_list_test.dart`;
proved failing by removing the guard.

## SKY-17 (P3) — layer toggles expose no state — FIXED (screen-local widget)

`_LayerSwitch` is this screen's own row widget, not a `skotiq_ui`
component, so it is independently wrong and fixed here rather than deferred to
the A11Y-STATE component work: `MergeSemantics` around the row, the same idiom
`SettingRow` uses. Each of the fourteen sky layers is now one node carrying its
name, its on/off state, its enabled state and its tap action.

Test: `test/screens/planetarium/layers_panel_semantics_test.dart`; proved
failing by swapping the merge for a pass-through widget.

## SKY-9 (P2) — BLOCKED (out of scope)

Framing's gate is `framingEquipmentProvider` in
`packages/skotiq_core/lib/src/providers/framing_provider/support.dart`: it
only fills sensor dimensions from `backend.getCameraStatus` while the camera is
`connected`, and returns `EquipmentStatus.noCameraSpecs` otherwise. Closing it
needs (1) sensor pixel dimensions on `EquipmentProfile` — a freezed model plus
a drift table and migration, i.e. regenerated `*.freezed.dart` / `*.g.dart` /
`database.g.dart`; (2) the onboarding optical-train step to ask for them (it
already asks for pixel size and computes 1.46"/px); (3) that provider to prefer
the live camera and fall back to the profile. All three are outside
`screens/{planetarium,your_sky,framing,first_light}` and the generated-file ban.
No code changed for this item.

## SKY-8 (P2) — BLOCKED (out of scope)

Both halves live in the shared component
`packages/skotiq_ui/lib/src/components/skotiq_tooltip.dart`: the anchor
maths in `_TooltipOverlay` / `_TooltipLayoutDelegate` (the Layers tooltip drew
176 px right and 79 px below its button) and the lifecycle — each
`SkotiqTooltip` owns an independent `OverlayPortalController` dismissed only
by its own `MouseRegion.onExit`, with no arbitration that at most one is
showing, which is what leaves several alive over the star field. The planetarium
call sites pass a plain message and position; nothing is wrong on this side.
No code changed for this item.
