# Live verification continuation — 2026-08-05 (cont/)

Reused sandboxed instance: `SK_AUDIT_DISPLAY=:78`, profile `verify-product`, pid `2948528`.

## Setup this pass

- Navigated Equipment; confirmed **session-only** sims (profile `0 devices`, yellow “This session only… Use Assign in Discovery”).
- Assigned **Simulated Camera** via Discovery → Assign → My Equipment `(empty)`.
- Profile became `1 devices`; Flat Wizard Open appeared on Equipment status rail.
- Snackbar: `Assigned Simulated Camera to My Equipment`.

## Results

| Item | Verdict | Evidence |
|---|---|---|
| Flat Wizard frame-count TextField (vs 27-click steppers) | **PASS** | Opened Flat Frame Wizard from Imaging → Camera → Flat Wizard. Live UI: `Frame Count` / `Frames:` with **TextField showing `30`**, flanked by `−` / `+`. Tree: `Frame Count`, `Frames:`, `0/30`. Shot: `flat-frames.png`, `frames-row.png`. (Harness could not reliably commit a typed `5`; visual + tree confirm direct-entry field exists.) |
| Loop / Conditional no-op INFO badge | **PARTIAL** | Prior pass: both in Logic palette (`loop-palette.png`). This pass: Sequencer Builder open with empty InstructionSet; Nodes search/add still unreliable under softpipe (Queue tab confusion / synthetic type into Search). **Could not add Loop/Conditional to tree** to live-confirm INFO badge. Rule remains in `logic_node_rules.dart` `NoOpLogicNodeRule`. |
| Planetarium Ctrl+K (not ⌘K) | **PASS** | Plan Tonight → Planetarium. Tree: `Search` / `Ctrl+K`. Crop: `ctrlk-crop.png`. Shot: `planetarium-ctrlk.png`. |
| Imaging Slew split-button primary | **PASS*** | Imaging → Mount → GoTo/Sync. Tree: named `button: Slew` (real button node). Visual: Slew beside Sync (`slew-crop-final.png`, `slew-after-scroll.png`). *One-click slew action not fully exercised (mount Parked / below horizon); chevron “More slew options” not separately listed in AT-SPI dump. |
| Narrowband mixer defaults | **NOT REACHED** | Analytics → “No session history”; no masters/session to open Session Review narrowband mixer. |
| Session-connect vs profile Flat Wizard gap | **REPRODUCED** — see below | `equipment-now.png`, `after-assign-cam.png`, trees. |

## Discovery-connect vs profile Flat Wizard

**Reproduced live:** with Simulated Camera connected but profile `cameraId` empty:

- Equipment cards show session-only warning + “Use Assign in Discovery”.
- Profile shows `0 devices`; status rail “No devices are assigned…”.
- Equipment Flat Wizard shortcut absent (`_FlatWizardShortcut` → `SizedBox.shrink()` when `profile.cameraId` empty).
- After Assign → Flat Wizard Open appears; Imaging → Camera → Flat Wizard also opens wizard.

**Product call (not silently fixed):** Wizard is **not fully unreachable** — Imaging → Camera → Flat Wizard is available without profile assignment. Equipment rail shortcut alone is profile-gated. Session-only / Assign messaging already exists on cards, Connect tooltip, and Ready-to-image. Treat as **needs-decision** (discoverability of Equipment shortcut vs requiring profile for that entry), not an unannounced product-policy change.

Options for owner:

1. Keep current: Equipment shortcut requires assigned camera; Imaging path remains for session-connected.
2. Show Equipment shortcut when any camera is connected (session or profile).
3. Show a disabled/prompt card (“Assign a camera to open Flat Wizard”) instead of hiding.

## Production fixes this pass

None.

## Residual open

- Loop/Conditional INFO badge after add (harness add-node limitation).
- Narrowband mixer (needs science masters / session review data).
- Slew one-click action under Unparked + valid coordinates (optional deeper retest).
- Flat Wizard Equipment shortcut gating — needs-decision.
