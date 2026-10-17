# w17-catalog-overlay — Imaging catalog-settings popover clamped to 28 px

Workstream `w17-catalog-overlay`, branch `agent/w17-catalog-overlay`, base
`5b2235cc7` (verified with `git rev-parse HEAD` before any edit — no detach
needed).

Owner report: "The catalog overlay button in Imaging is cut off and needs to
be fixed."

## Confirmed cause

`packages/skotiq_app/lib/screens/imaging/widgets/imaging_preview_toolbar.dart`,
`_CatalogOverlaySettingsButton` — a `PopupMenuButton<String>` whose single item
hosts `CatalogOverlayPopover` — ended with:

```dart
constraints: const BoxConstraints.tightFor(
  width: SkotiqTokens.iconButtonSizeSm,   // 28.0
  height: SkotiqTokens.iconButtonSizeSm,
),
```

`PopupMenuButton.constraints` is documented in the Flutter SDK as "Optional
size constraints for the **menu**" and is forwarded verbatim to `showMenu`
(`packages/flutter/lib/src/material/popup_menu.dart` — the property doc and
the `_PopupMenuRoute` construction). It never touches the trigger, which is a
stock `IconButton` built by `PopupMenuButton` itself. The route then clamps
the opened menu to a 28×28 box while `CatalogOverlayPopover` asks for
`clampPanelWidth(width, fraction: 0.3, min: 200, max: 240)` — 240 px at the
1920 px test window — so the title, "Magnitude limit" dropdown and both
switches were squeezed into a 28 px square. That is the "cut off".

Secondary defect at the same site, fixed together: the popover was wrapped in
`PopupMenuItem(enabled: false, padding: EdgeInsets.zero, height: 0)`. A
disabled `PopupMenuItem` halves the opacity of every descendant icon
(`IconTheme.merge(opacity: 0.5)` in `PopupMenuItemState.build`) and merges the
whole panel into one disabled `menuItem` semantics node — the live controls
lose their own accessible names and render dimmed. Pointer events still
reached the switches (which is why the bug read as "clipped" rather than
"dead"), but the widget was publishing itself to the a11y tree as inert.

## Fix (all in `imaging_preview_toolbar.dart`)

- Removed the `constraints:` argument from the `PopupMenuButton` — the menu is
  now free to take the popover's natural width.
- Sized the **trigger** where the trigger actually is:
  `style: IconButton.styleFrom(minimumSize: Size.square(28), fixedSize:
  Size.square(28), tapTargetSize: MaterialTapTargetSize.shrinkWrap)`. The
  icon button keeps its exact 28×28 footprint; `shrinkWrap` stops Material's
  default padded touch target from re-inflating it, so the toolbar row does
  not shift.
- Replaced the disabled `PopupMenuItem` with `_CatalogOverlayPopoverEntry`, a
  15-line `PopupMenuEntry<String>` that returns the child untouched
  (`height => 0` is nominal — the route measures each entry at layout time;
  `represents() => false` since the panel mutates providers directly and
  returns no value). This keeps the switches/dropdown at full opacity with
  their own semantics, and — unlike `enabled: true` — there is no item
  InkWell waiting to pop the route on a tap that misses a control.
- Inside the entry the child is wrapped in
  `Align(alignment: AlignmentDirectional.topStart)`. `_PopupMenu` lays its
  entries out under `IntrinsicWidth(stepWidth: 56)`, which tightens every
  entry to the same 56-stepped width — unwrapped, the card would be dragged
  to 280/224 instead of its designed 240/200. `Align` is the
  `RenderIntrinsicWidth`-documented way to let a child keep its own width
  under that tighten, so the card renders at exactly the `clampPanelWidth`
  answer. The menu shell behind it keeps the standard stepped width.
- `position: PopupMenuPosition.under` and `offset: Offset(0,
  SkotiqTokens.spaceXs)` unchanged; the route's `_fitInsideScreen` still
  slides the menu inside the screen with the standard 8 px inset, which is
  what covers the right-edge case for free.
- The dead `onSelected: (_) {}` no-op was dropped — a custom entry can never
  produce a selection.

## Sibling controls in the same file — reviewed, all clean

- `OverlaysMenuButton` (`PopupMenuButton<String>`): passes
  `constraints: BoxConstraints(minWidth: 248, maxWidth: 296)` — that is
  *menu* sizing used correctly, bounding the overlays panel's width, not the
  trigger. Left untouched.
- `_AnnotateButton`, `_DepthLockRegionButton` and the zoom/fit icons: plain
  `SkotiqIconButton`s — no `PopupMenuButton`, nothing to fix.
- One unrelated `BoxConstraints(minHeight: 40)` on `_OverlayMenuRow` and a
  layout-time `BoxConstraints(minWidth: constraints.maxWidth)` — ordinary
  layout constraints, not popup sizing.
- No other `PopupMenuButton` exists in the file. Scope held: nothing outside
  `imaging_preview_toolbar.dart` was touched for this defect.

## Regression test

Three cases added beside the existing toolbar tests in
`packages/skotiq_app/test/screens/imaging/imaging_preview_toolbar_test.dart`:

- `catalog_settings_popover_opens_at_natural_size` — opens the popover at a
  1600 px window; asserts width ≈ 240 (would read exactly 28.0 under the
  defect), trigger still exactly 28×28, popover anchored at/below the
  trigger's bottom edge, and title/dropdown/both switch rows present.
- `catalog_settings_popover_controls_are_live` — taps the DSO switch
  (`catalogOverlayIncludeDsosProvider` true→false), the bright-star switch
  (`catalogOverlayIncludeStarsProvider` false→true), then opens the
  `SkotiqDropdown` and picks `Mag <= 14`
  (`catalogOverlayMagnitudeLimitProvider` → 14.0); asserts the popover stays
  open through its own controls.
- `catalog_settings_popover_stays_on_screen` — a bare toolbar in a 420 px
  window; scrolls the settings button to the right edge via `ensureVisible`,
  opens the popover, asserts width ≈ 200 (the min-width floor) and that the
  popover rect lies entirely within `[0, 420]`.

**Red proof:** run against the pre-fix code these tests failed exactly on the
defect — measured popover width `Actual: <28.0>` (expected 240), and the DSO
tap missed the clipped switch (`catalogOverlayIncludeDsosProvider` stayed
`true`). After the fix all three pass.

## Before / after evidence (running app, Xvfb)

Sandboxed instance via `tools/ui_audit/drive_linux.py`, `SK_AUDIT_DISPLAY=:97`
(private Xvfb — never `:0`), `LIBGL_ALWAYS_SOFTWARE=1`, scratch
`SKOTIQ_DATABASE_DIR` under `/tmp/ns-audit/w17/data`. AT-SPI registry was
unavailable in this session (`tree` could not bind), so navigation used
`shot` + `click-img` per the README fallback.

Before (pre-fix build, profile `w17`):

- `/tmp/ns-audit/w17/shots/before-03-imaging.png` — Imaging screen.
- `/tmp/ns-audit/w17/shots/before-04-popover.png` — popover "open": a ~28 px
  dark box under the settings glyph.
- `/tmp/ns-audit/w17/shots/before-05-popover-zoom.png` — zoomed capture of the
  same clipped box.
- `/tmp/ns-audit/w17/shots/before-06-full.png` — full-frame context.

After (fixed build, same profile, window 1920→1280 logical at capture scale):

- `/tmp/ns-audit/w17/shots/after-03-popover.png` — popover opens at full
  width under the trigger: "Catalog overlay" title, "Mag <= 10" dropdown,
  DSO switch ON, bright-star switch OFF — nothing clipped.
- `/tmp/ns-audit/w17/shots/after-04-dso-toggled.png` — DSO switch flipped
  ON→OFF by a click inside the popover; popover stayed open. Live control,
  live provider.
- `/tmp/ns-audit/w17/shots/after-05-dropdown.png` — magnitude dropdown opens
  its own route over the popover, all five buckets listed, `Mag <= 10`
  checked.
- `/tmp/ns-audit/w17/shots/after-06-mag14.png` — `Mag <= 14` selected and the
  popover still open — provider update end-to-end.
- `/tmp/ns-audit/w17/shots/after-07-narrow.png`,
  `after-08-1100.png` — at 560 px and 1100 px window widths the app switches
  to its compact layout (bottom nav, no preview toolbar), so the narrow
  desktop-window case is not reachable in the real shell; it is covered by
  the `stays_on_screen` widget test at 420 px plus the route's
  `_fitInsideScreen` inset.

The fixed build's app process exited on its own during a later `resize`
(GTK/OpenGL frame timeouts in the log — a sandboxed softpipe quirk, not a
crash from this change); all evidence above was captured beforehand.

## Commands run (unpiped exit codes)

```
git rev-parse HEAD                                    → 5b2235cc7…  (base ✓)
export TMPDIR=$HOME/.cache/ns-tmp/w17-catalog-overlay (created)
dart format --output=none --set-exit-if-changed
    packages/skotiq_app                           → EXIT=0 (0 changed)
cd packages/skotiq_app && dart analyze            → EXIT=0
    873 issues, ALL info-level `deprecated_member_use`, all pre-existing,
    zero in the two touched files, zero errors and zero warnings.
cd packages/skotiq_app &&
  flutter test test/screens/imaging --concurrency=4   → EXIT=0, +378,
    "All tests passed!"
cd apps/desktop && flutter build linux --debug        → EXIT=0
    "✓ Built build/linux/x64/debug/bundle/skotiq_desktop"
```

Pre-fix red run of the new tests (same command, single file): EXIT=1 with the
28.0 px width and dead-tap failures quoted above — the test catches the
original defect.

## Result

- Popover opens at natural width (240 px @ 1600; 200 px floor), anchored
  under the icon via the unchanged `PopupMenuPosition.under` + offset; the
  route keeps it on-screen at the right edge.
- Trigger stays a 28×28 icon button; toolbar row unchanged.
- Magnitude dropdown, DSO toggle and bright-star toggle are live — verified
  in the widget tests (provider reads) and in the running app (screenshots).
- Change confined to `imaging_preview_toolbar.dart` +
  `imaging_preview_toolbar_test.dart` + this report.
