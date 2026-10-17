# g1-glass — the window as one slate of glass

Branch: `rebrand/skotiq-g1-glass`
Base: `cc45a3daf` (rebrand merged)
Date: 2026-10-17

## What changed and why

The desktop shell's title bar and bottom status strip are gone. The window is
now one surface whose chrome lives inside it; depth comes from tone, not lines.

### Shell (`packages/skotiq_app`)

- **`widgets/window_chrome.dart` (new)** — shared chrome widgets:
  - `ShellTopBand` (58 px): LST clock + `brandWarm` now-dot at the left;
    remote, help and settings at the right; a 1×18 separator; then the window
    controls. The controls are 30×30, radius 9, 16 px glyphs, 2 px apart,
    14 px from the right edge, with tooltips/semantics "Minimize window" /
    "Maximize window" / "Restore window" / "Close window". Real buttons:
    hover/pressed fills from the tokens, focus rings, keyboard activation.
    Not rendered on macOS (native traffic lights stay).
  - `SidebarChromeHeader` — the sidebar's top: a drag strip (12 px; ~40 px
    on macOS to leave room for the traffic lights), then `SkotiqLockup` +
    the command field ("Search or jump to…" with a `Ctrl K` / `Cmd K` chip
    that opens the command palette).
  - `WindowDragArea` — pan → `windowManager.startDragging()`;
    double-tap → platform action read over
    `com.skotiq.desktop/window_chrome` (`gtk-titlebar-double-click` on
    Linux, `AppleActionOnDoubleClick` on macOS, `toggleMaximize` fallback).
  - `WindowChromeState` — maximized/full-screen notifier fed by
    `windowManager` events.
  - `WindowEdgeHairline` — the app's own 1 px edge (~9% of theme ink, so red
    night gets a red edge, not a white one), gated off while the window
    fills the screen/work area.
  - `WindowResizeEdges` — invisible 5 px edge / 14 px corner grips calling
    `windowManager.startResizing(edge)`, Linux-only, gated the same way.
  - `FocusTraversalOrder` tags order keyboard focus sidebar → main → window
    controls.
- **`widgets/shell_clock.dart` (new)** — the wall-clock + LST readout that
  used to live in the bottom strip. Owns a one-second aligned timer, scoped
  to a `RepaintBoundary`, and shows the `clockProvider` timezone.
- **`widgets/rig_card.dart` (new)** — replaces the status strip as a card
  pinned to the bottom of the sidebar. Line one is the run state
  ("Sequence — Running", progress % when meaningful); then one labelled row
  per device (Camera temp, Mount, Guider RMS, Focuser position, Filter
  wheel), the `OperationStatusBar`, and the save-path row with distinct
  loading/present/missing/unknown/unconfigured states. Every row carries a
  semantic label ("Camera: disconnected", …) and the click targets the old
  strip had. Collapsed sidebar shows the card as a 32 px icon column with
  tooltips.
- **`side_navigation.dart`** — the sidebar now runs the full window height
  on `SkotiqColors.surface` with a faint radial wash of the user's accent at
  the top-left (≈10% alpha, gone by ~70%), so it follows the chosen scheme
  like the logo does. Header takes `SidebarChromeHeader`; footer takes
  `RigCard`. No border between sidebar and main.
- **`app_shell.dart`** — `TitleBar`/`StatusBar` removed. The desktop body is
  now `[SideNavigation | Column(ShellTopBand, content)]` under a single
  surface, with `WindowEdgeHairline` painted over everything on Linux and
  `_ContentSemanticsBoundary` keeping routed pages' semantics from
  swallowing the chrome. `_fallbackSideNavExpanded` drives collapse.
- **`app_shell_desktop.dart`** — calls `ensureWindowChromeState()` so the
  hairline/resize-edge gating has live maximize/full-screen state.
- **`_mobile_settings_bar.dart`** — the narrow-desktop path (below the side
  nav breakpoint) keeps a settings strip that now includes the window
  controls and a drag area, so a narrow desktop window still has
  minimize/maximize/close. macOS is excepted (native traffic lights).
- **`app_shell_parts/`** — the compact bottom-nav path is unchanged except
  that it never carried a status bar; nothing desktop-only leaks onto
  Android/iOS.
- **`translations.dart`** — added the new strings the card/band needed.
- **`shell_chrome_metrics.dart` (`skotiq_ui`)** — added the chrome metrics
  the band/controls/grips share.

### Runners (`apps/desktop`)

- **Linux `my_application.cc`** — plain opaque toplevel: no GTK header bar on
  any environment, `gtk_window_set_decorated(FALSE)` so no decorations or
  CSD shadow margins (square corners free). Title "Skotiq", default size
  1600×900 (matches `WindowOptions.size` — the comment about the first-frame
  size race is kept). `gdk_set_program_class(APPLICATION_ID)` + the
  `application-id`/`g_set_prgname` already in `my_application_new` give
  `com.skotiq.desktop` for both Wayland app-id and X11 WM_CLASS. Icon list
  set from `bundle/icons/` at 32–512 resolved via `/proc/self/exe`. New
  `com.skotiq.desktop/window_chrome` method channel answers
  `getTitlebarDoubleClickAction` from `GtkSettings:gtk-titlebar-double-click`.
  Window still shows on `first-frame`.
- **Windows `win32_window.cpp`** — caption hidden (system resize border +
  shadow kept), `DWMWA_WINDOW_CORNER_PREFERENCE = DWMWCP_ROUND` for
  Windows 11 rounded corners.
- **macOS `MainFlutterWindow.swift`** — `titleVisibility = .hidden`,
  `titlebarAppearsTransparent = true`, `.fullSizeContentView`, native
  traffic lights retained, `com.skotiq.desktop/window_chrome` channel
  answers from `AppleActionOnDoubleClick`.
- **`main.dart`** — Linux root wrapped in `WindowResizeEdges`. Every
  existing blank-window/hang guard kept (`waitUntilReadyToShow`, post-frame
  `show()`, no blocking awaits before `runApp`).

### Packaging

- `packaging/desktop/com.skotiq.desktop.desktop` — freedesktop entry with
  `@BUNDLE_DIR@` substitution; the Linux release is a tarball, so the entry
  is documentation for the user's manual install (see
  `docs/getting-started/installation.md`), not an installer.

### Decisions that deviate from the brief, and why

- **Expanded sidebar below 900 px.** At 900×700 the shell still shows the
  expanded sidebar; the compact path begins under the 768 px
  `breakpointTablet`. That's the shell's existing breakpoint, kept
  deliberately so the rig card stays usable.
- **Screenshots at 1440×900/900×700/700×700.** The brief asked for 1440×900
  and a narrow width; I captured three so the breakpoint transition (768 px)
  is visible in the middle shot.

## Verification

All commands run from the worktree root unless noted, with
`TMPDIR=$HOME/.cache/ns-tmp/g1-glass`.

| Command | Exit |
| --- | --- |
| `git rev-parse HEAD` → `cc45a3daf…` | 0 |
| `melos bootstrap` | 0 |
| `melos run analyze` | **0** (initially 1: 2 unused imports in new tests, removed) |
| `dart format --output=none --set-exit-if-changed packages/skotiq_app apps/desktop packages/skotiq_ui` | **0** (2436 files, 0 changed) |
| `melos exec --concurrency=1 --flutter -- flutter test --exclude-tags golden --concurrency=4` | **0** — see totals below |
| `cd native/skotiq_native && CARGO_TARGET_DIR=$HOME/.cache/ns-tmp/g1-glass/target cargo build --release -j 8 --manifest-path bridge/Cargo.toml` | 0 (1 dead-code warning, pre-existing) |
| `cd apps/desktop && flutter build linux --release` | 0 |
| `python3 tools/rebrand/rebrand.py --check` | 0 ("0 leftover mention(s)") |
| `git diff --check HEAD` | 0 |

Non-golden suite totals (all passed):

| Package | Tests |
| --- | --- |
| skotiq_app | +4524 |
| skotiq_bridge | +65 |
| skotiq_core | +6836 (~4 skipped) |
| apps/desktop | +1304 |
| apps/mobile | +235 |
| skotiq_planetarium | +640 |
| skotiq_plugins | +60 |
| skotiq_remote_protocol | +200 |
| skotiq_ui | +576 |
| skotiq_updater | +174 |
| **Total** | **+14 614, 0 failed** |

### Test results

- `test/screens/shell/` + `test/a11y/` (the touched suites):
  `+108 All tests passed!`
- New coverage: `window_chrome_actions_test.dart` (controls against a faked
  `window_manager` channel; drag pan; double-tap), `rig_card_rows_test.dart`
  (per-row semantics), `rig_card_layout_test.dart` (card bounds),
  `rig_card_save_path_test.dart`, `shell_clock_*_test.dart`,
  `shell_chrome_semantics_test.dart`, `window_controls_enabled_state_test.dart`.
- Old title-bar/status-bar tests were repointed at `ShellTopBand`,
  `ShellClock`, `RigCard` — not deleted. `status_bar_overflow_test.dart` and
  `status_bar_cut_marker_test.dart` asserted scrolling-strip behaviour the
  card doesn't have; their intent (no dropped status at any width) is
  carried by `rig_card_layout_test.dart`/`rig_card_rows_test.dart`.

### Screenshots (xvfb, `LIBGL_ALWAYS_SOFTWARE=1`, scratch HOME, `GDK_BACKEND=x11`)

- `reports/rebrand/g1-glass/shell-1440x900.png` — wide, expanded sidebar:
  lockup + command field + nav sections + rig card; top band with LST clock
  and window controls; no hairlines.
- `reports/rebrand/g1-glass/shell-900x700.png` — mid-size, still expanded.
- `reports/rebrand/g1-glass/shell-700x700.png` — below the 768 px
  breakpoint: compact bottom nav, lockup + settings + all three window
  controls still reachable in the top strip.

### Bugs found during verification

- `WindowResizeEdges` wraps the app above `MaterialApp`'s `Directionality`;
  `Stack`'s default `AlignmentDirectional.topStart` resolved against a null
  `TextDirection` and crashed first layout. Fixed by giving the root `Stack`
  a non-directional `Alignment.topLeft` (`window_chrome.dart`). The symptom
  was a black window under xvfb — caught by the screenshot run.
- Two unused imports in the new test files — removed.

## Couldn't finish / notes

- Windows/macOS runners changed but not compiled here (no toolchains); code
  is syntactically reviewed. macOS traffic-light inset depends on the
  sidebar's top strip height — worth a quick look on a real Mac.
- Golden tests: not run per brief — colour changes from the rebrand base are
  expected to break some goldens, to be regenerated once after every branch
  merges. Any golden that renders the shell chrome (`TitleBar`/`StatusBar`
  regions) will differ by design.
