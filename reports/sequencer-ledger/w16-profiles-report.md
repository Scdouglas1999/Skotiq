# W16 — Equipment › Profiles: menu anchor + empty pane

Workstream `w16-profiles`, branch `agent/w16-profiles`, base `5b2235cc7`.

## 0. The screen the owner meant is NOT the one the brief pointed at

The brief orients on `packages/skotiq_app/lib/screens/settings/equipment_profiles_screen.dart`
(Settings › Equipment profiles). The owner's words were "Profiles **in Equipment**" and "the
profiles **sub tab**". Live, that is the **Equipment screen's `Profiles` tab** —
`packages/skotiq_app/lib/screens/equipment/equipment_screen.dart` (`PageHeader` tabs
`Devices | Profiles 2 | Optical train`, `equipmentTabIndexProvider`). Settings ›
Equipment profiles has no tabs and no three-dot menu on a profile row.

Both defects reproduce on the Equipment tab and neither reproduces on the Settings screen, so the
Settings screen was left alone. Evidence: `shots/08-BEFORE-profiles-tab.png` (the tab, with the
`Profiles 2` tab strip and the `+` in the list header).

## 1. Live reproduction setup

Release bundle built from this worktree; the Rust bridge is required or the app aborts at startup
(`libskotiq_bridge.so could not be loaded, or it is stale`). `native/skotiq_native/target`
is a git symlink to a shared cargo dir that this worktree materialised as a plain FILE, so cargo
could not create `target/release`; built with `CARGO_TARGET_DIR=/home/scdouglas/.cache/ns-worktrees/cargo-target`
instead of modifying the tracked entry.

    flutter build linux --release                  # EXIT=0
    cargo build --release --package skotiq_bridge   # EXIT=0 (CARGO_TARGET_DIR set)
    cp .../libskotiq_bridge.so apps/desktop/build/linux/x64/release/bundle/lib/

Harness: `SK_AUDIT_DISPLAY=:91 SK_AUDIT_RUNTIME=/tmp/ns-audit-w16 LIBGL_ALWAYS_SOFTWARE=1`,
`drive_linux.py start --profile w16`, `resize 1920 1080` (the owner's laptop size).
AT-SPI was unavailable in this session (`Could not activate remote peer org.a11y.atspi.Registry`),
so everything was driven by `shot` + `click-img`/`click-xy`.

Two profiles seeded directly into the scratch SQLite (`equipment_profiles`) because with zero
profiles the app routes to `/onboarding` instead of the shell:
`Redcat 51 + 2600MC` (active + default, 250/51 mm, 4 filters, 5 devices) and
`Esprit 100 + 2600MM` (550/100 mm, 3 filters, 4 devices).

All shots under `/tmp/ns-audit-w16/shots/`.

## 2. Defect 2 (blank negative space) — cause PROVEN, and it is none of the brief's three

The brief offered three candidates *for the Settings screen*: selection not taking effect, the
mobile branch being taken, or sections leaving a wide pane empty. **None applies.** On the real
screen the cause is that the Profiles tab has **no detail pane at all**.

`equipment_screen.dart` `_ProfilesTab.build` (before):

    return Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: _profilesColumnWidth,      // const double = 360.0
        child: ProfileSidebar(...),
      ),
    );

The tab body is a single 360 px column pinned top-left. Measured live at 1920x1080 with the nav
rail expanded (`shots/08-BEFORE-profiles-tab.png`): the list ends at image x=386 of 1280
(= 579 real px) and everything right of it is bare `colors.background` — **~1340 of 1920 px,
70% of the content area, empty**. Selection works fine (the footer's `Connect all` / `Edit profile`
track the selected card); there is simply nothing built to fill the space. Exactly the owner's
"most of the screen is blank negative space that doesn't fill with anything".

## 3. Defect 1 (menu lands mid-screen) — cause PROVEN

`profile_sidebar.dart:312 _showProfileContextMenu` (before):

    final overlay = Navigator.of(context).overlay!.context.findRenderObject() as RenderBox;
    final position = RelativeRect.fromRect(
      Rect.fromLTWH(offset.dx, offset.dy, 0, 0),     // offset is a GLOBAL coordinate
      Offset.zero & overlay.size,
    );

`offset` arrives global (from `box.localToGlobal(...)` at `:684` and `details.globalPosition` at
`:609`/`:612`), but `showMenu`'s `position` insets are measured in the **Navigator's overlay**
coordinate space. There is no conversion, so the menu is placed at
`overlayOrigin + globalAnchor` — double-counting the overlay's own origin.

The overlay origin is non-zero because of the nested Navigator: `app_router.dart:75` is a go_router
`ShellRoute`, and `app_shell.dart` puts its child inside the chrome —
`Scaffold > Column[ TitleBar, Expanded > Row[ SideNavigation, Expanded > ... > child ] , StatusBar ]`.
So the overlay's global origin is `(SideNavigation width, TitleBar height)`.

### The live experiment that proves it (and refutes the alternatives)

The `SideNavigation` width is the only term I can vary without touching anything else. Same card,
same button, two rail widths:

| | rail right edge | card right edge | menu left edge | menu − card |
|---|---|---|---|---|
| rail expanded (`shots/11-menu-try2b.png`) | 146 | 379 | **533** | 154 |
| rail collapsed (`shots/15-menu-narrowrail2.png`) | 42 | 275 | **325** | 50 |
| delta | −104 | −104 | **−208** | −104 |

(image px, 1280-wide capture of a 1920 window; x1.5 for real px)

The card moved left by exactly the rail delta (−104), as any widget in the content column must.
**The menu moved by exactly twice that (−208).** That is the arithmetic signature of
`overlayOrigin + globalAnchor`: both terms contain the rail width, so the menu moves twice when the
rail moves once.

This refutes the two alternatives outright:
* a **fixed offset / wrong anchor widget** would have moved the menu by −104, same as the card
  (predicted x=429, measured 325 — off by 104 px);
* an intervening **`Transform`/`FittedBox`** would scale the anchor, not translate it by a term
  that tracks the nav rail, and would not produce a clean 2x.

The residual `menu − card` column is the overlay origin itself: 154 image px = 231 real with the
rail at 219 real, and 50 image px = 75 real with the rail at 63 real — the overlay origin tracks
the rail width 1:1, ~12 real px of it being the content column's border/padding. Vertically the menu
sat 39 image px (58 real) below the card bottom at both rail widths, against a 42 real px `TitleBar`
— i.e. the y term is the TitleBar height and does not move with the rail. Both axes behave exactly
as `overlayOrigin + globalAnchor` predicts.

So: the brief's **candidate (1), the nested `ShellRoute` Navigator, is the cause** — with one
refinement that matters for the fix. It is *not* that `localToGlobal(ancestor: overlay)` returns
garbage (the overlay *is* a proper ancestor here); it is that this call site never converts to
overlay space at all. The conversion is missing, not broken.

### Second, smaller anchor defect at the same call site

`profile_sidebar.dart:684` computes the origin from `context.findRenderObject()`, where `context`
is the **card's** build context, not the button's — so even in the right coordinate space the menu
would anchor on the card's bottom-right corner rather than on the three-dot button at the card's
top-right. Fixed together with the space conversion.

## 4. Blast radius of the menu-anchor cause

`showMenu` is called from 11 places. Flutter's own `PopupMenuButton` and `DropdownButton` do the
overlay conversion internally, so only the HAND-ROLLED `showMenu` call sites can carry this bug.
Audited every one:

**Correct — converts with `localToGlobal(..., ancestor: overlay)`:**
* `equipment_screen/layout_rail.dart:319` (the status rail's profile menu)
* `equipment/widgets/connected_device_card/actions_and_telemetry.dart:818`
* `equipment/widgets/discovery_panel/device_row_item.dart:423`
* `shell/widgets/shell_help_popover.dart:63`
* `analytics/widgets/image_thumbnail_strip_parts/_thumbnail.dart:510` (`_menuPosition`)

**Same defect — a GLOBAL coordinate used as if it were overlay-local, all under the ShellRoute:**
* `equipment/widgets/profile_sidebar.dart:327` — the owner's report. **FIXED here.**
* `planetarium/planetarium_screen/sheets.dart:105` — `_showContextMenu(context, position)` builds
  `RelativeRect.fromLTRB(position.dx, position.dy, overlay.size.width - position.dx, ...)` from a
  global pointer position. `/planetarium` is a ShellRoute route, so its right-click menu is
  displaced by the same `(rail width, title-bar height)`.
* `sequencer/widgets/sequence_tree_context_menu.dart:102` and `:367` — both build
  `Rect.fromLTWH(position.dx, position.dy, 1, 1)` from a global pointer position; the comment at
  `:99` even says "RelativeRect from the global pointer position so the menu opens exactly under
  the cursor", which is precisely what it does not do under this shell. Two menus: the node menu
  and the fold menu.

**Latent, not currently visible:**
* `widgets/transient_alert_badge.dart:100` — uses `renderBox.localToGlobal(Offset.zero)` with no
  `ancestor:`. It is mounted in `shell/widgets/title_bar.dart:284`, i.e. OUTSIDE the nested
  navigator, so `Overlay.of(context)` there resolves to the ROOT overlay at (0,0) and global ==
  overlay-local. It renders correctly today and breaks the moment the badge moves under the shell
  child. Left alone: changing it is a title-bar change with no live defect behind it.

**Explicitly checked and NOT affected (the brief asked):**
* `SkotiqDropdown` (`skotiq_ui/lib/src/components/skotiq_dropdown.dart:112`) —
  `field.localToGlobal(Offset.zero, ancestor: overlay) & field.size`. Correct.
* `PopupMenuButton` under Settings — `settings/equipment_profiles_screen_parts/profile_details_rendering.dart:85`
  (the Settings profile pane's three-dot), `settings/pairing_screen.dart:419`, and
  `skotiq_ui/.../phd2/guide_graph_advanced.dart:310`. Flutter's implementation converts with
  `ancestor: overlay`, and the overlay IS an ancestor of the button under this shell, so these are
  correct. **Verified live**, not just read: `shots/20-settings-menu2.png` shows the Settings
  profile menu opening on its button (button at image (1245,105), menu spanning x 1186-1258,
  y 96-238), correctly clamped to the right window edge.

So the nested `ShellRoute` navigator is the shared cause, but it only bites where a call site
forgets the conversion. **Four menus besides this one are still wrong** (planetarium context menu,
sequencer node menu, sequencer fold menu — the latter two in one file). They are outside this
workstream's files and belong to other screens; the reviewer should route them.

## 5. What changed

`packages/skotiq_app/lib/screens/equipment/widgets/profile_sidebar.dart`
* `_showProfileContextMenu` takes a `Rect globalAnchor` and converts it with
  `overlay.globalToLocal(...)` before building the `RelativeRect`. Fixed at the cause: the
  conversion works for any overlay origin and for an intervening transform, rather than subtracting
  a measured constant.
* The overflow button is wrapped in a `Builder` so the anchor is the BUTTON's render object and the
  menu hangs off the control that opened it, not off a corner of the card.
* The null-fallback in the old anchor maths is gone. A just-pressed button is laid out; a fallback
  offset there is how a menu ships in the wrong place instead of failing.
* Right-click / long-press pass `details.globalPosition & Size.zero` — a point, in the same space.

`packages/skotiq_app/lib/screens/equipment/dialogs/profile_editor_dialog.dart`
* New `ProfileEditorMode.profilePage`: the whole editor as a page, no dialog chrome, no
  `Navigator.pop` (`_closeAfterSave` already handled `mode != full`), footer = Save alone
  (`_footerActions` already gated Cancel on `full`). Form column capped at
  `profilePageMaxWidth = 1200`, left-aligned.
* Reuses the existing, tested editor rather than a new read-only inspector, so create/import/
  export/duplicate/delete/set-active/set-default/edit/save and the validation and error paths are
  untouched.

`packages/skotiq_app/lib/screens/equipment/equipment_screen.dart`
* `_ProfilesTab` is now a `ConsumerWidget` with a `LayoutBuilder`: 360 px list + `Expanded`
  inspector above `_profilesTwoPaneMinWidth` (360 + 520), single column below it and when there are
  no profiles.
* `_ProfileInspector` holds the editor keyed on profile id, inside an `AnimatedSwitcher` at
  `animationDuration(context, SkotiqTokens.durationQuick)` / `curveStandard` — a cross-fade,
  top-left aligned so the incoming form's heading does not slide, and zero-duration under
  `MediaQuery.disableAnimations` via the shared helper.
* `_NoProfileSelected` covers "profiles exist, none selected" only. With no profiles the tab is ONE
  column so the list's existing empty state does the inviting — splitting there would have put two
  "No profiles yet" empty states side by side, each offering to create one.

## 6. Tests

`test/screens/equipment/profile_sidebar_menu_anchor_test.dart` (new, 5 cases) — mounts the sidebar
inside a NESTED `Navigator` inset from the window, the way `AppShell` mounts a routed screen.
Parameterised over insets 0/64/220 plus a case asserting the button-to-menu offset does not change
with the inset, plus the right-click path.

Proof it catches the defect: with `_showProfileContextMenu` reverted to the pre-fix maths the suite
fails 4/5 and the printed numbers are the theory exactly — "it is 64.0 px off" at inset 64,
"220.0 px off" at inset 220, drift `got [0.0, 220.0]`. The inset-0 case passes on the broken code,
which is why no existing test caught this: mounted at the window origin the two are identical.

One harness trap worth recording: the route hands its child TIGHT constraints, so a bare
`SizedBox(width: 360)` was widened to the whole window, put the button at the right edge, and the
menu was clamped back on screen — which HID the misplacement in one case. The sidebar is wrapped in
`Align` for that reason. Also, the card's `onDoubleTap` recognizer holds the gesture arena 300 ms,
so `pumpAndSettle` alone never delivers the tap (`_tapMenuButton` pumps 400 ms).

`test/screens/equipment/profiles_tab_inspector_test.dart` (new, 4 cases) — the pane exists and takes
the majority of a 1920 px window with its left edge at the list's right edge; clicking the other
profile swaps the pane (asserted on the editor's id key and its `profile.name`, not on copy that
appears in both columns); no profiles gives one full-width invitation and exactly one "No profiles
yet"; below the two-pane width the tab stays a single column with no exception.

## 7. Live after-evidence (same app, same window size, same route as the before shots)

Rebuilt bundle, freshness confirmed by `strings lib/libapp.so | grep -c "Pick a profile"` = 2.

| | before | after |
|---|---|---|
| Profiles tab at 1920x1080 | `shots/08-BEFORE-profiles-tab.png` — 360 px list, ~1340 px bare background | `shots/36-AFTER-profiles-tab.png` — list + editor filling to the window edge: Profile identity, Optical train (250/51 mm, derived **f/4.9**), Devices with driver ids, Save changes |
| three-dot menu, rail expanded | `shots/09..11-menu-try2b.png` — button image (361,137), menu at (533,224) | `shots/37-AFTER-menu.png` — button (361,137), menu at (353,133): on the button |
| narrow, 1100x800 | — | `shots/38-AFTER-narrow.png` two panes, no overflow; `shots/39-AFTER-menu-narrow.png` menu on the lower card's button (button (543,320), menu (524,313)), fully on screen |
| selection | pane did not exist | `shots/40-AFTER-select-second.png` — clicking Esprit 100 swaps the pane: Sky-Watcher Esprit 100ED, 550/100 mm, **f/5.5 recomputed**, Default toggle off, footer gains "Use this profile" |

Softpipe note: the app died twice with "Timed out waiting for OpenGL frame of size 1920x1080 (have
1600x900)" while other agents' builds loaded the machine. It survives with ~25 s of settle before
and after the resize; the after-shots above are all at a confirmed `1920x1080+0+0`.

## 8. Verification commands and exit codes

    flutter build linux --release                                        EXIT=0
    cargo build --release --package skotiq_bridge                    EXIT=0
      (CARGO_TARGET_DIR=/home/scdouglas/.cache/ns-worktrees/cargo-target)
    dart format --output=none --set-exit-if-changed packages/skotiq_app   EXIT=0  (0 changed)
    dart analyze  (in packages/skotiq_app)                           EXIT=0
      873 issues: ALL `info`, 0 error, 0 warning. All pre-existing
      `deprecated_member_use` from the Flutter 3.44 / pinned-CI drift; NONE in a file I touched.
    flutter test test/screens/equipment --concurrency=4                  EXIT=0  (+173)
    flutter test test/screens/settings  --concurrency=4                  EXIT=0  (+615)
    flutter test test/screens/mobile_tap_target_test.dart --concurrency=4 EXIT=0  (+24)
    flutter test test/golden/public_screenshots_test.dart --concurrency=4 EXIT=0  (+1)

The last two are the only tests outside those dirs that touch `EquipmentScreen`,
`ProfileEditorDialog` or `ProfileSidebar`. NOTE: `public_screenshots_test.dart` REWRITES
`assets/screenshots/*.png` as a side effect of passing. Those 12 files were reverted with
`git checkout -- assets/screenshots/` — the brief forbids modifying golden PNGs, and the committed
tree carries none of them. Anyone running that test locally should expect the same and revert.

`dart analyze` needed `flutter pub get` in the package first; without a resolved
`.dart_tool/package_config.json` it reports every Flutter import as `uri_does_not_exist`
(179,435 bogus issues).

## 9. Left undone, deliberately

* **The four other mispositioned menus** (planetarium context menu, sequencer node + fold menus)
  are the same cause in files this workstream does not own. Documented in §4 for routing, not
  touched.
* **`transient_alert_badge.dart`** is latent-only (root overlay, correct today). Not touched.
* **Settings > Equipment profiles** was left completely alone: verified live that its pane fills,
  auto-selects the active profile and anchors its menu correctly (`shots/18`, `shots/20`). The
  brief's three candidate causes were all for that screen and none of them is the owner's defect.
* **On-sky / owner-hardware validation** is owed as always; this was verified on the Linux release
  bundle under Xvfb, not on the imaging laptop.
* **`native/skotiq_native/target`** is committed as a symlink but materialised in this worktree
  as a plain text file holding the shared cargo path, which breaks a bare `cargo build`. Worked
  around with `CARGO_TARGET_DIR`; the tracked entry was NOT modified, so the tree stays clean. Worth
  a look by whoever owns worktree creation.

---

# Extension: the four other mispositioned `showMenu` sites

Scope extended by the coordinator after w16 was green-lit. Same branch, same
worktree. All four sites named in §4 addressed.

## 10. Census — every place a `showMenu` `position` is built

Eleven sites, not nine. Flutter's own `PopupMenuButton` and `DropdownButton` convert internally, so
only hand-rolled `showMenu` calls can carry this defect.

| # | Site | Before | Now |
|---|---|---|---|
| 1 | `equipment/widgets/profile_sidebar.dart` | BUGGY (w16) | helper, over the button |
| 2 | `sequencer/widgets/sequence_tree_context_menu.dart:102` (node menu) | **BUGGY** | helper, at the cursor |
| 3 | `sequencer/widgets/sequence_tree_context_menu.dart:367` (fold menu) | **BUGGY** | helper, at the cursor |
| 4 | `planetarium/planetarium_screen/sheets.dart:105` (3 call sites feed it) | **BUGGY** | helper, at the cursor |
| 5 | `equipment_screen/layout_rail.dart:319` | correct | helper, below the button |
| 6 | `equipment/widgets/connected_device_card/actions_and_telemetry.dart:818` | correct | helper, below |
| 7 | `equipment/widgets/discovery_panel/device_row_item.dart:423` | correct | helper, below |
| 8 | `sequencer/widgets/sequence_toolbar/actions_and_estimate.dart:97` | correct | helper, below |
| 9 | `shell/widgets/shell_help_popover.dart:63` | correct | helper, right-aligned rect |
| 10 | `analytics/.../image_thumbnail_strip_parts/_thumbnail.dart:510` | correct | helper, 40x40 anchor |
| 11 | `widgets/transient_alert_badge.dart:100` | latent-correct | **left as-is, documented** |

## 11. The shared helper — yes, and why

`packages/skotiq_ui/lib/src/utils/menu_position.dart`, exported from the barrel:

    RelativeRect menuPositionFromRect(BuildContext, Rect globalAnchor)   // core
    RelativeRect menuPositionFromPoint(BuildContext, Offset globalPoint) // cursor
    RelativeRect menuPositionFromWidget(BuildContext anchorContext)      // over the control
    RelativeRect menuPositionBelowWidget(BuildContext anchorContext)     // below the control

This defect class earns a helper on every count: eleven sites, four of them wrong, all doing the
same conversion, and the failure is **silent** — the menu appears, it works, it is merely in the
wrong place, and it looks right in any test that mounts the widget at the window origin.

The split of responsibility is the point. The helper owns only the **coordinate space** — the thing
that kept being got wrong. Each call site keeps its own **anchor geometry** — at the cursor, over
the control, below it, right-aligned — because those legitimately differ and centralising them
would have forced a flag-per-caller API. `globalToLocal` is used rather than subtracting the
overlay's origin so a transform between overlay and screen stays correct too.

`menuPositionBelowWidget` exists because four sites independently wanted "drop below this control"
and each had written the same four-line `localToGlobal(Offset(0, height))` pair.

### Migration equivalence

The migration is behaviour-preserving, verified per site by arithmetic, not by hope:

* Sites 5-8 built `RelativeRect.fromLTRB(left, bottom, W - right, H - bottom)` from the button's
  bottom edge — which is exactly `RelativeRect.fromRect(Rect.fromLTRB(l, b, r, b), overlay)`.
  Identical.
* Sites 8 and 9 used `bottom: 0` where the helper computes `H - top`. `_PopupMenuRouteLayout` never
  reads `position.bottom` — it takes `y` from `position.top` and chooses the horizontal side from
  `left` vs `right` — so this is inert.
* Site 9 (help popover) keeps its right-alignment by passing a menu-wide anchor rect that *ends* at
  the button's trailing edge, so `left`/`top`/`right` come out unchanged.
* Site 10 keeps its deliberate 40x40 anchor (a frame tile is wide; anchoring on the whole tile
  would let the menu right-align off the far edge of it), now a named constant.

### Site 11, `transient_alert_badge` — chose NOT to migrate, and why

It is built by `TitleBar`, which sits in the shell `Column` **above** the `ShellRoute` Navigator, so
`showMenu` resolves the ROOT navigator whose overlay is the whole window at (0, 0): global
coordinates already *are* overlay-local there, and it renders correctly today.

Migrating is **not** free, which is the test the coordinator set. Its `right` argument is
`offset.dx + size.width` — the button's right edge treated as if it were a distance from the
window's right edge, which is incoherent but happens to keep `left < right` and so left-aligns the
menu. The helper computes the real inset, which makes `left > right` for a badge near the right of
the title bar and flips the menu to right-alignment. That is arguably better, but it is a visible
change to the title bar with no live defect behind it, so the correct call was to leave it.

It now carries a comment naming the assumption it depends on — that the badge stays outside the
ShellRoute navigator — and saying to switch to `menuPositionBelowWidget` if it ever moves under the
shell's routed content.

## 12. Live before/after — 1920x1080, nav rail expanded AND collapsed

The nav rail width is the term that exposes the double-add, so every measurement is taken at both
rail widths. Right-click driven with `xdotool ... click 3` on the isolated Xvfb display `:91`
(never `:0`); the harness has no secondary-click verb.

**Sequencer node menu** (Take Exposures row, image px of a 1280-wide capture of the 1920 window):

| | cursor | menu top-left | displacement |
|---|---|---|---|
| BEFORE, rail expanded (`shots/53`) | (408, 158) | (555, 190) | **(147, 32)** |
| BEFORE, rail collapsed (`shots/55`) | (303, 158) | (346, 190) | **(43, 32)** |
| AFTER, rail expanded (`shots/71`) | (408, 158) | (409, 161) | (1, 3) |
| AFTER, rail collapsed (`shots/72`) | (303, 158) | (304, 161) | (1, 3) |

The before-displacement's x term changed by exactly 104 px — the rail's own width change (146 → 42)
— while its y term stayed at 32, the title-bar height. After, the displacement is the same in both
rail states, which is the property that was broken.

**Planetarium sky menu** — the cleanest case, because the cursor is held at the *same global point*
while only the rail changes:

| | cursor | menu top-left |
|---|---|---|
| BEFORE, rail collapsed (`shots/64`) | (660, 300) | (554, 331) — LEFT of the cursor |
| BEFORE, rail expanded (`shots/65`) | (660, 300) | (658, 331) — moved **104 px** |
| AFTER, rail collapsed (`shots/75`) | (660, 300) | (661, 302) |
| AFTER, rail expanded (`shots/76`) | (660, 300) | (661, 302) — **unchanged** |

Before, the menu moved 104 px with nothing but the nav rail changing, and sat left of the cursor
because the bogus right inset flipped `_PopupMenuRouteLayout` into right-alignment. After, it is
invariant to the shell chrome.

**Gestures.** Right-click verified live for both screens at both rail widths, above. The fold-group
menu and the long-press path are covered by widget tests; a synthetic long-press via
`xdotool mousedown / sleep 0.9 / mouseup` on the desktop bundle did **not** open the node menu —
the row's own drag/hover affordances take that gesture there — so long-press is NOT claimed as
live-verified, only test-verified. **There is no keyboard path to either context menu**: both are
`GestureDetector(onSecondaryTapUp / onLongPressStart)` with no `Shortcuts`/`Actions` entry and no
context-menu key handler, so there was nothing to check. Worth noting as an accessibility gap, but
it is not this workstream's defect.

## 13. Tests

`packages/skotiq_ui/test/menu_position_test.dart` (new, 8 cases) — the numeric guard on the one
implementation. A nested `Navigator` inset by 0 / 64 / 220 px, covering all three public entry
points plus a drift case asserting the anchor offset does not track the inset. With the
`globalToLocal` conversion removed from the helper it fails **5/8**, each failure reporting a
displacement exactly equal to the inset, and the drift case printing
`[Offset(0.0, 8.0), Offset(220.0, 228.0)]`.

`packages/skotiq_app/test/screens/sequencer/sequence_tree_context_menu_anchor_test.dart`
(new, 7 cases) — the node menu at insets 0/64/220, long-press, the anchor-drift case, and the
**fold-group menu** at insets 0/220. On the pre-fix maths it fails **5/7**: "it is 64.0 px off
horizontally" at inset 64, "220.0 px off" at inset 220, drift `got [0.0, 220.0]`. The inset-0 cases
pass on the broken code, which is exactly why the existing
`sequence_tree_context_menu_test.dart` — which mounts at the window origin — never caught it.

Two harness traps recorded in the test files: the menus are typed on private enums
(`_TreeMenuAction`, `_FoldMenuAction`) so `find.byType` cannot name them and a
`byWidgetPredicate((w) => w is PopupMenuItem)` is required; and the drift case must
`pumpWidget(SizedBox.shrink())` between iterations, because at inset 0 a "tap outside" lands on the
row itself and re-pumping over a still-animating popup route leaves nothing to measure.

No widget test mounts the planetarium screen. Its own test file documents why — ~30 providers and a
GPU sky renderer that loads shaders from disk — and the one line it now calls is covered
numerically in `skotiq_ui` and verified live above.

## 14. Verification — extension

    dart format --output=none --set-exit-if-changed packages/skotiq_app   EXIT=0
    dart format --output=none --set-exit-if-changed packages/skotiq_ui    EXIT=0
    dart analyze  (packages/skotiq_app)                                  EXIT=0  873 issues
      Exactly the 873-issue baseline the coordinator measured on `5b2235cc7`. All `info`
      (`deprecated_member_use` from the Flutter 3.44 / pinned-CI drift); 0 error, 0 warning,
      none in a file touched here.
    dart analyze  (packages/skotiq_ui)                                   EXIT=0  59 issues
      All `info`; 0 error, 0 warning.
    flutter test test/screens/sequencer   --concurrency=4                    EXIT=0  (+771)
    flutter test test/screens/planetarium --concurrency=4                    EXIT=0  (+156)
    flutter test test/screens/equipment   --concurrency=4                    EXIT=0  (+173)
    flutter test test/screens/shell       --concurrency=4                    EXIT=0  (+105)
    flutter test test/screens/analytics   --concurrency=4                    EXIT=0  (+274)
    flutter test test/widgets             --concurrency=4                    EXIT=0  (+311)
    flutter test  (all of packages/skotiq_ui)                            EXIT=0  (+538)
    flutter build linux --release                                            EXIT=0

Bundle freshness for the live check was confirmed by mtime rather than a string grep — this change
adds no user-facing strings: `libapp.so` 10:57:28 against the newest edited source at 10:55:29.

## 15. Two pre-existing defects to record (NOT fixed, as instructed)

### 15a. Two test files rewrite tracked assets on a PASSING run

A test that mutates version-controlled files as a side effect of passing. Both were hit in this
workstream and both had to be reverted by hand before committing; a run on CI or on a dirty tree
will show them as spurious modifications, and a careless `git add -A` commits regenerated binaries
nobody reviewed.

* `packages/skotiq_app/test/golden/public_screenshots_test.dart` — a passing run rewrites
  **12 files** in `assets/screenshots/`: `analytics.png`, `desktop-dashboard.png`, `equipment.png`,
  `flat-wizard.png`, `framing.png`, `guiding.png`, `imaging.png`, `plan-tonight.png`,
  `planetarium.png`, `sequencer.png`, `settings-equipment-profiles.png`, `weather.png`.
* `packages/skotiq_ui/test/golden/design_gallery_golden_test.dart` — a passing run rewrites
  **6 files** in `docs/design/goldens/`: `gallery-dark.png`, `gallery-light.png`,
  `gallery-rednight.png`, `gallery-observatory-dark.png`, `gallery-observatory-light.png`,
  `gallery-observatory-rednight.png`.

Reverted here with `git checkout -- assets/screenshots/` and `git checkout -- docs/design/goldens/`;
neither is in any commit on this branch. Note this also means the repo's committed screenshots
differ from what the current code renders on Linux — the same host-dependence the project already
knows about for Windows-captured goldens — so "the test rewrote them" is not by itself evidence of
a UI regression. Whoever picks this up should decide whether these are generators that belong
behind a flag (`--dart-define` or an env guard) rather than plain tests.

### 15b. `native/skotiq_native/target` materialises as a plain file in a new worktree

It is committed as a **symlink** (git mode `120000`, blob `db097f88e9cf68a6b953fa5b3485e379ad24713f`)
pointing at the shared cargo dir `/home/scdouglas/.cache/ns-worktrees/cargo-target`. In this
worktree it was checked out as a **regular 48-byte text file** containing that path as text, so
cargo cannot create `target/release` inside it and any bare `cargo build` in the crate dies with:

    error: failed to create directory `.../native/skotiq_native/target/release`
    Caused by: Not a directory (os error 20)

Worked around throughout by exporting
`CARGO_TARGET_DIR=/home/scdouglas/.cache/ns-worktrees/cargo-target` — the same directory the symlink
names — so the tracked entry was never modified and the tree stays clean. Two consequences for
whoever owns worktree creation: a fresh agent worktree cannot build the Rust bridge without knowing
this, and because the bridge is required at startup (`libskotiq_bridge.so could not be loaded,
or it is stale`) that blocks every live verification. Likely `core.symlinks=false` or a
symlink-less checkout in whatever creates these worktrees.
