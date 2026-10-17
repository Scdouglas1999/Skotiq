# Wave D verification — cluster: sky-discovery

Adversarial re-drive of the fixes made after the 2026-08-11/13 `sky-discovery.md`
pass. **No code was changed in this pass.**

**Binary under test:** `apps/desktop/build/linux/x64/release/bundle` —
`libapp.so` and `libskotiq_bridge.so` both built **2026-08-13 18:31**
(the fresh Wave-D bundle). This is a genuinely new binary, not the Wave-B one
the previous report tested.

**Harness:** `tools/ui_audit/drive_linux.py`, `NS_AUDIT_DISPLAY=:85`,
`start --fresh --profile waveD-sky-discovery`. Window 1600x900 unless stated.
Onboarding was skipped; the observing site was set from
Settings → Location to **40.7128, -74.0060** (the same site the original pass
used), so every astrometric number below is comparable with the original report.
Wall clock during the drive: **2026-08-13 18:34–18:50 EDT** (22:34–22:50 UTC).

App log for the whole session: **0** exceptions, **0** `RenderFlex`/overflow
lines, 144 lines total.

---

## Verdicts on assigned findings

| ID | Verdict |
| --- | --- |
| SKY-1 — pause does not pause | **VERIFIED_FIXED** |
| SKY-2 — region create hangs the app | **VERIFIED_FIXED** |
| SKY-3 — RA asked in degrees only | **VERIFIED_FIXED** |
| SKY-5 — planetarium scrub rewrites the Dashboard | **VERIFIED_FIXED** (one residual, see D-1) |
| SKY-6 — DSOs drawn with no angular size | **VERIFIED_FIXED** |
| SKY-7 — search draws two overlapping result lists | **VERIFIED_FIXED** |
| SKY-8 — tooltips unanchored and never retire | **VERIFIED_FIXED** visually; **residual** in the semantics tree (D-2) |
| SKY-15 — Escape does not leave the region detail view | **VERIFIED_FIXED** |
| JD+0.5 dormant bug in `CelestialCoordinate.toHorizontal` | **Confirmed dormant** — not reachable from any live surface (see below) |

---

### SKY-1 — VERIFIED_FIXED

Repro run exactly as written (Plan Tonight → Planetarium → centre transport
button → wait ≥100 s).

- Clicked pause at wall **18:37:11**. The readout froze at **`18:37:07`** and
  the transport label changed from `1×` to **`PAUSED`**.
- **79 s later** (wall 18:38:26) the planetarium readout still read
  **`18:37:07 PAUSED`**, while the global status-bar clock had advanced to
  `18:38:26`. The frozen value is a hold, not a slow clock.
- Clicking the centre button again resumed: 12 s later the readout read
  `18:39:00` with the label back to `1×`, i.e. it re-synced to real now.
- Re-tested at a non-1× rate: pressing ⏩ once put the transport into
  **`+1m/s`** (the readout ran to 19:01:33 while wall time was 18:48:50);
  pressing pause froze it at `19:01:33` and it was still `19:01:33` after 20 s.
- `NOW` returns the readout to real time (`18:49:11` at wall 18:49:12).

The time model is no longer "wall clock + offset with nothing to stop it";
pause holds at both 1× and accelerated rates.

### SKY-2 — VERIFIED_FIXED

Repro: Plan Tonight → Discover → Your Sky → `Name a region` → `Custom RA/Dec`
→ RA `05h 35m 16s`, Dec `-5.39`, radius `0.5`, name `Orion audit region` →
`Create region`.

- Clicked `Create region` at **18:45:06**. By **18:45:09** the dialog was gone
  and the a11y tree showed the Your Sky list again:
  `Regions / 1 region · none imaged yet` and a card
  `Orion audit region / Custom / 5h 35m · -5° 23' / 0s / 0 tiles`.
- No spinner-forever, no modal barrier. `Escape` also dismisses the dialog
  cleanly when it is left open (reopened it, pressed `Escape`, the
  `Create region`/`Cancel` nodes disappeared and only the `Name a region`
  launcher remained).
- The region survived a window resize to 420x900 and back to 1600x900.

### SKY-3 — VERIFIED_FIXED

The field is no longer `RA (degrees) / 0–360`. It is now labelled `RA` with the
hint **`05h 35m 16s or 83.82°`** (Dec: `-05° 23' 24" or -5.39`), a helper line
**"Enter a position in either convention — sexagesimal or decimal."**, and — the
part that actually settles it — a live echo of the parse:

```
Reads as 05:35:16.00 -05:23:24.00 (83.817°, -5.390°)
```

I typed the sexagesimal form the original report said would create a region 79°
away, and it resolved to 83.817° — correct. The created region lists as
`5h 35m · -5° 23'`.

### SKY-5 — VERIFIED_FIXED for the Dashboard; one residual

Repro: Planetarium → step-forward ⏭ ×20 (each = +1 h) → Dashboard.

Baseline before scrubbing (wall 18:36:25): Dashboard `18:36:25 / LST 15:09:53`
labelled Local, `Dark in 3h 4m`, Moon `2%`, imaging window `6h 41m`.
Ground truth computed independently for 22:35:41 UTC at -74.0060°:
**LST 15:09:09** — the app's LST is right.

After scrubbing the planetarium to **Aug 14, 14:39** and returning to the
Dashboard at wall 18:39:38:

| element | shows | truth |
| --- | --- | --- |
| Dashboard header clock (`Local`) | `18:39:38` | 18:39:38 ✓ |
| Dashboard `LST` | `15:13:06` | 15:13 ✓ |
| Dashboard `Dark in` | `3h 0m` | 3h 0m ✓ |
| Dashboard Moon | `2%` | 2% ✓ |
| Status-bar LST (after leaving) | `15:13` | 15:13 ✓ |

Every element the original finding listed is now correct. The simulated time is
also **screen-scoped and ephemeral**: navigating away and back to the
Planetarium resets it to `NOW` (verified — returned to `Aug 13, 18:39:58`).

**Residual — D-1 below.** While you are *on* the Planetarium screen with a scrub
active, the global status bar's LST still tracks the simulated time.

### SKY-6 — VERIFIED_FIXED (with measurements)

Repro: search `M31` → select → wheel-zoom to FOV 2.0°.

Extended objects are now drawn as oriented ellipses at catalogue size. At
FOV 2.0° M31 no longer fits in the field — its ellipse runs off both edges —
and M32 and M110 are visibly different sizes and orientations from each other
(previously "three identical dots").

Quantitative check at **FOV 5.4°** (`m31-6deg.png`, canvas 580 px tall =
107.4 px/deg):

| quantity | expected (M31 = 178' × 63', PA 35°) | measured on screen |
| --- | --- | --- |
| major axis | 2.967° → 318 px | ~310 px |
| bounding-box width | 200 px | 209 px |
| bounding-box height | 262 px | 268 px |

Position angle and companion placement are right too: M32 sits 43 px (0.40° =
24') south of the M31 centre, which is its true offset; M110 sits north-west.

### SKY-7 — VERIFIED_FIXED

The search overlay was rebuilt as a right-hand side panel with
`Tonight / Catalog / Lists / Search / Info` tabs. Typing `M31` produces **one**
list. The a11y tree contains a single run of `button:` result rows
(`M31 / M - Andromeda Galaxy - Galaxy / mag 3.4`, `31 Cygnus`, `M41`, …) and
**no** second `panel: 74 results / Deep Sky Objects (25) / …` list. The
screenshot shows no clipped rows bleeding out from behind a narrower panel.

### SKY-8 — VERIFIED_FIXED visually; residual in the a11y tree

**Anchoring is fixed.** Hovering the toolbar icon at image x=399 (root 659,264)
drew its tooltip `Equatorial view — tap for Alt/Az` at x 325–478, y 128–150 —
horizontally centred on the button (399) and 48 px below it. Same for
`Search the sky` under the search box. No more 176 px lateral drift.

**Nothing stale is painted.** After hovering six toolbar controls in sequence
and then parking the pointer over the star field, the screenshot
(`tt-stale.png`) shows **zero** tooltips drawn.

**Residual — D-2 below:** the semantics tree keeps the tooltip nodes alive.

### SKY-15 — VERIFIED_FIXED

Opened the `Orion audit region` detail route (full-screen, tab bar hidden),
pressed `Escape`, and the tree went straight back to the Plan Tonight tab bar
(`Recommendation / Projects / Schedule / Framing / Planetarium / Discover`).

### JD+0.5 / `CelestialCoordinate.toHorizontal` — confirmed dormant

The bug is real in source: `coordinate_system.dart:103` `_julianDate()` omits
both `.toUtc()` and the trailing `- 0.5`, so it returns JD + 0.5 ≈ 12 sidereal
hours of GMST error (the file's own doc comment says so).

It is **not reachable from the running app**:

- The only non-test callers are `sky_view.dart:213/272/277/319`, inside the
  `SkyView` widget.
- `SkyView` is **never instantiated anywhere** in `packages/` or `apps/` — the
  live renderer is `InteractiveSkyView` / `FullScreenSkyView`, which are
  different classes. `SkyView` is dead code that is nonetheless exported from
  the package barrel (`skotiq_planetarium.dart:5`).

Cross-checked three live alt/az surfaces against hand computation for
40.7128 N / -74.0060 W, and they all agree with truth (so there is no ~12 h
discrepancy between surfaces to find):

| surface | app | hand-computed |
| --- | --- | --- |
| Planetarium `Selected Alt / Az` for M31 at LST 15:13 | `-1.2° / 27.0°` | -1.17° / 27.4° |
| Plan Tonight → Recommendation card, NGC7094 at 18:36 | `Alt 3.2°` | 3.32° |
| Status-bar / Dashboard LST at 22:35:41 UTC | `15:09:53` | 15:09:09 |

The rendered sky is also visibly correct for an August evening at 40°N (Vega,
Arcturus, Hercules, Corona Borealis, Draco, Ursa Major at the zenith); a 12 h
sidereal error would have drawn the winter sky.

**Recommendation (not a fix, a record):** the safe close-out is to delete
`SkyView` and its barrel export rather than to "correct" `_julianDate`, since
correcting it changes nothing a user can see and re-pointing it at
`AstronomyCalculations.julianDate` would break `coordinate_system_test.dart`'s
asserted values.

---

## New findings from the adversarial sweep

### D-1 — P3 — While the planetarium is scrubbed, the global status bar shows a simulated LST next to a real clock

**Screen:** Plan Tonight → Planetarium (status bar, bottom right).
Residual of SKY-5.

Repro:
1. Planetarium. Click ⏭ six times (+6 h).
2. Read the bottom-right status strip.

Actual, reproduced three times:

| wall | planetarium reads | status-bar clock | status-bar LST | true LST |
| --- | --- | --- | --- | --- |
| 18:39:24 | Aug 14, 14:39 | `18:39:23` | `11:15` | 15:12 |
| 18:40:11 | Aug 14, 00:40 | `18:40:10` | `21:14` | 15:14 |
| 18:49:43 | Aug 14, 00:49 | `18:49:43` | `21:24` | 15:22 |

The two readouts sit ~15 px apart in the same strip; the clock is real, the LST
is fictional, and nothing marks the difference. Navigating to any other screen
restores the real LST, so the blast radius is one screen — which is why this is
P3 and not a re-open of SKY-5. But it is the same shape as the original defect:
a number a user plans by, silently redefined by a preview control.

### D-2 — P3 — Planetarium tooltips are never removed from the accessibility tree

**Screen:** Plan Tonight → Planetarium toolbar. Residual of SKY-8's second half.

Repro:
1. Planetarium. Hover the toolbar icons at image x = 369, 399, 428, 467, 508 in
   turn (≈1.6 s each).
2. Park the pointer over the star field at root (900,900) and wait 12 s.
3. `drive_linux.py tree --all`.

Expected: no tooltip nodes, since none are drawn.
Actual: three tooltip panels are still in the tree —
`Search the sky`, `Reset view (zenith, FOV 60)`, `Equatorial view — tap for
Alt/Az` — and a fourth (`Layers`) joins them while x=467 is hovered. They
accumulate as you hover and are never removed. Nothing is painted
(`tt-stale.png` is clean), so this is an assistive-technology-only defect: a
screen reader walking the planetarium finds up to four floating strings that
belong to controls the user is not on.

### D-3 — P3 — The five time-transport buttons have no accessible name

**Screen:** Plan Tonight → Planetarium → time transport.

`tree --all` of the transport row:

```
panel: Aug 13, 2026 [DISABLED]
button:            <- rewind / rate down
button:            <- step back 1 h
button:            <- play / pause
button:            <- step forward 1 h
button:            <- fast forward / rate up
button: NOW
button: TONIGHT
```

`NOW` and `TONIGHT` are named; the five icon buttons beside them are not, and
the play/pause button does not expose a toggle state either — the only signal
that time is stopped is the `PAUSED` string inside a merged text panel. A screen
reader user cannot tell which of the five buttons pauses, nor whether it is
currently paused. (The visual pause fix in SKY-1 did not carry into semantics.)

Also in that dump: the date chip `Aug 13, 2026` is reported **`[DISABLED]`**
even though it is the control that opens the date picker, and the whole
bottom readout strip (`Center RA / Center Dec / FOV / Bortle`) plus the search
field are likewise reported `[DISABLED]`.

### D-4 — P4 — At 900 px width the open Layers drawer covers part of the time transport

**Screen:** Plan Tonight → Planetarium, window 900x900, Layers open.

The Layers drawer is an overlay pinned to the right edge (x ≥ 620 of 900) while
the transport stays centred on the full canvas (x 432–700). The result
(`narrow-plan.png`): the clock is clipped mid-digit (`18:46:` with the seconds
under the drawer) and the fast-forward button is behind the drawer and cannot be
clicked. The same overlap hides the right third of the "Chart is shallower than
the sky" banner. At 1600x900 and at 420x900 (where the transport collapses to a
compact pill and the drawer becomes full-width) there is no overlap.

---

## Prior findings I saw still reproducing (not assigned to me)

| ID | Status in this binary | Evidence |
| --- | --- | --- |
| SKY-4 — `Create region` clickable with no target | **Still reproduces.** In `From a target` mode with an empty library the button renders dim but the a11y tree reports `button: Create region` with **no `[DISABLED]`**; clicking it leaves the dialog open with no error, no toast and no new text anywhere in the tree. |
| SKY-10 — wheel zoom ignores the pointer | **Still reproduces.** Wheel-up 23 notches with the pointer at root (885,638) took FOV 60.0° → 2.0° with the centre byte-identical at `Center RA: 0h 42m 44s / Center Dec: +41° 16'`. |
| SKY-16 — desktop UI says "tap" | **Still reproduces.** The coordinate-mode tooltip reads `Equatorial view — tap for Alt/Az`. |

## Prior findings I incidentally saw fixed (not assigned to me)

| ID | Evidence |
| --- | --- |
| SKY-17 — layer switches expose no state | **Fixed.** All 17 rows are now `toggle button: <name> [ON]`/`[off]` — `Stars [ON]`, `Survey imagery (DSS, below 8°) [off]`, `Deep-sky objects [ON]`, `DSO labels [ON]`, `Constellation lines [ON]`, … `Cardinal directions [ON]`. No more inert `panel: … [DISABLED]` rows. |
| SKY-12 — readout overprints object labels | Improved: the readout strip now sits on its own darkened band and was legible in every capture. Not exhaustively re-driven. |

## Coverage of the adversarial sweep

- **Widths:** 1600x900 (primary), 900x900, 420x900. Screens re-checked at each:
  Planetarium (toolbar, transport, Layers drawer, readout strip), Discover →
  Your Sky (empty state, region list, `Name a region` dialog in both modes).
  At 420x900 the dialog becomes a bottom sheet with a drag handle and the
  `RA` / `Dec` pair stays side-by-side without truncating the hint text; no
  overflow warnings in the log at any width.
- **Banner order:** only one banner was ever live in this cluster (`Chart is
  shallower than the sky`, an honest disclosure with a `Configure` action). It
  renders top-left of the canvas and does not stack or reorder. No banner
  regression to report beyond the D-4 occlusion.
- **Semantics:** full `tree --all` dumps taken on the Planetarium (idle, search
  open, Layers open, paused, scrubbed), Your Sky (empty, one region, dialog in
  both modes, region detail) and the Dashboard. Findings D-2 and D-3 came out
  of those dumps.
- **Not driven:** Framing, Constellation, Collaborate, First Light — outside the
  assigned IDs and unchanged in scope from the original pass's "could not reach"
  list (they still need a connected camera / a reachable hub / atlas depth).

## Artifacts

Captures for this pass are in
`/tmp/claude-1000/-home-scdouglas-Documents-Skotiq2/224b7868-cbfc-40e1-8fb0-99c71d23f174/scratchpad/`:
`m31-2deg.png`, `m31-6deg.png`, `search1.png`, `tt-layers.png`, `tt-stale.png`,
`region-dlg2.png`, `yoursky1.png`, `narrow-plan.png`, `phone-plan.png`,
`phone-dlg2.png`, `statusbar-lst.png`. App log:
`/tmp/ns-audit/waveD-sky-discovery/app.log`.
