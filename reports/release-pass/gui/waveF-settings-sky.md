# Wave F — dryness check: `settings-sky`

Cluster: `settings-sky` · display `:85` · profile `waveE-settings-sky` (`start --fresh`)
Bundle driven: `apps/desktop/build/linux/x64/release/bundle/skotiq_desktop`
(`lib/libapp.so` + `libskotiq_bridge.so` both **Aug 13 23:56**, i.e. the post-E-fix build).
Harness: `tools/ui_audit/drive_linux.py` (profile AFTER the subcommand), 1600×900 unless noted.
Shots: `/tmp/ns-audit/waveF-ss/shots/`.

Charter: verify SET-12, WE-SP-1..5, D-2, D-3, E-SKY-1/2/3 against
`reports/release-pass/impl/efix-settings-sky-3.md` + the Wave-E evidence, then one adversarial
sweep. **Nothing was fixed in this pass.**

Result: **9 verified fixed, 2 still broken, 4 new findings.** The cluster is NOT dry.

---

## Verified fixed (9)

### SET-12 — the dashboard tour no longer narrates absent panels
Fresh onboarding → Dashboard (panels present: Tonight's Briefing + twilight bar, Tonight's
targets, Readiness, Last run, Moon) → **Start Tour**, then `Right` with a tree dump after each
press:

```
Tutorial step 1 of 12: Welcome to Dashboard
Tutorial step 2 of 12: Customize Layout
Tutorial step 12 of 12: Dashboard Complete      <- 3..11 passed over in ONE press
```

and backwards from 12: `2`, `1`, `1`. Wave E parked on and announced `6 of 12: Weather Status`
and `11 of 12: Active Sequence`; neither string appears anywhere now (`grep -ci 'weather
status\|active sequence'` over the session log = 0). The pass-over is a real jump, not a walk.

*Caveat on the two-implementations guard:* the batch's `TutorialOverlay pass-over: …` marker is
**not** in `app.log` (`grep -ci "pass-over"` = 0). The log is only 144 lines and carries no
`developer.log`-named entries at all, so this is most likely a capture limitation, not evidence
of the wrong widget — the on-screen behaviour is decisive on its own.

### WE-SP-1 — the onboarding device picker no longer clips the selected row
Step 6 (filter wheel) with both backend-error lines present (`Alpaca: nothing answered…`,
`INDI: nothing answered…`) and Simulated Filter Wheel selected: the picker auto-scrolls, the
selected card renders **whole** (border + "Sim" subtitle intact, `06b-fw-sel.png`) and a
scrollbar thumb is drawn at the picker's right edge at rest. Re-entering the step via Back →
Next reproduces the same revealed-and-scrollbarred state (`06d-reenter.png`), which is the
s60/s61 case the fix called out. What is clipped now is the *row above* (the Scan again strip),
i.e. ordinary scrolled-out content with a visible scrollbar — not the row the operator just
touched.

### WE-SP-2 — the click after "Reset All Progress" is now visibly absorbed
Settings → Help & Tutorials → Reset All Progress → Reset. The first-launch tour
(`Step 1 of 7 — Welcome to Skotiq`) mounts over the app, as the batch diagnosed. One click on
the **Dashboard** rail item: the card **stays on screen** (`47-afterrailclick.png` is pixel-
identical to `46-afterreset.png`) and — the cry-wolf half — the rail does **not** repaint
Dashboard as selected; Help & Tutorials stays highlighted. `Escape` then dismisses the tour and
the next rail click navigates to the Dashboard (`48-afterescape.png`). A modal that stays up
explains why the click did nothing.

### WE-SP-3 — pairing empty state now passes AA
`Start pairing mode to connect a device` measured on the raw capture `17-pair-raw.png`:
brightest glyph `rgb(154,163,173)` against background `rgb(24,28,34)` → **6.69:1** (was 1.31:1).

### WE-SP-4 — the pairing card is no longer one button, and copy confirms itself
`tree --all` during pairing mode:

```
panel: Pair New Device
  panel: Enter this code on your device:
  panel: Pairing code: VEGA-NOVA-5026
  button: Copy code
  panel: Expires in 04:55
  button: Cancel Pairing
```

Four separate nodes where Wave E had one `button:` carrying all four strings. Clicking **Copy
code** changes the control's label to `Pairing code copied to clipboard` **and** raises a green
snack bar with the same text (`20-copied.png`). (The clipboard write itself is still unverifiable
on this box — no `xclip`/`xsel`.)
**But the new control is drawn at 1.15:1 — see WF-SS-N1.**

### D-3 — the search box and the readout strip publish themselves correctly
Same dump, planetarium:

```
button: Search the sky (Ctrl+K)      <- was `panel: Search / Ctrl+K [DISABLED]`
panel: Sky time 00:08:18
panel: Time running at 1×
panel: Center RA 20h 38m 6s
panel: Center Dec +40° 0'
panel: FOV (short axis) 60.0°
panel: Bortle 5 (lim 5.9m)           <- was ONE `panel: … [DISABLED]` blob
```

No `[DISABLED]` on any of them, and every readout carries label **and** value. Clicking the
search box still opens the object panel with the field focused (`52-search.png`), so the
`Semantics(button:, excludeSemantics:)` wrapper did not eat the tap.

### E-SKY-1 — the transport no longer collides with the instruments
`resize 900 900` → Planetarium → Layers open: the transport **lifts** to x 275–566 / y 557–680
while the compass (240–315, y 730–805), the altitude bar and the horizon minimap (508–600,
y 705–820) sit below it — zero overlap (`39b-900drawer.png`). At 1100×900 it **centres** between
compass and minimap (transport 405–660, compass 240–330, minimap 705–800, `51b-1100.png`), and at
1600×900 with the drawer open there is no overlap either (`40-1600drawer.png`). Three widths,
three branches, no collision.

### E-SKY-2 — play/pause name and state now agree
Running: `panel: Time running at 1×` + `button: Pause time`.
After one click: `panel: Time paused` + `button: Play time`, with the `PAUSED` chip and the play
glyph on screen (`37-paused.png`). No toggle state on the button at all, so there is nothing left
to contradict.

### E-SKY-3 — the guide-graph selectors publish label AND value
Guiding, `tree --all`: `button: Time: 5m` and `button: Scale: ±2"` — both enabled buttons, no
`[DISABLED]`, value inside the accessible NAME. Selecting `15m` from the menu updates the node to
`button: Time: 15m`, so the name tracks the selection rather than being a fixed string.

---

## Still broken (2)

### WE-SP-5 (P4) — the "Build tonight's plan?" nudge still covers Moonrise
Dashboard with an observing site set, scrolled to the **hard bottom** (12 wheel notches, then 15
more with zero further movement). The floating prompt occupies x 537–920 / y 537–645 and the Moon
card's `Moonrise` row sits at y≈634 — its label is visible, its value is not
(`25-dashbottom.png`). Decisive control: dismissing the prompt with **Not now** at the identical
scroll offset reveals `08:12` at exactly that y (`28-nonudge.png`, vs `26-dashbottom2.png`),
and no content moved when the prompt left. The `kFloatingPromptReservedHeight` band the fix adds
to `DashboardScrollView` has no effect on this layout: max scroll is the same with and without
the prompt, so the last card is never lifted clear.

Same class, second surface, found in the sweep: at 1100×900 the **Planetarium Tour** nudge is
drawn over the open Layers drawer and hides the `Constellation art` / `Milky Way` rows
(`51b-1100.png`). Floating prompts are still painted over docked content generally, not only on
the dashboard.

### D-2 (P3) — one planetarium tooltip still never leaves the a11y tree
Narrowed, not closed. Of the five command-bar icons, four are now clean; the **projection
cycler** (root x=536, y=114) is not.

Decisive sequence on a freshly mounted Planetarium (tab away to Recommendation, back, pointer
parked at 1300,1000):

```
never hovered                       grep "Projection: Stereographic" = 0
hover 536,114 for 3 s               = 1
pointer away, +15 s                 = 1     screen is CLEAN (36-d2-clean-screen.png)
pointer away, +35 s cumulative      = 1
re-hover, leave again               = 1     (it never retires, and re-showing does not reset it)
```

The node lives under a button with **no accessible name**:

```
button:
  panel:
    panel: Projection: Stereographic
```

which is the tell — the other four icons carry their message on the trigger as
`Semantics(tooltip:)` (`button: Reset view (zenith, FOV 60)`, `button: Equatorial view — switch to
Alt/Az`, `button: Layers`) and leak nothing, so this control is not the widget the
`ExcludeSemantics` + timer fix in `skotiq_tooltip.dart` was applied to. Tooltips still *show*
normally everywhere (`49-icon5.png`, `50-icon2.png`), so the fix did not break the component.

---

## New findings from the adversarial sweep (4)

### WF-SS-N1 (P3) — the new "Copy code" button is drawn at 1.15:1, worse than the 1.31:1 the same batch just fixed
`WE-SP-4` replaced the nameless `IconButton` with a named `SkotiqButton`, but the button
paints its label in `textSecondary` `rgb(154,163,173)` on the pairing card's **accent fill**
`rgb(91,158,196)` → **1.15:1** (measured over the label's bounding box in `19-code-raw.png`; the
label is 26 px of near-background grey on 2902 px of blue). On screen the control reads as a
disabled ghost (`18-code.png`) until you click it, at which point the confirmation chip — dark
fill, light text — is perfectly legible. The regression is only in the idle state, and it is on
the one control the same fix batch made visible.
Repro: Settings → Notifications & Remote → Remote Access → Manage Pairing → Start Pairing Mode →
look under the code.

### WF-SS-N2 (P3) — the pairing screen is a pushed route the nav rail cannot escape, and the rail claims otherwise
From `Remote Connection Pairing`, one click on the **Dashboard** rail item repaints that row in
the selected treatment (accent bar + bold, `21-dash2.png` vs `20-copied.png`) and leaves the
pairing screen on screen. Fourteen seconds later `tree` still returns
`header: Remote Connection Pairing`. A **second** click changes nothing either (`23-dash4.png`).
Only the screen's own back arrow escapes — and when it does, the app lands on the **Dashboard**,
not on Remote Access (`24-afterback.png`), proving the rail had silently re-pointed the shell
underneath a route that stayed on top.
Not the WE-SP-2 mechanism: no tour, no scrim, and the same rail click **does** navigate correctly
from the Settings screen itself (`29-settings.png` → `30-afterrail.png`), so this is specific to
pushed sub-routes.
Repro: Settings → Notifications & Remote → Remote Access → Manage Pairing → click "Dashboard" in
the rail, twice.

### WF-SS-N3 (P3) — two planetarium command-bar controls still publish no accessible name
On every dump of the command bar:

```
button: Search the sky (Ctrl+K)
button: Reset view (zenith, FOV 60)
button: Equatorial view — switch to Alt/Az
button:                       <- the projection cycler (tooltip "Projection: Stereographic")
button: Layers
panel:
  button:                     <- "Tools"
button: Plan / object panel
```

Identified by hovering each icon and reading the painted tooltip: root x=536 is
`Projection: Stereographic`, root x=636 is `Tools` (`49-icon5.png`, `50-icon2.png`). D-3's fix
named `CommandBarIconButton` from its tooltip; these two are evidently not that widget. The
projection one is also the sole remaining D-2 leak above, so both symptoms have the same owner.

### WF-SS-N4 (P4) — the tutorial overlay card publishes itself as interactive-but-dead
Every step of the dashboard tour dumps as
`panel: Tutorial step 1 of 12: Welcome to Dashboard [DISABLED]`. The harness prints `[DISABLED]`
on a `panel` only when the node is focusable/selectable/checkable *without* `enabled`/`sensitive`
— the exact shape D-3 identified and repaired on the planetarium readout strip, still present on
the surface SET-12 covers. Cosmetic for sighted users; for AT it is a focus stop that reports
itself unavailable.

---

## Notes / non-findings

* The reserved band under Help & Tutorials still clips the first `Tutorial Tours` row while a
  nudge is up (`43-help.png`); everything scrolls, so this remains the intended trade Wave E
  recorded, not a defect.
* Tooltips still appear and dismiss visually on all five planetarium icons; the D-2 residual is
  a semantics-tree leak only, with a clean screen at the same instant.
* `Skip onboarding` was not used — the onboarding was walked to completion (optics 600/100/3.76,
  capture folder `/tmp/ns-audit/waveF-ss/captures`) so the dashboard under test is the real
  post-onboarding one.
