# GUI release pass (wave 2) — cluster: Mosaic / Collaborative Sky / Transients / Suggestions / Catalogs

Driven live on `SK_AUDIT_DISPLAY=:87`, profile `gui-collab-catalogs`, fresh scratch profile,
release desktop bundle (`apps/desktop/build/linux/x64/release/bundle`), window 1600x900.
Site set to 40.02 / -105.27 via Settings -> Location. Onboarding was exited with "Skip
onboarding" (step 3 refuses to advance with no camera, see COL2-14).

Screenshots cited live in `/tmp/ns-audit/shots-collab3/`.

Wave 1's report is preserved at `reports/release-pass/gui/collab-catalogs-wave1.md`; findings
here are numbered `COL2-n` and are new unless they explicitly say "wave 1 ... still reproduces".

## Harness note (not a product finding)

The release bundle was missing `lib/libskotiq_bridge.so` when this pass started (deleted from
the bundle at 08:16 by a concurrent job); every GUI profile died at boot with "Native bridge failed
to initialize". Restored by copying the freshly built
`native/skotiq_native/target/release/libskotiq_bridge.so` into the bundle's `lib/`. Also
note `drive_linux.py` only binds `--profile` when it is passed *after* the subcommand
(`start --profile X`), not before it — a leading `--profile` silently runs profile `main`.

---

## COL2-1 — The MPC card says it downloads MPCORB; it downloads the 312-object "bright asteroids" list (P2)

Screen: Settings -> Imaging -> Catalogs -> "Minor Planets & Comets (MPC)".

Repro:
1. Open the card. Copy reads: "Downloads fresh asteroid (**MPCORB**) and comet (CometEls) elements
   from the Minor Planet Center. New bodies appear in the planetarium overlay and search."
2. Status line reads "Oldest source updated 2026-08-09 - **312 asteroids**, 762 comets".
3. Press "Refresh Now" and wait ~8 s. The date advances to 2026-08-13; the counts stay 312 / 762.

Expected: either MPCORB (~1.4 M objects), or copy that names the subset actually fetched.
Actual: the fetch is real but it is not MPCORB. `~/.local/share/com.skotiq.desktop/
catalogs/element_refresh_metadata.json` after the refresh records
`"asteroidsUrl":"https://www.minorplanetcenter.net/iau/Ephemerides/Bright/2026/Soft00Bright.txt"`,
`"asteroidsCount":312` — the Minor Planet Center's *Bright Minor Planets* ephemeris file, three
orders of magnitude smaller than MPCORB. `mpc_asteroids.txt` is 59 KB and starts at (1) Ceres,
(2) Pallas, (3) Juno. The comet side really is CometEls (762). A user told "MPCORB" who cannot
find their target asteroid in the planetarium will conclude the search is broken rather than that
the catalogue holds only the 312 brightest. The count itself is also unlabelled — "312 asteroids"
next to "MPCORB" reads as a failed/truncated download.
Evidence: `/tmp/ns-audit/shots-collab3/14-mpc-refresh.png`, `15-mpc-after.png`, and the metadata
JSON above.

## COL2-2 — "Refresh Now" for MPC gives no progress and no completion feedback (P3)

Screen: Settings -> Imaging -> Catalogs -> "Minor Planets & Comets (MPC)" -> "Refresh Now".

Repro: click "Refresh Now"; screenshot immediately and again after 8 s.
Expected: a spinner/disabled button while two HTTP fetches run, then a confirmation.
Actual: the button never changes state, no spinner, no snackbar, nothing in the app log. The only
evidence the click did anything is a date buried in a small status line ("Oldest source updated
2026-08-09" -> "2026-08-13") that a user is not looking at. On a slow link the user has no way to
tell a running refresh from a dead button, and will click it repeatedly.
Evidence: `/tmp/ns-audit/shots-collab3/14-mpc-refresh.png` (immediately after click — identical),
`15-mpc-after.png` (after completion — only the date differs).

## COL2-3 — Deep-Star "Download" with an empty tileset URL is a silent no-op (P2)

Screen: Settings -> Imaging -> Catalogs -> "Deep-Star Tier (Tycho-2 / Gaia)".

Repro:
1. Scroll to the Deep-Star Tier card. "Tileset base URL" is empty (placeholder only).
2. Click "Download".

Expected: the button is disabled while the URL is empty, or clicking it says "Enter a tileset URL".
Actual: nothing happens. No snackbar, no inline validation, no field highlight, no log line, and
the accessibility tree is unchanged (`button: Download` carries no `[DISABLED]` state). The control
is indistinguishable from a broken button. Repeated twice with an immediate capture to rule out a
snackbar that had already timed out.
Evidence: `/tmp/ns-audit/shots-collab3/11-scrolled.png` (empty field + enabled button),
`12-deepstar-click.png` (captured within ~1 s of the click — nothing).

## COL2-4 — Wave 1 COL-13 still reproduces: the Deep-Star tier ships developer instructions as user copy (P3)

Screen: Settings -> Imaging -> Catalogs -> "Deep-Star Tier (Tycho-2 / Gaia)".
Actual copy, verbatim, in the shipping release bundle: "Streams faint stars below the bundled HYG
floor (mag 9.0) as view-culled tiles when zoomed in. **No tileset is published yet: host one built
with tools/catalog_prep and point the URL below at it.**" and, under the field, "No official
tileset is published yet — point this at a tileset you host yourself (see **tools/catalog_prep in
the Skotiq repository**)." A paying customer is being told to build their own tileset from a
directory in a source repository they do not have.
Evidence: `/tmp/ns-audit/shots-collab3/11-scrolled.png`.

## COL2-5 — Wave 1 COL-11 still reproduces: HYG shows "Update available" with no way to take it (P3)

Screen: Settings -> Imaging -> Catalogs -> "HYG Star Database".
Actual: the card shows `Installed` *and* an orange `Update available` chip, with Version 4.4,
Package Standard, Installed 2026-08-11 — i.e. the newest package the app itself installs. The card
exposes no "Update" action; the only downloads on the page are the three package tiers below, which
are described by size, not by version. The badge is unexplained and unactionable, and it is on the
one catalogue the same card calls "Required for plate solving".
Evidence: `/tmp/ns-audit/shots-collab3/08-catalogs.png`.

## COL2-6 — Catalogs are stored outside the app's data directory, so they survive a wiped profile (P3)

Screen: Settings -> Imaging -> Catalogs, on a profile started with a wiped data directory.

Repro:
1. Start the app with `SKOTIQ_DATA_DIR` / `SKOTIQ_DATABASE_DIR` pointing at an empty
   directory (`drive_linux.py start --fresh`).
2. Open Settings -> Imaging -> Catalogs.

Expected: on a data directory with no catalogues, the cards read "Not installed" and the page
invites a download.
Actual: every card reads `Installed` with install dates from previous sessions (HYG 4.4 /
2026-08-11, OpenNGC 2023.12 / 2026-08-11, GLADE+ 2026-08-03). The files are in
`~/.local/share/com.skotiq.desktop/catalogs/`, which no data-directory setting moves.
Consequences: (a) the "Files & Storage" data directory does not actually contain the app's largest
data set, so a user who points Skotiq at a big disk still fills the system drive with ~52 MB of
catalogues; (b) "Delete Catalogs" on any profile destroys them for every profile on the machine.
Evidence: `ls ~/.local/share/com.skotiq.desktop/catalogs/` (52 MB of csv/txt) against
`find /tmp/ns-audit/gui-collab-catalogs/data -type f` (skotiq.db, a backup and a log — no
catalogues).

## COL2-7 — Tonight's top-ranked imaging target is a bare naked-eye star, typed "Star" (P2)

Screen: Plan Tonight -> Recommendation -> "Tonight's candidates".

Repro: open Plan Tonight with a site set (40.02 / -105.27) and look at the first candidate card.
Expected: an imaging target.
Actual: the #1 candidate (score 96 of 100) is "**gam Cyg / IC1318**" and its own chips describe it
as type "**Star**", "Mag 2.2". The body copy recommends it warmly: "Excellent peak altitude (89°),
far from the 3% moon (122°), transits at 01:52 tonight." IC1318 is the Gamma Cygni *nebula*, but the
row is carrying gamma Cygni's stellar type and magnitude, so a deep-sky imaging recommender is
ranking a 2nd-magnitude star as tonight's best subject, and everything downstream that keys off
magnitude (the exposure suggestion, the "Sort: Magnitude" order, any auto-queue-by-brightness rule)
inherits the error. The hero pick above it has the opposite problem — NGC7094, a 1.6-arcminute,
mag 13.4 planetary nebula, is scored 98 for an unspecified rig.
Evidence: `/tmp/ns-audit/shots-collab3/19-outlook-list.png`, `20-firstcand.png`,
`21-cards23.png`.

## COL2-8 — The candidate list's accessibility tree keeps a stale card after a re-sort (P3)

Screen: Plan Tonight -> Recommendation.

Repro:
1. Open Plan Tonight. The sort control reads "Sort: Score"; the first card under "Tonight's
   candidates" is M39 / NGC7092 (Open Cluster, Mag 4.6, score 98).
2. Click the sort control and choose "Sort: Magnitude".
3. Screenshot the first candidate card, then run `drive_linux.py tree`.

Expected: both agree.
Actual: the screen re-sorts (first card becomes gam Cyg / IC1318, Mag 2.2, score 96) but the
accessibility tree still reports the first candidate as `M39 / NGC7092 / Open Cluster / Peak in
dark 81° / Mag 4.6 / 19.5' / Cyg / 98`, followed by the correctly re-sorted entries (2.2, 3.0, 3.4,
3.7, 3.8, 4.0 …). The stale node survived three tree reads over ~3 minutes, so it is not a race.
A screen-reader user is told the first target is M39 while every button in that row acts on
gam Cyg.
Evidence: `/tmp/ns-audit/shots-collab3/20-firstcand.png` (screen) against the tree output quoted
above; `21-cards23.png` shows the rendered order continues gam Cyg -> Schmidt's Nova Cygni.

## COL2-9 — Every entry in the sort menu reports itself as disabled to assistive tech (P3)

Screen: Plan Tonight -> Recommendation -> sort control (top right of the filter row).

Repro: click "Sort: Score" and run `drive_linux.py tree`.
Expected: seven enabled menu items, one marked selected.
Actual: all seven report `[DISABLED]` — `button: Sort: Score [DISABLED]`, `Sort: Altitude
[DISABLED]`, … — and none reports a selected state, even though clicking "Sort: Magnitude" really
does re-sort the list. The closed control itself also reads `button: Sort: Score [DISABLED]`. This
is the same inverted-state class wave 1 recorded on the co-imaging consent sheet (COL-3), now on a
second, unrelated surface, so the fix needs to be at the shared control, not per screen.

## COL2-10 — Night Outlook altitude chart: the last two x-axis labels are drawn on top of each other (P3)

Screen: Plan Tonight -> Recommendation -> the "NIGHT OUTLOOK" hero card's altitude chart (and every
candidate card's chart — same widget).

Repro: open Plan Tonight and look at the right-hand end of the altitude chart's time axis.
Expected: readable tick labels.
Actual: the final two labels are painted at the same x, producing an unreadable glyph pile
("O9OCTC"-looking) where "09:01" should be. The axis reads 21:01 / 23:01 / 01:01 / 03:01 / 05:01 /
07:01 / <pile>. It is on the flagship card of the planning screen, repeated once per candidate row.
Evidence: `/tmp/ns-audit/shots-collab3/17-axis.png` (crop), `16-plantonight.png`.

## COL2-11 — Transient Alerts says "No active alerts" without ever having checked, and offers no way to check (P2)

Screen: Plan Tonight -> Recommendation -> "Transient Alerts" card.

Repro:
1. Open the card's gear -> "Transient Alert Settings". Untick TNS, tick "AAVSO (Variable Stars)".
   Close.
2. Read the card, and `grep -icE "aavso|tns|transient|mpec|cbat"` the app log.

Expected: some evidence a source was polled — "Checked 2 minutes ago", a refresh control, or an
explicit "AAVSO unreachable".
Actual: the card reads "**No active alerts**" and nothing else. There is no last-checked time, no
"checking…", no refresh action (the card has only an expand chevron and a settings gear), and the
app log contains **zero** lines mentioning any alert source over the whole session. "No active
alerts" is indistinguishable from "we never asked", which on the app's only channel for
time-critical events (a naked-eye supernova, a bright nova) is exactly the wrong ambiguity. Note
the one honest state does exist and is lost by this change: with TNS ticked the card correctly
warns "Setup needed for live TNS alerts"; tick AAVSO instead and the warning is replaced by a
confident empty state.
Evidence: `/tmp/ns-audit/shots-collab3/23-transient-card.png`, `22-transient-settings.png`.

## COL2-12 — Transient "Types to Monitor" chips expose no on/off state at all (P3)

Screen: Transient Alert Settings -> "Types to Monitor".
Actual: the eight type chips (Nova, Supernova, Cataclysmic, Comet, Asteroid, Variable, GRB, Other)
are drawn as selectable chips with tick marks, but the accessibility tree exposes them as plain
`button: Nova`, `button: Supernova`, … with no checked/selected state and no `[DISABLED]`. A
non-sighted user cannot determine, or verify after toggling, which transient types they are
subscribed to. The checkboxes above them in the same dialog do report `[ON]` / `[off]` correctly,
so the dialog is internally inconsistent.
Evidence: `/tmp/ns-audit/shots-collab3/22-transient-settings.png` plus the tree quoted in COL2-11.

## COL2-13 — Auto-queue threshold is hard-coded to mag 10 and contradicts the threshold the user just set (P3)

Screen: Transient Alert Settings.
Actual: "Magnitude Threshold — Only show objects brighter than this magnitude" is a user slider
(range 5-20, default 15.0). Directly below, "Auto-queue bright transients — Automatically add
transients **brighter than mag 10** to targets" is a fixed number with no control. A user who drags
their threshold to 12 has no way to learn why a mag-11 nova was shown but not queued, and no way to
change it.
Evidence: `/tmp/ns-audit/shots-collab3/22-transient-settings.png`.

## COL2-14 — Hub connect: the in-flight busy state is visual only; assistive tech sees an idle, enabled button (P3)

Screen: Plan Tonight -> Discover -> Collaborate -> "Connect to a hub".

Repro:
1. Enter `http://127.0.0.1:9`, display name "AuditRig", press Connect. A good error appears in
   ~0.7 s: "Cannot reach 127.0.0.1: Connection refused". (This path is correct — record it as
   working.)
2. Select the address field, replace it with an address that black-holes rather than refuses:
   `http://10.255.255.1:8090`. Press Connect.
3. Read `drive_linux.py tree` at T+0, T+8 s and T+25 s, and crop the dialog footer.

Expected: the busy state is exposed to assistive tech as well as to the eye.
Actual: visually the Connect button is correct — it dims and swaps its icon for a spinner, and the
old error clears on submit. But the accessibility tree reports `button: Connect` with **no**
disabled state and no changed name at T+0, T+8 and T+25 s, identical to the idle dialog. A
screen-reader user has no signal that the attempt started, is running, or is the reason nothing is
happening, and the dialog is otherwise silent for the whole attempt (>3 minutes against a
black-holed address — see COL2-15).
Evidence: `/tmp/ns-audit/shots-collab3/33-connect-inflight.png` (spinner visible in the button),
tree output at the three sample times.

Note for verifiers: an earlier attempt of this repro appeared to show a *stale* error surviving a
new submission. It did not — the address field had silently kept `http://127.0.0.1:9` because the
error banner had re-centred the dialog and moved the field out from under the click. Re-check the
field contents (`shots-collab3/32-addr3.png`) before believing that variant.

## COL2-15 — Wave 1 COL-9 still reproduces, and the omitted panels move with the centre (P2)

Screen: Mosaic Wizard (Analytics -> Projects -> "Mosaic projects" -> "New mosaic").

Repro:
1. Open the wizard. Default grid 3 columns x 3 rows; Plan summary says "Active panels: 9,
   Grid: 3x3". Count the cells in the sky preview.
2. Press Columns "+" twice (summary: "Active panels: 15, Grid: 5x3"). Count again.
3. Drag the centre marker ~200 px to the right (header goes from "RA 0.000h" to "RA 23.894h").
   Count again.

Expected: 9, then 15, then 15.
Actual: **6**, then **9**, then **12** — the preview never draws the plan it is previewing.
- 3x3 at RA 0.000h: cells 2,3 / 5,6 / 8,9. Panels 1, 4, 7 (the whole first column) are absent.
- 5x3 at RA 0.000h: cells 3,4,5 / 8,9,10 / 13,14,15. Panels 1,2,6,7,11,12 (the first two columns)
  are absent.
- 5x3 after dragging the centre to RA 23.894h: cells 1,2,3,4 / 6,7,8,9 / 11,12,13,14. Now the
  *last* column (5,10,15) is the missing one.
The omitted set is exactly the panels on the far side of the RA 0h seam from the centre, which is
the same wrap-around blindness wave 1 measured on the publish path (COL-7, where a mosaic straddling
RA 0h was published with a centre 144 degrees off — 144.0 being the unwrapped arithmetic mean of
panel RAs 358.595 / 359.298 / 0.0 / 0.702 / 1.405). Both should be fixed together. The preview is
the only aiming tool the wizard offers ("Drag centre / Tap panel to toggle"), so what the user frames
is not what the plan contains, and panels they cannot see they also cannot toggle off.
Evidence: `/tmp/ns-audit/shots-collab3/37-mosaic-wizard.png` (3x3, six cells),
`39-grid5.png` (5x3, nine cells), `40-grid5-moved.png` (5x3 at RA 23.894h, twelve cells).

## COL2-16 — "Create mosaic project", the wizard's primary action, does nothing and says nothing (P1)

Screen: Mosaic Wizard -> "Create mosaic project".

Repro:
1. Analytics -> Projects -> "Mosaic projects" -> "New mosaic".
2. Click "Create mosaic project" (bottom right). Repeat with Columns raised to 5, and again after
   expanding "Advanced (numerical)" and filling Panel width 60.0 / height 40.0 arcmin.

Expected: a mosaic project is created and the wizard closes — or the button is visibly disabled with
the reason next to it.
Actual: nothing happens on any attempt. The wizard stays open unchanged, there is no snackbar, no
inline error, no dialog, and nothing is written to the app log. The button is not dimmed relative to
its neighbour "Load into Sequencer", and the accessibility tree reports
`button: Create mosaic project` with **no** `[DISABLED]` state. Clicks were confirmed to land on the
button (root 1338,932; the button occupies that point in
`/tmp/ns-audit/shots-collab3/38-create-click.png`), and a capture taken within ~1 s of the click
shows no transient message. There is no other route out of the wizard except Cancel, so on this
build the mosaic feature cannot be entered at all from its own entry point.
Evidence: `/tmp/ns-audit/shots-collab3/37-mosaic-wizard.png`, `38-create-click.png`, tree before and
after (identical), `drive_linux.py log --tail 6` (device discovery only).

If the intended behaviour is "blocked until an equipment profile supplies a focal length", then the
defect is that the block is invisible: see COL2-17.

## COL2-17 — The Mosaic Wizard contradicts itself about whether it knows the panel size (P2)

Screen: Mosaic Wizard.

Repro: open the wizard with no equipment profile, then expand "Advanced (numerical)" and scroll.
Actual, all on screen at once:
- A warning card: "**Panel size unknown** — No equipment profile with a focal length — set one in
  Settings to size a panel. **A mosaic cannot be planned until one panel's field is known.**"
- Plan summary: "Panel size: **unknown**" — yet the same summary confidently computes "Est. time
  (14m/panel x 10 subs): **3.8 h**" and "Total exposures: **150**".
- Advanced (numerical): "Panel width (arcmin) **60.0**", "Panel height (arcmin) **40.0**" — a
  concrete panel field, pre-filled, sitting two inches below the card that says the panel field is
  unknown. Typing into these fields does not clear the warning or change "Panel size: unknown".
So the dialog says planning is impossible, shows the number it claims not to have, and prints a plan
anyway. The warning also sends the user to Settings when the field they need is in the same dialog.
Evidence: `/tmp/ns-audit/shots-collab3/37-mosaic-wizard.png` (warning + summary),
`41-wizard-left.png` (summary with 3.8 h / 150), `44-radec.png` (60.0 / 40.0 arcmin).

## COL2-18 — "Advanced (numerical)" reports itself disabled while working normally (P3)

Screen: Mosaic Wizard -> "Advanced (numerical)".
Actual: the accessibility tree reports `panel: Advanced (numerical) [DISABLED]` both collapsed and
expanded, although clicking it expands the section and the four fields inside it accept input. Same
inverted-state class as COL2-9 and wave 1's COL-3.

## COL2-19 — Settings pages lose ~160 px of height while a "tour" coach-mark is on screen (P4)

Screen: any Settings page on first visit (observed on Settings -> Imaging -> Catalogs).

Repro: open Settings for the first time in a profile; the "Settings Tour" card appears bottom-right.
Screenshot, click "Maybe Later", screenshot again.
Expected: a coach-mark floats above the page.
Actual: it takes space from it. With the card up, the settings sidebar and content pane both stop at
root y≈869 with the sidebar list visibly cut mid-item; after dismissing, both extend to y≈940 and
another card's worth of content is visible. A transient hint should not reflow the page under the
user's cursor.
Evidence: `/tmp/ns-audit/shots-collab3/08-catalogs.png` (tour up, panes clipped),
`09-bottomband.png` (same page after dismissal, panes reach the status bar).

---

## Things that work (recorded so a later pass does not re-litigate them)

- **Hub connect failure messaging is good.** `http://127.0.0.1:9` -> "Cannot reach 127.0.0.1:
  Connection refused" in ~0.7 s; `http://10.255.255.1:8090` -> "Request to 10.255.255.1 timed out"
  after ~60-90 s, with a spinner in the button throughout. Only the a11y side is wrong (COL2-14).
- **Collaborative Sky's disconnected empty state** is honest and specific ("Connect to a
  self-hosted hub… There is no Skotiq cloud"), with a single clear CTA.
- **Transient alert settings persist** across close/reopen of the dialog within a session
  (AAVSO on, TNS off round-tripped correctly), and the checkboxes report `[ON]`/`[off]` properly.
- **Settings search** ("catalog") is fast and returns deep links into sub-sections
  (Delete Catalogs, GLADE+ Galaxy Catalog, ASTAP catalog directory…).
- **MPC refresh really does fetch** — `element_refresh_metadata.json` timestamps advance — the
  problem is only what it claims to fetch (COL2-1) and that it says nothing while doing it (COL2-2).
- **No RenderFlex overflows or Flutter exceptions** in the entire session's log
  (`grep -icE "renderflex|overflow|exception"` -> 0).

---

## Coverage

Screens actually driven this pass:

- Settings -> Imaging -> Catalogs (HYG, OpenNGC, GLADE+, Deep-Star Tier, Minor Planets & Comets,
  Download Catalogs tiers, Actions)
- Settings -> Location (used to set the site; not audited as a screen)
- Settings search (sidebar, query "catalog")
- Plan Tonight -> Recommendation (autopilot banner, filter row, sort menu, Transient Alerts card,
  Night Outlook hero card + altitude chart, Tonight's candidates list)
- Transient Alert Settings dialog (sources, magnitude threshold, types, both toggles, persistence)
- Plan Tonight -> Projects (empty state)
- Plan Tonight -> Discover -> Your Sky (empty state + "Name a region" dialog)
- Plan Tonight -> Discover -> Collaborate (disconnected empty state, "Connect to a hub" dialog,
  refused-connection and timed-out-connection paths)
- Analytics -> Projects (empty) -> Mosaic projects (empty) -> Mosaic Wizard (grid controls, sky
  preview + centre drag, plan summary, Advanced numerical, footer actions)

Screens I could not reach, and why:

- **Mosaic project screen (`/mosaic/:id`)** — blocked by COL2-16: "Create mosaic project" is a
  silent no-op, so no project can be created from the wizard. Everything on that screen (panel
  status, "Publish to hub", the Collaborative-mosaic section wave 1 filed COL-7 / COL-8 against)
  was therefore unreachable this pass.
- **All hub-connected Collaborative Sky surfaces** — collaborative mosaic listings, co-imaging
  session cards and the consent sheet, the shared calibration section, panel claiming. Wave 1
  reached these by standing up a local `server/skotiq_hub`; I did not stand one up this pass,
  so wave 1's COL-1, COL-2, COL-4, COL-5, COL-7 and COL-8 are **not re-verified** here and should
  be treated as still open.
- **Discover -> Constellation tab** — not driven (no budget left after the Collaborate paths).
- **Catalog destructive/download actions** — "Delete Catalogs" and "Download Selected Package" were
  deliberately not exercised: per COL2-6 the catalogues live in the developer's real
  `~/.local/share/com.skotiq.desktop/catalogs/`, not in the scratch profile, so running
  either would have rewritten or destroyed their actual installation. Wave 1's COL-10 and COL-12
  are therefore not re-verified.
- **Live transient alert content** (an alert card, its detail view, "auto-queue" firing) — no real
  TNS/AAVSO event was available and the app offers no way to inject one; only the empty state and
  the settings dialog could be reviewed.
- **Candidate row actions** ("Review in Sequencer", "Send to Framing", "Add to observing list",
  "Open Planetarium") — not exercised; they belong as much to the sequencing/framing clusters and
  the budget went to the mosaic wizard instead.
