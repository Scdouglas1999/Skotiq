# w6-inspector-shift — the inspector tab switch moved the whole screen

Base `f1f739da1`, branch `agent/w6-inspector-shift`.

Owner's report (release build): clicking **Activity** or **Notes** in the
right-hand node inspector makes "the whole screen bounce to the left, revealing
nothing on the right".

## 1. Reproduced in the running app

Harness: `tools/ui_audit/drive_linux.py --profile w6shift`, `SK_AUDIT_DISPLAY=:92`,
profile seeded from `~/.cache/skotiq-ledger-preview/data`. App window
1600x900 at root (160,150) on a 1920x1200 virtual screen. Loaded
"NGC 7000 + M31 · full night" from Sequencer › Saved, selected the **Cool
camera** node, then clicked **Activity**.

### Settled state: nothing wrong

Raw 1920x1200 captures, column-profile cross-correlation over the palette +
canvas band (x 160-1440, y 400-1000), and the vertical border positions:

| landmark (root x) | Settings | Activity | Notes |
|---|---|---|---|
| nav rail / palette border | 379/380 | 379/380 | 379/380 |
| palette right edge (card) | 633/634 | 633/634 | 633/634 |
| inspector left border | 1470 | 1470 | 1470 |
| window right edge | 1760 | 1760 | 1760 |
| inspector width | 290 | 290 | 290 |
| measured shift of palette+tree | — | **+0 px** (corr 1.0000) | **+0 px** |

So the inspector's WIDTH is not the bug: it is 290px on every tab, and a
screenshot taken a few seconds after the click shows no displacement. A
settled-state check would have declared this fixed.

### The transient: a 29 px bounce

Recorded the window with `ffmpeg -f x11grab` at 25 fps while clicking
**Activity**, then measured each frame's horizontal shift against the
pre-click frame (`/tmp/ns-audit/frames`, softpipe renders ~5 real fps so
frames repeat):

```
frame 45 (1800 ms)  shift  +0     baseline
frame 49 (1960 ms)  shift  +0     whole body dims by 4/255
frame 54 (2160 ms)  shift +29 px  <-- content jumps LEFT
frame 59 (2360 ms)  shift +10 px
frame 64 (2560 ms)  shift  +1 px
frame 72 (2880 ms)  shift  +0 px  settled back
```

The entire screen body (nav rail excluded — it is outside the moving subtree)
slides 29 px left and springs back over ~400 ms. That is the owner's bounce.

## 2. Root cause

`AdaptiveTabBar` keeps its selected tab on screen from `didUpdateWidget`:

```dart
Scrollable.ensureVisible(keyContext, alignment: 0.5, ...);   // before
```

`Scrollable.ensureVisible` is not scoped to one scrollable. It walks **every
ancestor `Scrollable`** (`while (scrollable != null) { ... scrollable =
Scrollable.maybeOf(scrollable.context); }`) and scrolls each one so the target
is visible in it.

The sequencer's body is an `AnimatedTabBarView` → `TabBarView`
(`sequencer_screen.dart:539`), i.e. a horizontally scrolling pager holding
Builder / Templates / Saved / History. The inspector's Settings/Activity/Notes
strip is a descendant of that pager. So "keep this 60 px tab visible" asked the
PAGER to centre the tab too: it scrolled toward page 1, and `TabBarView`'s page
physics then snapped it back to page 0 — a bounce. `NeverScrollableScrollPhysics`
did not prevent it: that only refuses USER drags (`shouldAcceptUserOffset`),
never a programmatic `animateTo`.

"Revealing nothing on the right" is literal: page 1 (Templates) is behind
`_LazyTab`, which renders `SizedBox.shrink()` until first visited, so the strip
uncovered on the right is empty.

The precondition is that the strip is scrollable at all — with the real font
the three labels fit the 290 px column, but the bar's own scroll position is
still what `ensureVisible` targets, and any sub-pixel extent makes the ancestor
walk fire.

## 3. The fix

`packages/skotiq_ui/lib/src/components/adaptive_tab_bar.dart` —
`_ensureSelectedVisible` now scrolls **its own** `ScrollPosition`:

```dart
final target = keyContext.findRenderObject();
if (target == null || !target.attached) return;
_scrollController.position.ensureVisible(target, alignment: 0.5, ...);
```

`ScrollPosition.ensureVisible` resolves the nearest enclosing viewport — this
strip's — and applies the offset to this position only. The bar still keeps its
selected tab visible; no host scrollable is touched. Nothing about the panel's
width, the tab body, or the crossfade changed, because none of them was ever
the cause.

## 4. Proven after the fix

Rebuilt the release bundle in this worktree (`flutter build linux --release`,
then the campaign-hash `libskotiq_bridge.so` copied back over it —
`rustContentHash => -1858542796`), relaunched the harness on the same profile,
and repeated the identical sequence: load the night, select **Cool camera**,
click **Activity**, then **Notes**.

Same 25 fps `x11grab` recording, same per-frame cross-correlation:

| | before the fix | after the fix |
|---|---|---|
| peak shift of palette + canvas on the Activity click | **-29 px**, recovering over ~400 ms | **0 px on every one of 100 frames** |
| palette + canvas band, whole 4 s recording | 29 / 10 / 1 / 0 px | shift `+0`, corr >= 0.9991 throughout |
| pixels left of the inspector (x < 1300) during the Notes click | — | mean abs diff **0.0000** (nothing outside the inspector changed at all) |
| pixels inside the inspector during the Notes click | — | mean abs diff 1.21 (the tab body really did swap) |

Settled landmarks, post-fix, Settings vs Activity (root x):

| landmark | Settings | Activity |
|---|---|---|
| nav rail / palette border | 379/380 | 379/380 |
| palette right edge | 633/634 | 633/634 |
| inspector left border | 1470 | 1470 |
| inspector width | 290 | 290 |
| measured shift of palette+tree | — | **+0 px** (corr 1.0000) |

Tabs still behave: the Activity body shows "Nothing has run for this node yet.",
the Notes body shows the Comment editor, and all three labels stay visible and
unclipped in the 290 px column.

Evidence: `/tmp/ns-audit/frames` (before), `/tmp/ns-audit/frames2`,
`/tmp/ns-audit/frames3` (after), `/tmp/ns-audit/shots/raw-*.png`.

### Tests

- `packages/skotiq_app/test/screens/sequencer/inspector_tab_switch_layout_test.dart`
  (new, 3 cases) lays out `SequencerScreen` at 1400x900, selects an exposure
  node and switches tabs, asserting on EVERY frame of the transition that the
  `SequenceTree` Rect, the `NodePropertiesPanel` Rect and the screen pager's
  scroll offset are unchanged. Against the unfixed `AdaptiveTabBar` all three
  fail with the tree at `Rect.fromLTRB(117.6, 102.0, 953.6, 900.0)` instead of
  `Rect.fromLTRB(264.0, 102.0, 1100.0, 900.0)` — a 146.4 px lurch (larger than
  the live 29 px because the test font makes the strip overflow further and
  fake-async runs the pager animation to completion).
  - Activity is switched by a real `tap`. Notes and the return to Settings go
    through `inspectorTabProvider` (the exact state the tab button writes):
    under the test font every glyph is a square em, so the three labels measure
    ~390 px in the fixed 300 px column and the last tab's centre lands outside
    the window, where a `tap` would hit nothing and assert about a switch that
    never happened. With the real font all three fit, as the live shots show.
- `packages/skotiq_ui/test/adaptive_tab_bar_test.dart` gains
  "selecting a clipped tab does not scroll the host" — the cause-level guard:
  a bar inside a horizontally scrollable host, tap a clipped tab, host offset
  must stay 0.

### Commands (unpiped, exit codes as recorded)

```
flutter test test/screens/sequencer --concurrency=3     EXIT=0   724 passed (721 base + 3 new)
flutter test (packages/skotiq_ui, full)             EXIT=0   520 passed (519 base + 1 new)
dart analyze (packages/skotiq_app)                  EXIT=2   890 issues - the documented baseline, zero from this change
dart analyze (packages/skotiq_ui)                   EXIT=0   57 infos, zero from this change
dart format --output=none --set-exit-if-changed
  packages/skotiq_app skotiq_core skotiq_ui EXIT=0
flutter build linux --release                           EXIT=0
```

`dart analyze` exits 2 on the app package because the 890-issue baseline
contains infos; no issue in the log names either file this change touched.

## 5. Not fixed here (same defect class, other owners' files)

`Scrollable.ensureVisible` is called with the same ancestor-walking semantics in
11 other places. Two of them are inside this very pager and will bounce the
screen the same way when they fire:

- `screens/sequencer/widgets/sequence_tree.dart:335,353` (follow-execution and
  the selected-row reveal)
- `screens/sequencer/widgets/sequence_minimap.dart:127`
- `screens/sequencer/widgets/sequence_step_finder.dart:54`

They are in files parallel agents are editing, so they are reported, not
touched. The tree ones are the most likely to be seen: they fire on every
auto-follow step during a run.
