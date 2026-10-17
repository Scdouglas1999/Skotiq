# 04 · Shell

The shell is the top bar, the rail, the page header pattern and the instrument bar. It is built
once and every screen inherits it. Reference renders: `mockups/png/tonight.png` (collapsed rail),
`mockups/png/tonight-empty.png` (expanded rail), `mockups/png/narrow.png` (< 768 px).

Files (all under `packages/skotiq_app/lib/screens/shell/`):

| Piece | File today | What happens to it |
|---|---|---|
| Shell scaffold | `app_shell.dart` (744 lines) | Layout rows/columns change to the grid in §1. `StatusBar` stays at the bottom. `TitleBar` stays at the top. |
| Title bar | `widgets/title_bar.dart` | Becomes the **top bar** (§2). Gains the command field. Loses nothing else. |
| Rail | `widgets/side_navigation.dart` + `skotiq_ui/.../nav_item.dart` | Becomes the **rail** (§3). Single-line items, groups, Settings at the bottom. |
| Nav list | `shell_navigation.dart` | `primaryDestinations` becomes the grouped list in §3.2. |
| Status bar | `widgets/status_bar.dart` | Becomes the **instrument bar** (§5). Loses the web-dashboard and share buttons (they move to the top bar). |
| Bottom nav | `widgets/skotiq_bottom_navigation.dart` | 5 slots, 64 px (§6). |
| Dashboard command bar | `screens/dashboard/widgets/command_bar.dart` | **Deleted.** Its facts move to the instrument bar (global) and the Tonight hero (local). |
| Metrics | `skotiq_ui/lib/src/tokens/shell_chrome_metrics.dart` | Values in 03-tokens §3.4. |

## 1. Grid

```
┌──────────────────────────────────────────────────────────────┐  ▲
│ TOP BAR                                                 44px │  │
├──────┬───────────────────────────────────────────────────────┤  │
│      │ PAGE HEADER (inside the screen)                  56px │  │
│ RAIL ├───────────────────────────────────────────────────────┤  │ window
│ 64px │ PAGE BODY (screen content, scrolls or fills)          │  │ height
│      │                                                       │  │
├──────┴───────────────────────────────────────────────────────┤  │
│ INSTRUMENT BAR                                          32px │  ▼
└──────────────────────────────────────────────────────────────┘
```

- The rail sits BETWEEN the top bar and the instrument bar; both bars span the full width.
- Rail and top bar are `background`-toned. The instrument bar is `surface`-toned. The page body is
  `background`-toned. There is a 1 px `border` hairline under the top bar, right of the rail, and
  above the instrument bar.
- Chrome total: 76 px (was 40 + 36 + up to 166 px of screen-level headers). Every screen gets at
  least 60 px more content than before at the same window size.

## 2. Top bar (44 px)

Left to right, on a `-webkit-app-region: drag`-equivalent (`WindowDragArea` already exists):

| Zone | Content | Spec |
|---|---|---|
| Brand | 22 × 22 `primary` rounded-6 square with `LucideIcons.sparkles` in `onPrimary` at 14 px; wordmark `SKOTIQ` 12 px / 700 / +1.6 tracking in `textPrimary` | left padding 16, gap 10 |
| **Command field** | centred, `max-width 520`, `min-width 320`, height 30, `field` decoration on `surface`, `LucideIcons.search` 15 px muted, placeholder "Search targets, settings, or jump to a screen" 13 px muted, trailing `kbd` chip "Ctrl K" | Opens the command palette (§7). Click anywhere on it or press Ctrl/Cmd+K |
| Actions | four 32 × 32 `SkotiqIconButton`s, gap 2: remote-connection indicator (`monitor` when local, `wifi` when remote, badge dot when degraded; this is the existing `RemoteConnectionIndicator`), alerts (`bell`, existing `TransientAlertBadge` + notification centre), **help for this screen** (`help-circle`, replaces the tour toasts, see 05 §11), settings (`settings`, → `/settings`) | icons 17 px `textSecondary`, hover `surfaceHover` fill + `textPrimary` |
| Window controls | existing `WindowControls`, `ShellChromeMetrics.windowControlWidth` (46) each, no radius, icons 14 px muted, 8 px gap before the group | unchanged behaviour |

Removed from the title bar: the equipment-profile button (profiles live on the Equipment screen and
in the instrument bar's equipment pill).

## 3. Rail

### 3.1 Geometry

| | Collapsed (default) | Expanded |
|---|---|---|
| Width | 64 | 220 |
| Padding | 12 top/left/right, 8 bottom | same |
| Item | 40 × 40, radius `radiusLg`, icon 18 centred (padding 11 = (40 − 18) / 2, derived, not a spacing token) | 40 high, full width, icon 18 + label in `button` style, padding-left 11, gap 12 |
| Group | 14 px vertical gap between groups | 11 px `eyebrow` label ("OBSERVE") with 10 px above, 4 px below |
| Selected | fill `primary` 12%, icon `primary` | same + label `primary` |
| Hover | fill `surfaceHover`, icon `textPrimary` | same |
| Rest | icon `textSecondary` | same, label `textSecondary` |
| Badge | 7 px `warning` dot at top-right of the item (8, 8 inset) with 2 px `background` ring | same. Used on Equipment when nothing is connected, on Weather when unsafe |
| Bottom | `spacer`, then the collapse/expand toggle (`panel-left` / `panel-left-close`) as a normal item | + "Collapse" label |
| Tooltip (collapsed) | label only, `popover` decoration, 200 ms delay, right of the item, via the existing `SkotiqTooltip`. Fix F4 INSIDE `skotiq_ui/lib/src/components/skotiq_tooltip.dart`: its own comment (lines 63–94) documents the missed `onExit` when the trigger rebuilds; hide the overlay from `didUpdateWidget`/`deactivate` and on any pointer-up outside, and add a widget test that pumps a rebuild while hovered and asserts the overlay is gone | — |
| Transition | width animates 220 ms ease-out; labels fade in over the last 120 ms | |

Persisted in `AppSettings.sidebarCollapsed` as today.

### 3.2 Destinations (replace `ShellNavigation.primaryDestinations`)

```dart
// shell_navigation.dart — order and grouping are the spec. Route paths do NOT change.
group: 'navGroupObserve'   // "Observe"
  /dashboard   LucideIcons.moonStar      navTonight      // label "Tonight"   (was "Dashboard")
  /imaging     LucideIcons.camera        navImaging      // "Imaging"
  /sequencer   LucideIcons.listOrdered   navSequencer    // "Sequencer"
  /guiding     LucideIcons.crosshair     navGuiding      // "Guiding"
group: 'navGroupPrepare'   // "Prepare"
  /planner     LucideIcons.compass       navPlan         // "Plan"      (was "Plan Tonight")
  /equipment   LucideIcons.plug          navEquipment    // "Equipment"
  /weather     LucideIcons.cloudSun      navWeather      // "Weather"
group: 'navGroupReview'    // "Review"
  /darkroom    LucideIcons.aperture      navDarkroom     // "Darkroom"  (NEW destination; route exists)
  /analytics   LucideIcons.barChart3     navAnalytics    // "Analytics"
```

- The list type is `ShellPrimaryDestination` (`shell_navigation.dart:8`). Add
  `final ShellNavGroup group` (new enum `observe | prepare | review`); DELETE the `description`
  function field and the `description` parameter of `NavItem` (`nav_item.dart:12,21`); delete the
  `nav*Desc` strings from `translations.dart` in every language.
- `primaryIndexForLocation` is prefix-based (`shell_navigation.dart:183-191`). Add an alias table
  consulted first: `/session-review`, `/stack-result`, `/mosaic` → Darkroom; `/polar-alignment`,
  `/flat-wizard` → Equipment; `/tonight` → Tonight; `/settings` → −1 (nothing highlighted, Settings
  lives in the top bar); `/onboarding`, `/pairing`, `/replay`, `/diagnostics` → −1.
- Settings is NOT in the rail. Onboarding stays outside the shell.

### 3.3 Narrow (< 768 px) → bottom nav

Five fixed slots: Tonight, Imaging, Sequencer, Guiding, More. "More" opens a sheet listing Plan,
Equipment, Weather, Darkroom, Analytics, Settings with icons and labels. Code that changes:
`ShellNavigation.bottomNavigationDestinations` (6 entries today, `shell_navigation.dart:118-155`)
becomes the four `ShellRouteDestination`s above; `overflowDestinations` becomes every primary
destination without a slot PLUS `ShellNavigation.settings`; `isBottomNavRoute` follows;
`ShellChromeMetrics.contentStackBottomChromeHeight()` returns `BottomNavMetrics.barHeight` alone
below 768 px (there is no compact status bar any more). Bar height 64, item =
28 px pill (48 wide, radius 14) with 21 px icon + 11 px / 500 label; selected pill filled
`primary` 12% with icon and label in `primary`.

## 4. Page header (56 px, inside every screen)

Every routed screen starts with `PageHeader` (new widget in `skotiq_ui`, replaces
`ScreenHeader`):

```
| 24px | [icon 18 muted] [Title 20/600] [optional muted context 14]   [tab] [tab] [tab]      …      [actions] | 24px |
                                                                        ↑ 28 px gap after title    ↑ 22 px between tabs
```

- Height 56, bottom hairline, `background` fill.
- Tabs are UNDERLINE tabs (05 §4). They are the ONLY tab style allowed in a page header.
- Actions: right-aligned, gap 8. At most one `primary` button, and only if it is the screen's
  main action (Sequencer: Start; Equipment: Scan). Others are `secondary`, `ghost` or chips.
- NO subtitle sentence. The `subtitle` parameter is removed. A screen that needs to explain
  itself gets the help button in the top bar (05 §11).
- Below 768 px the header collapses to 48 px, tabs move to a scrollable second row.

## 5. Instrument bar (32 px)

The single persistent status surface. `surface` fill, top hairline, `caption`-sized text, pills
are `InstrumentPill`s (05 §10b): 22 px high, 8 px horizontal padding, `radiusXs`; hover
`surfaceHover`. The clock and LST values are `readoutXs`.

Left group (in order, each a pill; click opens the relevant screen):

1. Run state: dot + word. `Idle` (muted dot), `Ready` (primary dot), `Running` (success dot with
   live halo), `Paused` (warning), `Error` (error). Click → Sequencer.
2. `sep` (1 × 14 hairline)
3. Camera: `camera` icon + dot + device name or "No camera". Value shows the SHORT model name
   ("ASI2600MM"). Click → Equipment.
4. Mount: `mountain` icon + dot + name.
5. Guider: `crosshair` icon + dot + name.
6. Focuser: `focus` icon + dot + position when connected ("EAF 25000").
7. Filter wheel: `disc` icon + dot + current filter, only when connected.
8. Equipment status/temperature-compensation LEDs and `OperationStatusBar` (existing) stay after
   these, in the same pill style.

Right group (never sacrificed; left group scrolls/elides first, keeping the existing cut affordance):

1. Sensor temperature `thermometer` + value (only when a cooled camera is connected).
2. Save folder `hard-drive` + short path + free space, or "No save folder" in `warning` text.
3. `sep`
4. Clock: `clock` icon, local time in mono 500 `textPrimary`, then `LST` muted, then LST mono.

Removed: the "Dashboard" (web) button and the share button (→ top-bar remote indicator menu),
the second "Idle" pill, the profile pill's "0 connected" duplicate.

Below 768 px the instrument bar is replaced by a 28 px status strip INSIDE the Tonight and Imaging
page headers (see `narrow.png`); other screens show nothing (the bottom nav is the only bottom
chrome).

## 6. Narrow layout summary

| | ≥ 768 px | < 768 px |
|---|---|---|
| Top bar | 44, with command field | 48, screen title + search icon + bell + settings |
| Rail | yes | no |
| Instrument bar | 32 | no; 28 px strip in Tonight/Imaging headers |
| Bottom nav | no | 64, five slots |
| Side panels | 320 px column | bottom sheet with a horizontal chip strip for sections |

## 7. Command palette (Ctrl/Cmd+K)

New widget `CommandPalette` (`packages/skotiq_app/lib/widgets/command_palette/`), shown with
`showGeneralDialog` + `Align(alignment: Alignment.topCenter)` and a 96 px top inset (NOT
`SkotiqDialog`, which forces a title row, a close button and centre alignment). `dialog`
decoration, 560 px wide, input 40 px. Results grouped with eyebrows: **Screens** (every rail destination + Settings sections +
route-only screens: Polar alignment, Flat wizard, Session review, Mosaic, Pairing, Diagnostics),
**Targets** (`objectSearchProvider`, the same provider behind the Planetarium search box; shows
an "Install catalogs" row when it reports no catalog),
**Settings** (the existing `settings_search_index.g.dart`), **Actions** (Start/Stop sequence,
Connect all, Park, Snapshot). Keyboard: arrows, Enter, Esc. This is how every route-only screen
becomes reachable without adding rail items.

Invoked from the top bar field and a `Shortcuts` binding in `app_shell.dart`.

## 8. Acceptance (shell wave)

Verify in the running app with `tools/ui_audit/drive_linux.py` (see 07 §Verification):

- [ ] `tree` shows exactly nine rail buttons in the order of §3.2 plus "Expand navigation" (the
      toggle is named for what it DOES: "Expand navigation" while collapsed, "Collapse navigation"
      while expanded); no button named "Dashboard" or "Plan Tonight"; no `nav*Desc` text in the
      tree.
- [ ] `shot --raw` (root coordinates, no downscale) of `/dashboard` at 1600 × 900: the page-body
      top edge is at window-y 100 ± 2 (44 + 56) and the instrument bar's top edge at 868 ± 2
      (900 − 32). No command bar row between the page header and the hero.
- [ ] `tree` on `/equipment`, `/imaging`, `/settings` shows the same instrument-bar panels as on
      `/dashboard` (clock, LST, save folder, four device pills).
- [ ] Exactly ONE tree element whose name is exactly "Idle", "Ready" or "Running" on any screen
      (the instrument-bar pill). The Tonight eyebrow ("Running · 42%") and button labels do not
      count; the Sequencer header carries no run-state chip.
- [ ] Navigating to `/session-review` highlights Darkroom in the rail; `/settings` highlights
      nothing.
- [ ] The More sheet (window at 700 px) lists Plan, Equipment, Weather, Darkroom, Analytics,
      Settings.
- [ ] All of the above repeated in light and red night (`shot` of `/dashboard` in each).
- [ ] Ctrl+K opens the palette; typing "polar" lists Polar alignment; Enter navigates.
- [ ] Window at 700 × 900: bottom nav has five buttons; no instrument bar; Imaging shows the 28 px
      status strip.
- [ ] Rail collapsed hover tooltip disappears when the pointer leaves (`shot` 500 ms after moving
      the pointer to the page body shows no tooltip).
