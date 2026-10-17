# Wave D verification — cluster: collab-catalogs

Driven live on `NS_AUDIT_DISPLAY=:87`, profile `waveD-collab-catalogs`, fresh scratch profile,
release bundle `apps/desktop/build/linux/x64/release/bundle` (binary + `libskotiq_bridge.so`
both dated 2026-08-13 18:31), window 1600x900. Onboarding skipped; site set to 40.02 / -105.27 via
Settings -> Location (LST started ticking, so the site took).

Screenshots: `/tmp/ns-audit/shots-waveD-collab/`.

Verdicts below are against the exact repro in `reports/release-pass/gui/collab-catalogs.md`.

---

## Verdicts

### COL2-16 — "Create mosaic project" is a silent no-op — VERIFIED_FIXED

Repro run: Analytics -> Projects -> "Mosaic projects" -> "New mosaic".

Blocked state (no equipment profile, panel size unknown): the footer now carries a permanent
inline reason directly left of the button — "Panel size unknown, so there is nothing to lay a grid
out from. Set a focal length in Settings and connect the camera, or type the panel width and
height under Advanced (numerical)." Clicking Create in this state still does nothing, but the
reason is on screen the whole time rather than absent (`09-create-click.png`).

Unblocked: Advanced (numerical) -> Panel width 60, Panel height 40. The blocking footer text and
the "Panel size unknown" card both disappear, Plan summary flips from `Panel size: unknown` to
`1.00° x 0.67°`, and the Create button becomes visually filled/primary (`14-panelsize.png`).
Clicking "Create mosaic project" then **creates the project and navigates to it**: header
`Mosaic 23.89h 0.0°`, `5 wide x 3 high · 15 panels · 23:53:38.40 +00:00:00.00 · 0 integrated`,
`Status: Planning`, and a Panels grid with exactly 15 tiles (`19-project.png`, tree). The mosaic
project screen — unreachable in the original pass — is now reachable.

Note the created centre `23:53:38.40` = 23.894 h, i.e. the wrapped centre, not the 144° unwrapped
mean that wave 1's COL-7 recorded on the publish path.

Residual (not a re-open of COL2-16): in the blocked state the accessibility tree still reports
`button: Create mosaic project` with no `[DISABLED]` state while the button refuses to act. See
WD-COL-N2.

### COL2-17 — wizard contradicts itself about panel size — VERIFIED_FIXED

Repro run: open the wizard with no equipment profile, expand "Advanced (numerical)", scroll.

- The warning card is still there but now names the in-dialog remedy: "No equipment profile with a
  focal length, so the panel field cannot be measured. Set a focal length in Settings and connect
  the camera, **or enter the panel width and height yourself under Advanced (numerical) below** —
  either one lets the grid be laid out." (`08-wizard.png`)
- Panel width / Panel height are now **empty** (placeholder-only), not the pre-filled 60.0 / 40.0
  that made the dialog contradict itself (`13-advanced2.png`).
- Typing into them **does** clear the warning and change the summary (`14-panelsize.png`), which is
  exactly what COL2-17 said did not happen.

Remaining wrinkle, recorded but not counted as still-broken: with panel size unknown, Plan summary
still prints "Est. time (14m/panel x 10 subs): 2.3 h" and "Total exposures: 90". Those two are
functions of panel count and subs only, not of panel size, so they are not the contradiction
COL2-17 named.

### COL2-15 — RA-seam preview omits panels — VERIFIED_FIXED

Repro run (panel size supplied so the grid can be laid out, per the new gate):

1. 3x3, RA 0.000h — summary "Active panels: 9, Grid: 3x3"; the preview draws **9** cells, labelled
   1..9 (`08-wizard.png`, `15-top.png`). Original: 6.
2. Columns "+" twice -> 5x3, summary "Active panels: 15" — the preview draws **15** cells, labelled
   1..15 (`16-grid5.png`). Original: 9.
3. Centre moved across the RA 0h seam by typing Center RA = 23.894 h (the harness has no drag
   command; this is the same state the original reached by dragging — the header reads
   `RA 23.894h`). The preview still draws **15** cells, 1..15, contiguous, with no column dropped
   (`18-ra23.png`). Original: 12, with the far-side column missing.

The panel span at 23.894 h with 5 x 1.00° panels really does cross 0h (23.894 h ± ~0.12 h), so the
wrap case is exercised. Creating from that state produced a project whose centre is 23:53:38.40 —
the wrap is handled on the create path too.

### COL2-1 — MPC card claims MPCORB but downloads the bright-asteroid list — VERIFIED_FIXED

Settings -> Imaging -> Catalogs -> "Minor Planets & Comets (MPC)". Card copy is now, verbatim:
"Downloads the Minor Planet Center's current bright-asteroid elements (**Soft00Bright — the few
hundred asteroids bright enough to observe, not the full MPCORB**) and its comet elements
(CometEls). Refreshed bodies appear in the planetarium overlay and search. Satellite TLEs
(CelesTrak) refresh on their own 24-hour cache when the satellite layer is on." The status line
is also labelled: "Oldest source updated 2026-08-13 - **312 bright asteroids**, 762 comets", so the
count no longer reads as a truncated MPCORB (`27-mpc.png`).

### COL2-2 — "Refresh Now" gives no progress and no completion feedback — VERIFIED_FIXED (with a residual)

Clicking "Refresh Now" and reading the tree immediately: the button's accessible name becomes
`button: Refreshing…`, and on screen it is dimmed along with the Auto-refresh dropdown
(`28-mpc-inflight.png`). The dead-button ambiguity the finding was about is gone, in both channels.
The fetch is real: `~/.local/share/com.skotiq.desktop/catalogs/mpc_asteroids.txt` and
`mpc_comets.txt` were rewritten at 18:41:50/51 by the click.

Residual: there is still no explicit completion confirmation. Trees at T+2 s and T+4 s after the
click show no snackbar and no "last refreshed just now"; the only signal is the status-line date,
which does not move when a refresh happens twice on the same day (it read 2026-08-13 before and
after). Minor next to the original finding, but a same-day re-refresh still looks like nothing
happened once the button snaps back.

### COL2-3 — Deep-Star "Download" with an empty tileset URL is a silent no-op — STILL_BROKEN

Settings -> Imaging -> Catalogs -> "Deep-Star Tier (Tycho-2 / Gaia)", "Tileset base URL" empty.
Clicked "Download" twice, capturing within ~1 s each time (`26-deepstar-click.png`):

- no snackbar, no inline error, no field highlight — the card is pixel-identical before and after;
- the accessibility tree still reports `button: Download` with **no** `[DISABLED]` (the harness does
  print `[DISABLED]` for interactive roles — `panel: Advanced (numerical) [DISABLED]` and
  `0 connected [DISABLED]` appear in the same session's dumps — so this is the app's state, not a
  missing instrument);
- `drive_linux.py log --tail 8` shows only device-discovery lines.

Unchanged from the original finding.

### COL2-7 — top-ranked imaging target is a bare naked-eye star typed "Star" — VERIFIED_FIXED

Plan Tonight -> Recommendation with the site set.

- Sort: Score — the first three candidates are NGC7094 (Planetary Nebula, mag 13.4, 98), M15 /
  NGC7078 (Globular Cluster, mag 6.3, 98), NGC7080 (Galaxy, mag 12.4, 98). No bare star.
- Sort: Magnitude — the first candidate is M31 / NGC0224 (Galaxy, Mag 3.4), not the mag-2.2
  "gam Cyg / IC1318" the original recorded. The screen and the accessibility tree agree on M31
  (`33-cands-mag.png` plus tree), so wave 2's COL2-8 stale-card symptom did not reappear either.
- Searching the candidate box for `1318` returns "**12 matches for "1318" outside tonight's scored
  candidates**", listing `Star · mag 2.2 · Cyg · RA 20h 22m 13.7s Dec +40° 15' 24.1"` (gamma Cygni)
  under that heading, while "1199 candidates were scored, **0 passed the filters**". Stars are out
  of the scored imaging pool and are labelled as such when search surfaces them.

Note for the catalogue owners, not a defect of this finding: the *nebula* IC 1318 is not in the
scored pool at all — searching "IC 1318" only returns star/double-star matches.

### COL2-11 — "No active alerts" without ever having checked — VERIFIED_FIXED

Plan Tonight -> Transient Alerts.

1. The card header now carries a **refresh** control (⟳) next to the expand chevron and the gear
   (`35-top.png`) — the missing "way to check" from the finding.
2. Ran the original repro: gear -> tick AAVSO, untick TNS -> Close. The card no longer says "No
   active alerts". Collapsed it reads "**No alert source is being checked**"; expanded it adds
   "Nothing was polled — AAVSO (Variable Stars): this build has no AAVSO feed."
   (`37-transient-expanded.png`). Both strings are in the accessibility tree.
3. Each unpollable source now says so in the settings dialog itself: AAVSO / MPEC / CBAT are
   subtitled "Not polled — this build has no live feed for it; alerts from it can still be entered
   by hand"; TNS keeps "Requires TNS bot credentials in Science settings".

The ambiguity the finding was about — "no alerts" versus "we never asked" — is resolved in the
honest direction, and the honest TNS state was not lost.

### COL2-13 — Auto-queue threshold hard-coded to mag 10 — STILL_BROKEN

Transient Alert Settings (`36-transient-settings.png`). "Magnitude Threshold — Only show objects
brighter than this magnitude" is a 5–20 slider; directly below, "Auto-queue bright transients —
**Automatically add transients brighter than mag 10 to targets**" is still a fixed number with no
control of its own.

Adversarial check that the 10 is genuinely fixed rather than derived: I dragged the slider from
15.0 to **8.0** (tree: `slider: 8.0`, chip `<= 8.0`) and re-read the auto-queue row — it still says
"brighter than mag 10". So the app now claims it will auto-queue objects two magnitudes fainter
than the ones it will even show. Unchanged from the original finding, and the contradiction is
demonstrable in both directions.

### Mosaic resume banner above the panel-size warning — NOT VERIFIED LIVE

I could not manufacture the precondition. The banner is gated on the native sequencer reporting an
interrupted checkpoint whose sequence name starts with "Mosaic " (`_probeForInterruptedMosaic` in
`packages/skotiq_app/lib/screens/sequencer/widgets/mosaic_wizard_dialog/wizard_logic.dart`),
which needs a started-then-interrupted mosaic run — i.e. a connected camera, a run, and a kill.
That was out of budget for this pass, and hand-writing a `skotiq_session.checkpoint` is not
viable (it embeds a whole `SequenceDefinition`).

What I can say:
- With two mosaic projects in `Planning` and no checkpoint, the wizard shows **no** resume banner
  and the panel-size warning sits at the top of the left column — correct for that state.
- The ordering is unconditional in source: the resume banner is emitted before the
  `if (!_panelSizeKnown)` warning in the same `Column`
  (`packages/skotiq_app/lib/screens/sequencer/widgets/mosaic_wizard_dialog.dart:303-313`).
- `packages/skotiq_app/test/screens/sequencer/widgets/mosaic_wizard_resume_test.dart` passes
  (6/6) but asserts presence/absence and the Resume/Start Over lifecycles — **no test asserts the
  vertical order**, so the ordering claim is currently backed by source only.

---

## New findings from the adversarial sweep

### WD-COL-N1 — After creating a mosaic, the projects list it returns to still shows the pre-create state (P2)

Repro (deterministic, hit twice):

1. Analytics -> Projects -> "Mosaic projects" (list renders; note what it contains).
2. "New mosaic" -> Advanced (numerical) -> Panel width/height -> "Create mosaic project". The
   wizard creates the project and pushes its detail screen.
3. Press "Back".

Expected: the list shows the project just created.
Actual: it shows exactly what it held when it was built. First run: list read "**No mosaic projects
yet — Start one with 'New mosaic' above**" while the project it had just created was alive one route
above (15 panels, `Status: Planning`). Second run: after creating a second project the list showed
only the first one. Leaving the screen and re-entering shows both. So the list is loaded once and
never invalidated by the wizard's create.

Why it matters: the very first thing a user sees after successfully creating their first mosaic is
an empty state telling them they have none — the same "app says something untrue" shape this
release pass has been chasing, and it lands directly on the path COL2-16 just unblocked.

### WD-COL-N2 — The wizard's blocked footer buttons report themselves as enabled and look enabled (P3)

While "Panel size unknown" is in force, "Create mosaic project" and "Load into Sequencer" both do
nothing when clicked (verified at 1600x900 and at 900x760). The inline reason next to them is the
fix for COL2-16 and it is good — but:

- the accessibility tree reports `button: Create mosaic project` / `button: Load into Sequencer`
  with no `[DISABLED]` state, identical to the working state, so a screen-reader user is told the
  primary action is available and gets silence when they take it;
- visually the two buttons are not dimmed relative to their enabled selves (compare
  `09-create-click.png` with `14-panelsize.png`, where the only change is Create gaining its filled
  style).

The same shape as COL2-3's Download button; a shared "gated button" treatment would close both.

### WD-COL-N3 — Entering one panel dimension auto-fills the other, and typing over the auto-filled value is silently dropped (P3)

Repro (twice, from a fresh wizard each time):

1. New mosaic -> Advanced (numerical). Both panel fields are empty.
2. Click "Panel width (arcmin)", type `50`.
3. Click "Panel height (arcmin)", type `35`.

Expected: 50 x 35 arcmin.
Actual: the height field reads **40.0** and Plan summary reads "Panel size: 0.83° x 0.67°" — 50 x 40
(`57-fields-crop.png`). Entering the width auto-fills the height with the default 40.0, and the
keystrokes typed into the now-populated field are rejected without a sound. The symmetric case
confirms the auto-fill: from a fresh wizard, typing **only** the height (35) yields "1.00° x 0.58°",
i.e. width silently defaulted to 60.

Clearing the field first (select-all, then type) does work — "0.83° x 0.58°" — so the value is
reachable, just not the way anyone types it. A mosaic created from step 3 lays out 40-arcmin-tall
panels while the operator believes they asked for 35, and nothing on screen contradicts them except
a field they have already typed into.

### WD-COL-N4 — Status bar clips the mount item mid-word at 900 px, with no ellipsis and no separator (P3, shared status bar)

At `resize 900 760` the bottom status bar renders "Camera •" then "**Mou**" cut mid-word with the
temperature item's thermometer glyph painted immediately against it, and the Guider/Focus items
simply vanish with no overflow affordance (`44-statusbar-crop.png`, cropped from
`43-narrow-projtab.png`). At 1600x900 the same bar reads "Camera Disconnected | Mount Disconnected |
Guider Disconnected | Focus ---". This is the shared shell status bar rather than anything this
cluster's fixes touched, so it belongs to whoever owns the consistency cluster.

---

## Adjacent findings I re-checked but was not assigned (state recorded, not adjudicated)

- **COL2-4 still reproduces** — the Deep-Star card still ships "host one built with
  tools/catalog_prep" and "see tools/catalog_prep in the Skotiq repository" as user copy
  (`25-cat2.png`).
- **COL2-5 still reproduces** — HYG shows `Installed` + an orange `Update available` chip with no
  update action anywhere on the page (`24-catalogs.png`).
- **COL2-8 did not reproduce** — after re-sorting to Magnitude, screen and tree agree (M31 first).
- **COL2-9 appears fixed** — the seven sort-menu entries now report as plain enabled buttons, no
  `[DISABLED]`.
- **COL2-10 still reproduces** — the altitude chart's last two x-axis labels are still painted on
  top of each other at the right-hand end (`31-plantonight.png`, `35-top.png`).
- **COL2-12 appears fixed** — the eight "Types to Monitor" chips now report `[ON]`.
- **COL2-18 still reproduces** — `panel: Advanced (numerical) [DISABLED]` both collapsed and
  expanded while the section works normally.

## Layout / hygiene checks

- 1600x900 and 900x760: the Mosaic Wizard, the mosaic project screen, the mosaic list, Catalogs and
  the Transient Alert Settings dialog all render without clipping; at 900 px the wizard footer wraps
  "Create mosaic project" onto its own row and the preview keeps its 9 cells (`46-narrow-wizard.png`).
- `grep -icE "renderflex|overflow|exception"` over the session log: **0**.
- Harness note for the next verifier: `resize` moves the window to +0+0, so the `click-img` offset
  changes from `+160+150` to `+0+0`. Re-take a shot after any resize; stale offsets make every
  control look dead (it cost me several minutes of believing the mosaic list had stopped
  responding).
