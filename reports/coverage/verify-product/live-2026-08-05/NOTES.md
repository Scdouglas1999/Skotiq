# Live product-critique verification — 2026-08-05

## How the app was driven

- Harness: `NS_AUDIT_DISPLAY=:78 python3 tools/ui_audit/drive_linux.py … --profile verify-product`
- Fresh scratch profile (`--fresh`), release binary at `apps/desktop/build/linux/x64/release/bundle/skotiq_desktop`
- AT-SPI bound by profile PID (not app name); evidence via `tree` first, cropped `shot` when needed
- Skipped onboarding → connected Simulated Camera/Mount/Focuser/Filter Wheel from Discovery
- Set observing location to lat `35°` / lon `-105°` in Settings → Location

App left running: pid in `/tmp/ns-audit/verify-product/app.pid` on display `:78`.

## Batch results

| Claimed fix | Live verdict | Evidence |
|---|---|---|
| Weather radar opens on oldest frame | **PASS** | Weather with location set shows GOES “Latest image”, “just now”, “Updated 0 sec ago”. Tree: `Latest image` / `This source provides a single live frame`. Shot: `weather-latest.png` |
| Unattended Autopilot title truncated | **PASS** | Plan Tonight empty state shows full title `AUTOPILOT STANDING BY` (not `Unattended Aut…`). Shot: `autopilot-standing-by.png` |
| PolarAlignmentNode missing from palette | **PASS** | Sequencer Nodes search `Polar` → `Polar Alignment` / `Measure polar error by rotating in RA` under Mount. Shot: `polar-palette.png` |
| Loop / Conditional default to no-ops | **PARTIAL** | Both appear in Logic palette (`Loop` / `Conditional`). Could not add nodes via `+` / double-click under softpipe (silent no-op), so INFO no-op badge after add was **not** live-confirmed. Shot: `loop-palette.png` |
| Flat wizard frame count 27-click steppers | **PARTIAL** | Sequencer “Calibrate Flat Exposures” dialog uses a **slider** for frames (quick change; default 25) — different surface than FlatWizardScreen. FlatWizardScreen `_FrameCountInput` TextField exists in code; live `/flat-wizard` gated on profile `cameraId` (session-only sim connect did not assign). Shot: `flat-calibrate-dialog.png` |
| Search hint ⌘K on Linux | **NOT REACHED** | Could not switch Plan Tonight → Planetarium tab (clicks landed on Recommendation content). No live Ctrl+K badge check. |
| Slew split-button primary half | **NOT REACHED** | Imaging Mount panel tab not successfully selected in time. |
| Narrowband mixer zeros | **NOT ATTEMPTED** | Needs science masters / narrowband UI with data. |

## New live findings

1. **Session-only sim connect vs Flat Wizard shortcut** — Connecting sims from Discovery without Assign leaves `cameraId` empty; `_FlatWizardShortcut` returns `SizedBox.shrink()`, so Flat Wizard is invisible despite a live Simulated Camera. Discoverability gap, not necessarily a regression of the frame-count fix.
2. **Node palette `+` / double-click unreliable under this softpipe harness** — `_addNode` appears not to fire from synthetic clicks (sequence stayed at 0 nodes). May be harness/Flutter gesture limitation; not declared a product defect without a manual confirm.

## Production fixes this pass

None. No claimed fix was live-refuted; blocked items were not “fixed from reading.”

---

## Continuation (`cont/`) — same instance

See `cont/NOTES.md` and `cont/verdict.json`.

Highlights: assigned Simulated Camera to profile; Flat Wizard Frame Count **PASS** (TextField `30` + steppers); Planetarium **Ctrl+K PASS**; Imaging Slew named button **PASS** (action not fully exercised); Loop/Conditional still **PARTIAL**; narrowband **NOT REACHED**; Discovery-connect Flat Wizard gap **reproduced** → **needs-decision** (Imaging path still opens wizard).

---

## Residual (`residual/`) — same profile, DB seeded + relaunch

See `residual/NOTES.md` and `residual/verdict.json`.

- **PRODUCT-DECISIONS.md** updated with §24 Flat Wizard Equipment shortcut gating.
- Narrowband mixer defaults **PASS** (HOO preset, non-zero weights).
- Loop/Conditional INFO **BLOCKED** by harness (cannot add nodes under softpipe).
- Deeper Slew **SKIPPED** (mount disconnected after relaunch); prior PASS* kept.
- Production fixes: none.
