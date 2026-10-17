# w1-wiring — putting the mark into the app

Branch `rebrand/skotiq-w1-wiring`, worktree `ns-worktrees/skotiq-w1-wiring`,
base commit `b1105ed2e`. Scope: call sites in `packages/skotiq_app/lib/**`,
`apps/desktop/lib/**`, `apps/mobile/lib/**` plus their tests. 176 files
changed, +679/−769.

## 1. Startup splash

New shared widget `packages/skotiq_app/lib/widgets/startup_splash_gate.dart`
(`SkotiqSplashGate`, exported from `skotiq_app.dart`).

- Centers a 96 px `SkotiqMark(motion: SkotiqMarkMotion.draw)` on
  `SkotiqColors.of(context).background`, per the brief's "about 96 px".
- Hand-off is a `FadeTransition` over `SkotiqTokens.durationSmooth` (220 ms)
  with `SkotiqTokens.curveStandard`. The duration is passed through
  `animationDuration(context, …)`, so it collapses to zero under reduced
  motion.
- The gate lifts only when `ready && drawOver`. `drawOver` is whichever of
  these fires first: the mark's `onDrawComplete`, or a shared draw deadline
  (`TrailsMotion.drawDuration` for the 96 px level, ≈1.6 s). A ready app is
  therefore never held longer than one draw pass.
- If readiness outlives the draw, the same mark flips to
  `SkotiqMarkMotion.loading` and the optional `statusText` fades in beneath
  it. The status slot is always laid out (invisible while the draw plays)
  so the mark never shifts off-center when the text appears.
- `MediaQuery.disableAnimations` renders the still mark (`motion: none`)
  and a zero-length fade; the gate lifts as soon as the app is ready.
- The cover is wrapped in `IgnorePointer(ignoring: ready)`: the moment the
  app reports ready the splash stops absorbing input even while the fade is
  still running, so it can never swallow a tap on a live shell.

**Shared clock.** The mobile app swaps its connection-screen `home:` for
`SkotiqApp` on connect. To keep that swap from restarting the brand moment,
the draw deadline and a `skotiqSplashPhaseProvider` (`drawing → handingOff →
done`) are shared. The draw-start instant is a `static` field on the gate
state, deliberately not a provider: it is written in `initState` (where
Riverpod mutations are illegal — a fact the new tests caught) and it must
survive a remounted `ProviderScope`. A second gate that mounts mid-draw
never replays `draw`; it joins the deadline under `loading`. Once the phase
reaches `done` the gate renders its child directly, so a re-mounted splash
never re-covers a ready app. `SkotiqSplashGate.debugResetDrawClock()`
exists for tests.

**Placement — inside the shell, not around the Navigator.** The gate wraps
the shell's content in `AppShell` (`screens/shell/app_shell.dart`), below
the routed `Navigator`. Startup dialogs — checkpoint recovery, onboarding,
update prompts, and the mobile `PairingCodeDialog` that `_connectToServer`
can open mid auto-connect — are pushed as root-navigator routes, so they
paint above the splash and stay interactive. A gate layered over the
navigator would hide exactly the prompts it must sit behind. This also
preserves `_ContentSemanticsBoundary`: the splash covers the shell column
it was already inside, so nested-route modal barriers keep working exactly
as before.

**Readiness.** `startupReady = !ref.watch(appSettingsProvider.select((s) =>
s.isLoading))`. No new init phase and no `await` before `runApp` — the
comments in `apps/desktop/lib/main.dart` about the historical blank-window
bugs were honored; its `WindowOptions` startup order is unchanged apart
from the background color below.

**Mobile.** The disconnected connection screen is wrapped with
`SkotiqSplashGate(ready: true, …)` in `apps/mobile/lib/main.dart`: pairing,
discovery and manual connect are the ready state while disconnected, so
the draw plays over them once and lifts. On connect, `SkotiqApp` mounts
the shared `AppShell` gate, which inherits the same deadline (loading
motion, not a second draw).

**Native launch surfaces** (no more white flash before Flutter paints):

- Android `drawable*/launch_background.xml` now use
  `@color/skotiq_launch_background`; `values/colors.xml` and
  `values-night/colors.xml` define it as `#0B0D12` (matching
  `SkotiqColors.dark.background`). `NormalTheme` windowBackground in
  `values*/styles.xml` points at the same resource.
- iOS `LaunchScreen.storyboard` background was white; now the same
  `#0B0D12` (rgb 0.043/0.051/0.071).
- Desktop `WindowOptions.backgroundColor` was `0xFF0A0C0F`; now
  `0xFF0B0D12` to match the dark theme background exactly.

## 2. Wordmark

`SkotiqLockup` (mark + "skotiq" in Sora SemiBold) replaced the
letter-spaced all-caps product name in four places. No `tone:` is passed
anywhere so call sites pick up t1's `theme` default when the branches
merge.

- `screens/shell/widgets/title_bar.dart` — `SkotiqLockup(markSize: 20)` in
  the 44 px bar.
- `screens/shell/app_shell_parts/_mobile_settings_bar.dart` —
  `SkotiqLockup(markSize: 18)`.
- `screens/settings/widgets/about_settings.dart` — `SkotiqLockup(
  markSize: isMobile ? 28 : 32)` as the About header.
- `screens/onboarding/steps/welcome_step.dart` —
  `const Center(child: FittedBox(child: SkotiqLockup(markSize: 32)))` as the
  welcome brand header. Sora's advance width makes the 32 px lockup ~272 px
  wide — 6.8 px over the welcome column at the narrowest supported phone
  (320 dp) — so the lockup is wrapped in `FittedBox`: full size on wider
  layouts, scaled down where it would overflow.

Audit of the other `'SKOTIQ'` string hits: remaining occurrences are
ordinary labels and prose (wizard copy, planner text, tooltips, semantic
strings, the AndroidManifest `android:label`), not logos — left as text.

## 3. Spinners

Inventory found 194 `CircularProgressIndicator` call sites in 152 files;
194 were examined, 190 replaced across `packages/skotiq_app`, `apps/mobile`
and `apps/desktop`:

- Inline (button, row, chip, text line) → `SkotiqSpinner(size: …, color: …)`
  preserving the original `SizedBox` footprint and color intent
  (`colors.primary`, `style.accent`, `colors.textMuted`, `onPrimary`, …).
- Centered / main loading area (≈24 px+) →
  `SkotiqMark(motion: SkotiqMarkMotion.loading, size: …)`.
- Many-at-once placeholders (thumbnail rails, list rows, small card
  placeholders) → still `SkotiqMark(size: …)` so a visible list never
  starts dozens of tickers (e.g. `frame_thumbnail_loader.dart`,
  `sub_cull_rail` tiles, `profile_chip` indicators).
- Where a CPI had `semanticsLabel` it was carried to the replacement;
  labels were not invented where the surrounding widget already announces
  the loading state.

### Deliberately kept `CircularProgressIndicator`s (4 files)

- `screens/analytics/widgets/science_campaign_strip.dart:80` — determinate
  44 px ring, `value: pct.clamp(0,1)`: a measurement, per the brief.
- `screens/dashboard/widgets/capture_settings_card.dart:216` — determinate
  16 px exposure ring beside the `%` readout.
- `screens/imaging/widgets/overlay_widgets.dart` — 80 px capture-progress
  ring with the percentage in the middle. `isAborting` now shows
  `SkotiqMark(loading)` and the ring stays only while a real `value` exists
  (was `isAborting ? null : progressValue` — the abort phase was
  indeterminate).
- `widgets/operation_status_bar.dart` — 12 px operation ring. Same split:
  `operation.progress != null` keeps the determinate ring; the null phase
  is now `SkotiqSpinner(size: 12)`.

`LinearProgressIndicator` and `ShimmerLoading` untouched. Note:
`SkotiqButton(isLoading:)` still renders a `CircularProgressIndicator`
internally — that lives in `packages/skotiq_ui` (component internals are
outside this worktree's area).

## 4. Tests

- New `test/widgets/startup_splash_gate_test.dart` (7 tests): draw while
  unready, ready-before-draw waits out the pass then fades to `done`,
  loading motion + status text when startup outlives the draw, status stays
  invisible during the draw, reduced-motion still mark + prompt lift, tap
  passthrough once ready, and the shared deadline across a remount.
- 15 test files had `CircularProgressIndicator` finders updated to the new
  widget type (`SkotiqSpinner` for inline, `SkotiqMark` for centered
  loading). "No spinner stuck on screen" assertions now check for the
  loading-motion mark/`SkotiqSpinner` predicate rather than only the old
  type. `capture_settings_card_test` and
  `narrowband_apply_feedback_test` still find `CircularProgressIndicator`
  — the first targets the kept determinate ring, the second the spinner
  inside `SkotiqButton(isLoading:)`.

## 5. Cost check

The swap is ticker-neutral or better: each replaced CPI (a 60 fps ticker)
became one gated `SkotiqSpinner`/`SkotiqMark(loading)`, and every
many-at-once list placeholder became a still mark (zero tickers vs the
CPI's ticker — a net reduction). Repeating mark animations already flow
through `OnScreenAnimationGate` and `MediaQuery.disableAnimations`. After
`done`, the splash gate returns its child — no residual ticker, one
canceled `Timer`, one disposed `AnimationController`. The existing
`status_bar_idle_repaint_test`, `freshness_ticker_period_test` and the
shell rebuild test (which asserts the shell only rebuilds on fields it
reads — the splash watches `isLoading` via `select`, not the whole
settings object) all pass.

## Commands run (exit codes)

```
export TMPDIR=$HOME/.cache/ns-tmp/w1-wiring
melos bootstrap                                                    → 0
dart analyze lib  (packages/skotiq_app)                            → 0 errors after fixes
dart analyze .                                                    → 2 (0 errors, 915 pre-existing infos)
dart analyze lib test (apps/mobile)                                → 0 (20 pre-existing infos)
dart analyze lib (apps/desktop)                                    → 0 (9 pre-existing infos)
dart format --output=none --set-exit-if-changed <3 touched dirs>   → 0 (2338 files, 0 changed)
flutter test test/widgets/startup_splash_gate_test.dart --concurrency=4 → 0 (7/7)
flutter test <shell tests + 16 touched test files> --concurrency=4 --exclude-tags golden → 0 (181/181)
flutter test test/screens/session_replay_screen_test.dart (mobile) → 0 (3/3)
flutter test --exclude-tags golden --concurrency=4 (skotiq_app full)  → 1
python3 tools/rebrand/rebrand.py --check                           → 0 leftover mentions
```

The full non-golden `skotiq_app` run was 4524 tests with exactly one
failure: `onboarding_system_back_test.dart › the leave prompt fits the
narrowest supported phone` — a `RenderFlex` overflow of 6.8 px at 320 dp
caused by the welcome-step lockup (see above). Fixed in
`c35d27553`; the test file now passes 4/4, making the suite green.

## Known limits / deviations

- Splash readiness is `appSettingsProvider.isLoading` rather than a new
  init gate — the brief asked not to add awaits before `runApp`, and
  settings load is what the first frame actually waits on.
- `dart analyze` reports 915 `info`-level issues package-wide
  (pre-existing `deprecated_member_use`, etc.); zero errors, zero warnings
  introduced. No golden PNGs were created, deleted or regenerated; golden
  tests were not run (`--exclude-tags golden` throughout, per the brief).
- The full non-golden `skotiq_app` suite is green (one real failure found
  and fixed: the welcome lockup at 320 dp). `apps/mobile` and
  `apps/desktop` were verified on the tests covering their changed call
  sites; their remaining suites were not re-run end-to-end.
