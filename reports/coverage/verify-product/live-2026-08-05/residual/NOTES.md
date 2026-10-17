# Live verification residual — 2026-08-05

Reused / relaunched sandboxed instance: `SK_AUDIT_DISPLAY=:78`, profile `verify-product`.
Prior cont pid was stopped so the scratch DB could be seeded; relaunched without `--fresh`
(pid recorded in `/tmp/ns-audit/verify-product/app.pid`).

## PRODUCT-DECISIONS.md

Appended **§24 Flat Wizard Equipment shortcut** (session-connected vs profile-assigned gating)
from `cont/NOTES.md` needs-decision — options + recommendation only; **no code change**.

## Setup this pass

- Seeded scratch DB (app stopped): target NGC 7000, completed session with 4 Ha/OIII lights,
  finalized Ha + OIII `integrated_masters` rows.
- After relaunch: dismissed Continue Session; navigated Analytics → History → session detail →
  **Review & Integrate** (sparkles) → Session Review → **Workbench**.

## Results

| Item | Verdict | Evidence |
|---|---|---|
| Narrowband mixer defaults | **PASS** | Workbench shows `Narrowband mixer` / `HOO preset` with matrix `Ha -> R 1.00 G 0.00 B 0.00`, `OIII -> R 0.00 G 1.00 B 1.00` — not all-zeros / black. Tree: `tree-mixer.txt`. Shots: `mixer-full.png`, `mixer-crop.png`, `workbench1.png`, `session-review1.png`. |
| Loop / Conditional no-op INFO | **BLOCKED** (harness) | Loop visible in Nodes search (`loop-search.png`, `loop-vis.png`). Add attempts all left sequence at **0 nodes**: AT-SPI Tap, double-click, right-click (no context menu), Enter / Insert / Ctrl+Enter / Space / Ctrl+Shift+A, drag-to-canvas. Conditional search + double-click also **0 nodes**. Log: `loop-attempts.json`. Shots: `loop-after-dbl.png`, `loop-ctx.png`, `loop-after-drag.png`, `cond-search.png`, `cond-after-dbl.png`. Cannot live-confirm INFO badge without an added node. |
| Slew one-click (optional deeper) | **SKIPPED** — prior **PASS*** | After relaunch Mount is **Disconnected**; Unpark + above-horizon coords not cheap. Leave cont PASS* (named Slew button present; action not fully exercised). |

## Production fixes this pass

None. Narrowband claim live-confirmed; Loop/Conditional blocked by harness gesture limits (same class as prior passes); no newly reproduced product defect to fix.

## Residual open

- Loop/Conditional INFO badge after successful add (needs manual add or harness that can fire palette `_addNode`).
- Optional Slew action under Unparked + valid coords.
