# Wave F dryness check — cluster: science-collab

**Date:** 2026-08-14 (00:00–00:35 local). **Harness:** `tools/ui_audit/drive_linux.py`,
display `:86`, profile `waveE-science-collab` (`--profile` after the subcommand), reusing
Wave E's data directory so the Aug-13 run and its 12 quick captures were already on disk.
**Binary:** `apps/desktop/build/linux/x64/release/bundle/skotiq_desktop`,
`lib/libapp.so` + `lib/libskotiq_bridge.so` both stamped **Aug 13 23:56**, i.e. after
the E-fix commit `7d305dbcb` / `4723ca202` (23:54). Freshness cross-checked by string-grep
of the E-fix's own strings in `libapp.so`: `More equipment status`, `frames_graded_poor`,
`unavailable: `, `Scroll tabs right`, `asGradableFrame`, `create-project requested`,
`Open Workbench before treating` all present (and `No official tileset is published yet`
present as UTF-16 only — the em-dash trap the E-fix log recorded).

**State driven:** Continue-Session → *Load Previous Setup* and (after a restart) *Skip*;
Equipment ▸ Discovery ▸ Connect Simulated Camera + Simulated Mount; Settings ▸ Location
longitude 40 → **-10** (to move the site into darkness so the daylight gate stopped
blocking); Sequencer ▸ Builder ▸ Take Exposures 3 s × 4 ▸ Start ▸ **Start Anyway** → a
second completed run (`imaging_sessions` id 2, `captured_images` 17–20). Screens swept at
**1600×900** and **900×760**. Screenshots + probes in `/tmp/ns-audit/waveF-sci/shots/`.

---

## Verdicts on assigned items

| ID | Verdict | Evidence |
|----|---------|----------|
| **NEW-E5** (Night Doctor reads the diagnostics) | **VERIFIED_FIXED** (on a session analysed by the new code) | The fresh run's Session Review ▸ Narrative reads **70 / 100**, *"Rough night: every sub was graded poor."*, `Fair`, **1 finding** (`f54-narrative2.png`) — where Wave E's identical state read 100/100 / "A clean night" / 0 findings. The persisted row proves it is the new detector: `night_reports` id 2 = `[{"id":"frames_graded_poor","severity":"critical","title":"Every sub was graded POOR","explanation":"…rates all 4 of this session's subs POOR. Median HFR across the night was 5.68 px…","evidenceSubIds":[17,18,19,20]}]`, and the same session's `captured_images` are `quality_score` 35.29–35.62 / `hfr` 5.62–5.73. The disclosure row from the D-fix correctly no longer appears (there is no longer a disagreement to disclose), and Workbench shows the same four POOR subs (`f74-workbench.png`) — one story on both surfaces. **Caveat filed separately as WF-SCI-N2:** the Aug-13 session still shows the old 100/100 verdict, because reports are computed once and cached. |
| **NEW-E2** (Replay navigation) | **VERIFIED_FIXED** | Sequencer ▸ History ▸ replay icon → `header: Replay — New Sequence`; click **Dashboard** in the rail, 8 s → the Dashboard is on screen and the rail highlight matches (`f06-after-dash.png`; `tree --filter Replay` returns nothing). The app-bar `✕` is now the filter glyph and behaves like one: selecting a chip took the header to `0 of 2 decisions`, clicking the glyph restored `2 of 2 decisions` **without leaving the screen**. The `←` still pops back to Execution History. |
| **NEW-E3** ("1 of 2 decisions") | **VERIFIED_FIXED** | Old run: `Time range: 20:53:44 — 20:54:01` / `2 of 2 decisions` with both rows rendered (`f05-replay.png`). New run: `Time range: 00:20:29 — 00:20:46` / `2 of 2 decisions`. |
| **NEW-E1** (mosaic Back bar) | **VERIFIED_FIXED** | Analytics ▸ Projects ▸ Mosaic projects ▸ open a project: `tree` reports **`button: Back`** (was `panel: Back`), and clicking the **word** "Back" at image x=223 — the target Wave E clicked twice with no effect — pops straight back to the list (`f30-mproj.png` → `f31-afterback.png`, tooltip "Back" visible). |
| **NEW-E4** (status-bar equipment chip) | **VERIFIED_FIXED** | Every screen this session ends with `button: My Equipment, 0 connected` / `button: My Equipment, 2 connected` — button role, no `[DISABLED]` (was `panel: … [DISABLED]`). Still functional: clicking it opens `panel: Popup menu` with `button: 🔭 My Equipment…`, `button: No devices configured`, `button: Disconnect All`, `button: Equipment`. |
| **WD-SCI-N3** ("Start Anyway") | **VERIFIED_FIXED** | Pre-flight with 3 warnings and no errors: `button: Start Anyway`, and a direct AT-SPI probe gives `['enabled','focusable','sensitive','showing','visible']` — identical to its siblings `Re-check` / `Cancel`, where Wave E had `panel: Start Anyway` with no role and no keyboard reach. Clicking it started the run (4/4 frames). |
| **WD-SCI-N4** (chevrons over tab labels) | **VERIFIED_FIXED** | `resize 900 760` ▸ Analytics: the right chevron now sits in its **own cell** to the right of the strip (`f25-an-narrow.png`); no label is painted over. After clicking it the left chevron likewise sits before `History` and **Science reads in full** (`f26-tabs2.png`) — Wave E had `S › ce` and `Hi ‹ y`. What the viewport slices at its edge (an icon-only Diagnostics remnant) is the documented scroll behaviour, not overpaint. Re-checked on Projects (`f67-proj900.png`) and on the Sequencer strip at 900 (fits, no chevrons — `f59-seq-narrow.png`). |
| **WD-COL-N2** (inert gated actions) | **VERIFIED_FIXED** | Mosaic Wizard with "Panel size unknown": `button: Load into Sequencer — unavailable: panel size unknown, so there is no grid to lay out` and `button: Create mosaic project — unavailable: Panel size unknown, so there is nothing to lay a grid out from…`. Clicking each does nothing **and writes no log line** (app.log 918 → 918 lines), which is now the expected reading for a refused-at-the-gate click. The discriminator round-trips: once both dimensions are typed the same two nodes print as plain `button: Load into Sequencer` / `button: Create mosaic project`. |
| **WD-COL-N3** (auto-filled dimension ate keystrokes) | **VERIFIED_FIXED** | Fresh wizard ▸ Advanced (numerical): both fields start empty; typing width `50` leaves **Panel height empty** (`f37-w50.png`) and the footer still refuses; then typing height `35` gives `Panel size: 0.83° × 0.58°` = 50 × 35 (`f38-h35.png`), where Wave E got 50 × **40.0**. Adversarial: `ctrl+a` + `9999` in the width shows red `Enter 1–360` under the field while the height keeps `35.0` (`f39-range.png`). |
| **WD-COL-N4** (status bar clipped against the thermometer) | **VERIFIED_FIXED** | At 900×760 with 2 devices the strip ends in `button: More equipment status` followed by a rule, then the temperature chip (`f22-zoom.png`) — Wave E had "Simulated Cam" butted against the thermometer with no separator and no control. Clicking the chevron at (441,740) scrolls the strip: the bar goes from `Simulated Ca…` alone to `Simulated Ca… · Simulated Mo…` (`f23-sb2.png`). |
| **COL2-3** (deep-star Download, fourth look) | **VERIFIED_FIXED** | Settings ▸ Imaging ▸ Catalogs ▸ Deep-Star Tier with an empty URL: `button: Download — unavailable: no tileset URL is set, so there is nothing to download from`, rendered visually dim (`f44-deepstar.png`). Typing `https://example.invalid/tiles` into "Tileset base URL" turns it into a plain `button: Download`; clearing the field restores the "unavailable" name. Both directions, same node. |
| **NEW-C2** (in-scope half) | **VERIFIED_FIXED** | `tree \| grep -c DISABLED` = **0** on Analytics ▸ Session / History / Projects / Equipment Stats / Science / Diagnostics with data present, and the mosaic wizard's disclosure is now `button: Advanced (numerical)` (was `panel: … [DISABLED]`). |
| **NEW-C3** (Imaging Frame Type / Binning) | **STILL_BROKEN** (out of scope for this batch, unchanged) | Imaging ▸ `tree`: `panel: Frame Type` / `button: Light` and `panel: Binning` / `button: 1x1` still unassociated. The E-fix log records this as another batch's file; nothing regressed. The out-of-scope half of NEW-C2 is likewise unchanged: `panel: Overlays [DISABLED]` on Imaging, and the Sequencer palette's role-less `panel: Nodes / Tab 1 of 3`. |

**Score: 12 verified fixed, 1 still broken** — and the one still-broken item is the one the
E-fix batch explicitly declared out of its scope. Bonus check (not assigned): the
`AccessibleDropdown` parity fix is live — the Analytics session picker now announces
`Quick captures (no session) [off]` / `New Sequence · Aug 14 … [off]` / `New Sequence · Aug 13 … [ON]`.

---

## New findings

### WF-SCI-N1 (P3) — after a run finishes, Analytics ▸ Session keeps reviewing the *previous* night

Deterministic, hit three times. With two completed runs on disk (Aug 13 20:53 and Aug 14
00:20), open Analytics ▸ Session: the header reads `Reviewing New Sequence · **Aug 13, 2026
20:53** · 4 frames` and the panel below it shows that night's numbers (`MEDIAN HFR 5.70`,
`f62-sess.png`) while the newer run sits in the dropdown one row above it. The **"Most
recent" clear affordance is not shown**, because the app considers this the *default* pick,
not an explicit one — so nothing on screen says you are looking at last night.
Choosing the Aug 14 session works, but navigating to Dashboard and back reverts to Aug 13.

Decisive experiment: after `stop` + `start` of the same profile, the same screen opens on
**Aug 14** — so the query is right and the value is stale.
`latestScienceSessionProvider` (`packages/skotiq_app/lib/screens/analytics/widgets/science_analytics_tab.dart:67`)
is a plain `FutureProvider` that reads `getLatestSessionIdWithLightFrames()` once and is
never invalidated when a run completes; `session_tab.dart:44` uses it as the auto-pick.
Why it matters: the whole point of the tab is the night you just shot, and on the imaging
laptop the app is never restarted between runs.

### WF-SCI-N2 (P3) — the Night Doctor verdict is written once and never recomputed, so NEW-E5's fix does not reach any night already analysed

On the fixed build, the Aug-13 session's Session Review still reads **100 / 100 · "A clean
night — no problems detected." · Excellent · 0 findings** over four subs the same app grades
POOR (`f16-sessreview.png`); only the D-fix's disclosure row underneath contradicts it. The
top-right **Refresh** button does not recompute it (`f17-refresh.png` identical; `night_reports`
still one row, `created_at` 1786668866 = Aug 13 20:54:26, i.e. written by the *old* build).
Cause: `session_review_controller_parts/_helpers.dart:117-127` prefers
`reports.latestForSession(...)` and only computes when no row exists — there is no
invalidation and no user-reachable recompute. Consequences beyond the upgrade case: a
report computed on first view *before* grading finished keeps a verdict the grader later
contradicts, for the life of that session.

### WF-SCI-N3 (P3) — the pre-flight primary is inert while it announces itself enabled, with no reason

Same shape the E-fix's `GatedAction` was invented for, at a site the batch did not cover.
Sequencer ▸ Start with a blocking error (site in daylight): the dialog says *"Cannot Start
Sequence / Please fix 1 error(s) before starting"*, and the primary prints as plain
**`button: Start Sequence`** — no `[DISABLED]`, no "unavailable: …" clause. Clicking it
(image 720,566 → raw 900,707) leaves the dialog exactly as it was: no start, no toast, no
new log line (`f47-preflight.png` → `f48-afterstartclick.png`). A direct AT-SPI probe shows
the state that the harness cannot render: `['sensitive','showing','visible']` — the
`enabled` flag is absent, while `Re-check` and `Cancel` beside it carry
`['enabled','focusable','sensitive',…]`. The role/keyboard half of WD-SCI-N3 is genuinely
fixed; what is left is that a blocked primary is indistinguishable from a live one for
anyone (or anything) reading the tree, and carries no reason.

### WF-SCI-N4 (P4) — "Open last run" opens the Sequence Builder, not the run

Dashboard ▸ Last night card ▸ **Open last run** (`button: Open last run`) lands on Sequencer
▸ **Builder** with the 0-node empty sequence — not the run, not even the History tab
(`f10-review.png`, reproduced twice). Source is explicit about it:
`screens/dashboard/widgets/standby/last_night_recap_card.dart:135-139` — *"History
deep-linking by run id isn't a stable route, so we link to the Sequencer"* — `context.go('/sequencer')`.
The card that carries the label already knows the session id (the card body's own `onTap`
in `tonight_screen.dart:532` pushes `/session-review?session=$id`), so the button under it
promises less than the card it sits in delivers.

---

## Evidence-quality note for the orchestrator (not a product defect)

`drive_linux.py::_states` prints `[DISABLED]` only when **both** `enabled` and `sensitive`
are missing from the AT-SPI state set. This build keeps `sensitive` on a disabled Flutter
button and drops only `enabled` (probed above on `Start Sequence`, and Wave E probed the
same shape on `Edit Dashboard`). So a genuinely disabled *button* never prints `[DISABLED]`
— only role-less focusable `panel:` nodes do. That is why two waves in a row read
`onPressed: null` controls as "not disabled", and it is the reason the E-fix's decision to
put the reason **in the accessible name** is the right discriminator. Changing the check to
`"enabled" not in raw` would make the next wave's dumps say what they mean.

## Observations (recorded, not filed)

- The new night report carries `"severity":"critical"` while the ring renders `Fair` at
  70/100. The headline is honest, so this is a badge/severity mapping nit, not cry-wolf.
- Analytics ▸ Science keeps its own session pick (`Analysing … Aug 13 20:53`) while ▸ Session
  is on Aug 14; the two tabs never disagree about a session's *contents*, only about which
  one they are showing.
- Sequencer ▸ History groups the Aug 14 00:20 run under "Thursday, Aug 13, 2026 · 2 runs".
  Checked before filing: `tabs/history_tab.dart:442` buckets deliberately by **observing
  night**, so this is correct astronomy, not a date bug.
- At 900 px the Analytics chart-card headers wrap hard ("Sensor tempera / ture"); pre-existing
  narrow-layout squeeze, untouched by this batch.

## Coverage

Analytics ▸ Session / History / Projects / Equipment Stats / Science / Diagnostics (empty
and with two runs + 12 quick captures); the session picker opened and round-tripped, plus a
restart to settle the default; Session Review ▸ Narrative and ▸ Workbench for both sessions;
Session Summary and Session Report dialogs; Mosaic projects list, project detail + Back,
wizard (gated footer, Advanced numerical, out-of-range entry, 900-px footer wrap); Settings ▸
Imaging ▸ Catalogs (Deep-Star card, both gate directions); Sequencer Builder ▸ pre-flight
(error variant and warnings variant) ▸ run ▸ History ▸ Replay (filters, slider, glyph, back,
rail navigation); status bar at both widths; the shared equipment chip and its popup.
Layouts checked at 1600×900 and 900×760.
