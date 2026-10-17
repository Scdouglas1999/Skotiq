# w11-mount-panel — the Imaging side panel's Mount section

Branch `agent/w11-mount-panel`, base `9c233bdd0`.

Owner's report: *"Can we fix the Mount sub tab inside Imaging as well? Basically
every single button has a truncated label due to sizing."*

## What was actually wrong

The Imaging side panel is 320px wide **including** its 44px icon strip
(`SidePanel.defaultWidth`, `stripWidth`), and the panel pads its content by 16 on
each side — 244px of content. Every other section in that rail knows this and
says so ("The SidePanel already pads its content by 16"). The Mount section did
not: it added `padding: EdgeInsets.all(24)` of its own and then wrapped each
group in a `SkotiqCard` at `EdgeInsets.all(16)`. 80 of the 244px went to
air, leaving 164 for content — and the actions were laid out as
`Row(children: [Expanded, SizedBox(12), Expanded])`, i.e. 76px per button.

A `Row` of `Expanded` children is a perfectly valid layout. Nothing overflowed,
nothing threw, nothing logged. The buttons simply ellipsised their labels, which
is the whole defect: the panel offered "U…", "St…", "Three-Point P…", "RA (H…",
"Sl…" and "S…" and nothing in the app could tell.

## The fix

Measurement, not breakpoints. What fits depends on the words the mount reports
("Start tracking" vs "Park"), on the locale and on the reader's text scale, so
no dp threshold can be right.

### `skotiq_ui` (shared: the cause is in the components)

- `measureTextWidth(context, text:, style:)` —
  `packages/skotiq_ui/lib/src/utils/text_measure.dart`. One `TextPainter`
  measurement that reads the text scale off the context.
- `SkotiqButton.measureWidth(context, label:, hasIcon:, size:)` — the width
  a button needs, from the button's **own** metrics: the same text style,
  horizontal padding, icon slot and 1px border `build` paints with, so the
  measurement cannot drift from what is drawn. The three per-size metrics moved
  from `State` getters to top-level functions so there is exactly one
  implementation of each.
- `AdaptiveColumns` / `AdaptiveCell` —
  `packages/skotiq_ui/lib/src/layout/adaptive_columns.dart`. Lays cells out
  in as many **equal** columns as their measured widths allow (the widest cell
  sets the column width, so no single cell is the one that truncates) and stacks
  them full width when not even two fit. A short final run keeps the grid's
  columns. `columnsThatFit` is the pure function and is unit-tested.

### `MountTab`

| Before | After |
| --- | --- |
| `EdgeInsets.all(24)` + `SkotiqCard(padding: 16)` per group | `padding: EdgeInsets.zero` + `PanelSection`, exactly as every sibling section in the rail (14px card padding → 216px of content) |
| Actions: fixed two-column `Row` | `AdaptiveColumns`: two-up when both measured labels fit, a full-width stack otherwise |
| `ABORT SLEW`, `ButtonVariant.primary` | `Abort slew`, `ButtonVariant.destructive`, always full width |
| `Three-Point Polar Alignment` | `Polar alignment` — what the Sequencer toolbar and the command palette already call that screen; three-point is the method chosen inside it |
| `Start Track` / `Stop Track` | `Start tracking` / `Stop tracking` |
| Caps `_StatusBadge` (bespoke box) | `SkotiqChip(tone:, dot: true)` — the chip the Equipment screen's device cards use |
| `RA (Hours)` / `Dec (Deg)` hints side by side | stacked `SkotiqTextField`s labelled `RA` / `Dec` with `h` / `°` suffixes, mono values |
| `_InfoRow` (caption label over `monoSm`) | `Readout(size: ReadoutSize.sm)` — the design system's readout, em dash for an unknown value instead of `--` |
| Pulse cross with a rigid 48px centre | the centre gap is `Flexible`; the pads themselves never shrink |
| `Responsive.isMobile(context)` decided the readout grid | the grid decides from the width it is actually given — the window size never said anything about a 244px column |

`_LabelFirstButton` is the last-resort rule: below the width `label + icon`
needs, the **icon** gives way, never the words. At every real host width the
icons are all there; the wrapper is what makes 160px honest rather than a
special case.

## The sibling sections in the same rail

Driven live at the panel's real width (release bundle, harness profile
`w11mount`, `NS_AUDIT_DISPLAY=:98`), one section at a time off the icon strip:

| Section | Found | Done |
| --- | --- | --- |
| Capture | Clean. Its buttons ("View quick captures", "Clear session") are content-sized `Align`ed, not a fixed pair. The `Save to` / `Name` **fields** show truncated values, which is a field showing a long value, not a control hiding its own name. | — |
| Camera (cooling + calibration) | **Same defect.** "Cool Down" rendered "Cool D…" in a fixed two-column `Row`; "Target temperature" broke **mid-word** as "temperatur / e" in the slider's label column. | `AdaptiveColumns` for the pair; label is "Target"; copy sentence-cased ("Cool down", "Cancel warm-up") |
| Focus | The manual step-size strip clipped `500` to "50(" — a horizontal `SingleChildScrollView` with no fade, arrow or part-visible chip to say it continued. Same defect the rotator's relative-move strip was fixed for. | `Wrap` |
| Guiding | Same fixed two-column pair (Start / Stop). At rest both fit; `Starting...` beside Stop does not at 216px. | `AdaptiveColumns` |
| Mount | The reported defect. | rebuilt (above) |
| Filter wheel | Clean — positions are wrapping chips. | — |
| Rotator | Not reproducible in the sim profile (no rotator connected, so the panel is its empty state). By inspection its Go to / Sync rows are `Expanded` **field** + content-sized button, so the button cannot truncate; the field takes the squeeze. Not the same defect. | — |
| Annotations | Clean (empty state, wrapping filter chips). | — |
| DepthLock | Clean — already `Wrap`s its button groups. | — |

Copy that is still Title Case in sections I did not otherwise touch, and so was
left for the copy pass rather than mixed into a layout fix: "Tracked Stars",
"Guider Configuration", "Step Size:", "Go To Position...", "Run Autofocus",
"Temperature Compensation", "Gain / Offset".
## Proved live

Release bundle built in this worktree; the app driven headless on `:98` with
`tools/ui_audit/drive_linux.py --profile w11mount`, seeded from
`~/.cache/skotiq-ledger-preview/data` minus `skotiq.db.lock`. Route:
Skip the Continue Session dialog → Imaging in the left rail (`tree` shows
"Live view") → the mount glyph on the right rail.

| Window | Shot | Result |
| --- | --- | --- |
| before (supplied fixture, 1920×1200) | `~/.cache/ns-worktrees/fixtures/imaging-mount-tab-truncated.png` | "U…", "St…", "ABORT SLEW", "Three-Point P…", "RA (H…", "Sl…", "S…" |
| 1920×1200 | `reports/sequencer-ledger/w11-mount-panel-shots/after-mount-1920x1200.png` | every label in full |
| 1600×900 | `reports/sequencer-ledger/w11-mount-panel-shots/after-1600x900.png` | every label in full |
| 1280×800 | `reports/sequencer-ledger/w11-mount-panel-shots/after-1280x800.png` | every label in full |
| 1280×800, scrolled | `reports/sequencer-ledger/w11-mount-panel-shots/after-1280x800-scrolled.png` | Go to & sync and Pulse guide in full |
| Camera section | `reports/sequencer-ledger/w11-mount-panel-shots/after-camera-1920x1200.png` | "Cool down" / "Warm up" / "Build defect map..." in full; "Target temperature" on one line |
| Guiding section | `reports/sequencer-ledger/w11-mount-panel-shots/after-guiding-1920x1200.png` | Start/Stop share a row (they fit); "Settle threshold" on one line |
| Focus section | `reports/sequencer-ledger/w11-mount-panel-shots/after-focus-1920x1200.png` | the step strip wraps; 500 is whole |

The accessibility tree at each size names them `Unpark`, `Start tracking`
(disabled — the mount is parked), `Abort slew`, `Polar alignment`, `Slew`,
`Sync`, with the chip as `Stopped`. The painted labels match, read off the
screenshots.

The panel's own layout decisions at the real 320px panel (216px inside a
section card, measured with the shipped HankenGrotesk):

- Actions stack. Two labelled buttons need ~2 × 143 + 8 = 294px.
- Slew/Sync stack. The Slew cell has to reserve the popup chevron
  (`4 + kMinInteractiveDimension`), which puts the pair at ~264px.
- RA/Dec share a row: a sexagesimal RA is ~101px at `readoutSm`, so 2 × 101 + 12
  fits 216 — measured, not assumed, and it drops to one column when it stops
  fitting (which it does at the 160px the widget test pins).
- In the narrow bottom sheet (a phone at 430) the same code puts the actions
  two-up, because there the measurement says they fit.

## Verification

Unpiped, exit codes recorded:

| Command | Exit |
| --- | --- |
| `flutter test test/screens/imaging --concurrency=3` (skotiq_app) | 0 — **373 passed** (360 on base: +10 mount fit, +1 SmallButton measure, +2 slider label) |
| `flutter test --concurrency=3` (skotiq_ui, whole package) | 0 — 530 passed |
| `dart analyze lib` (skotiq_app) | 682 infos vs **692 on base** — ten FEWER (the rewrite dropped deprecated `ButtonVariant.outline` / `h5` / `surfaceAlt` uses). Zero warnings, zero errors, zero new. |
| `dart analyze lib` (skotiq_ui) | 0 — "No issues found!" |
| `dart format --set-exit-if-changed` on every file I touched | 0 |
| `flutter build linux --release` | 0 |

Pre-existing and NOT mine, confirmed by re-running against `9c233bdd0`:

- `test/widgets/go_to_position_dialog_test.dart` — all 10 tests fail on the base
  commit too ("LayoutBuilder does not support returning intrinsic dimensions"
  inside the focuser's `AlertDialog`).
- `dart format` would rewrite 41 files that predate this branch (the DepthLock
  set, `imaging_screen.dart`, `live_preview_area.dart`, `preview_viewport.dart`,
  `skotiq_tooltip.dart`, several `skotiq_core` files). Left alone.
- `test/golden/guiding_panel_builtin_golden_test.dart` rewrites
  `docs/design/goldens/surface-guiding-panel-builtin-multistar.png` when it
  runs. The regenerated PNG was reverted, per "do not modify golden PNGs" — the
  guiding panel's Control row did change, so that golden is now stale and wants
  a deliberate regeneration on the CI host.

## One thing the owner should know

`~/.cache/ns-worktrees/libskotiq_bridge.ownertree-1467366630.so` — the
prebuilt bridge this brief names — **cannot be read past 41MB**: `dd` stops with
an I/O error at 40,976,384 of 48,789,784 bytes and `md5sum` refuses it. Every
copy of it is a hardlink to the same damaged inode, so
`preview-merged`, `w8-performance` and `cargo-target/release` are all the same
unreadable file. This looks like the btrfs corruption from 2026-08-14 rather
than anything this branch did.

The bundle here was linked against
`~/Documents/Skotiq2/native/skotiq_native/target/release/libskotiq_bridge.so`
instead — same `rustContentHash` (-1467366630), built 2026-09-13 00:20, reads
clean (md5 `c226e4aecdd9b071ecb03dd81b823c98`). The app ran, talked to the
simulators and reported live mount state, so the pairing is good.

Also: this worktree's `native/skotiq_native/target` was checked out as a
regular FILE containing the path it should point at, not as the symlink git
records (mode 120000). That is why `flutter build linux` warned "Rust library
not found". Restored to a real symlink; `git status` is clean either way.
