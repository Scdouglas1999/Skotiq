# GUI release pass — cluster: Analytics / Science / Session Review / Stack Result

Harness: `tools/ui_audit/drive_linux.py`, profile `gui-science-review`, display `:86`, fresh scratch profile.
Build: release bundle under `apps/desktop/build/linux/x64/release/bundle`.
Date: 2026-08-11.

> NOTE (harness): `--profile` is only honoured **after** the subcommand.
> `drive_linux.py --profile X start --fresh` silently runs the `main` profile
> (it reported `see /tmp/ns-audit/main/app.log`). Documented here so the next
> agent does not lose a start attempt to it. Not a product finding.

## Summary

33 findings: **3 P1**, **13 P2**, **16 P3**, **1 P4**. Findings are numbered in the order they
were found, so the numbering is not sorted by severity.

The three that would cost a user their night or their trust:

- **SCI-11 (P1)** — Analytics ▸ Session reports 100 exposures / 3m 20s for a run that
  Analytics ▸ Equipment Stats reports as 248 exposures / 8m 16s. Same screen, same data.
- **SCI-16 (P1)** — Session Review of a FAILED run reads `Total 0 · Successful 0 · Failed 0`
  and never states the failure reason the executor logged.
- **SCI-28 (P1)** — **Stop** on Live Stacking wipes a 32-frame stack to zero with no
  confirmation and nothing saved to disk; a separate *Reset Stack* button already exists.

Two themes run through the rest: (a) **empty and blocked states that name an action the
screen cannot perform** (SCI-1, SCI-20, SCI-15, SCI-21, SCI-30), and (b) **icon-only controls
that the accessibility tree does not expose at all** (SCI-3, SCI-4, SCI-19).

## Findings

### SCI-1 — P2 — Analytics ▸ Diagnostics empty state tells you to "Select an imaging session" but the screen has no session selector
Repro: fresh profile ▸ skip onboarding ▸ nav **Analytics** ▸ tab **Diagnostics**.
Expected: an empty state that names what is missing and how to get it, or a visible
session picker to select from.
Actual: the body reads **"Select an imaging session to analyze"** while the only
mention of sessions is dead grey text **"No sessions available"** in the top-right
corner. There is no dropdown, list or button anywhere on the screen to select a
session from, so the empty state instructs an action the screen cannot perform.
Evidence: `/tmp/ns-audit/gui-science-review/s12-diagnostics-empty.png`.

### SCI-2 — P3 — Analytics ▸ Diagnostics leads with a 4-sentence grey wall of text
Repro: as SCI-1.
Expected: a one-line subtitle, detail behind "Learn more".
Actual: a 65-word, full-width (1050 px) paragraph in low-contrast grey sits between the
title and the empty state, immediately above a "Learn more about optical diagnostics"
link — i.e. the long-form explanation is printed *and* linked. No other Analytics tab
opens with a paragraph like this.
Evidence: same shot as SCI-1.

### SCI-3 — P2 — Observing Alerts header: three icon-only actions are absent from the accessibility tree
Repro: **Analytics ▸ Science ▸ Observing Alerts**; `drive_linux.py tree` and grep for buttons.
Expected: refresh / settings / (archive) icon buttons exposed with names.
Actual: the tree lists only the tab buttons and the four filter chips
(`All/New/Queued/Observed`). The three icon buttons rendered at the right of the sub-tab
bar (image x≈1177, 1215, 1253 y≈92 in `s09-alerts-empty.png`) have **no node at all** —
no name, no role. They are real controls: clicking x=1215 opens the Alert Settings dialog.
A screen-reader user cannot reach "refresh alerts" or "alert settings".
Evidence: `/tmp/ns-audit/gui-science-review/s09-alerts-empty.png`, tree output.

### SCI-4 — P2 — Alert Settings dialog: magnitude slider and notifications switch have no accessibility node
Repro: **Analytics ▸ Science ▸ Observing Alerts** ▸ gear icon (image 1215,92) ▸ read `tree`.
Expected: a slider node with a value, and a checkable node with `[ON]`/`[off]`
(the app does this elsewhere — e.g. `button: Glance mode [off]` on the Dashboard).
Actual: `tree` shows only `panel: Magnitude Threshold`, `panel: mag 15.0`,
`panel: Notifications`, `panel: Show notifications for new alerts`. Grepping the tree for
`check|switch|toggle|slider|[ON]|[off]` in this dialog returns **nothing**, so neither the
threshold nor the notification toggle is operable or readable by assistive tech.
Evidence: `/tmp/ns-audit/gui-science-review/s10-alert-settings.png`.

### SCI-5 — P3 — Alert Settings: the slider's value label wraps mid-value ("mag" / "15.0")
Repro: as SCI-4.
Expected: `mag 15.0` on one line, or the number aligned with the track.
Actual: the trailing label is squeezed into ~40 px and wraps to two lines, so the unit and
the number sit on separate rows next to a slider whose track ends 30 px earlier.
Evidence: `s10-alert-settings.png` (right of the slider, image ~750,478).

### SCI-11 — P1 — Analytics ▸ Session and Analytics ▸ Equipment Stats report the same data differently: 100 exposures / 3m 20s vs 248 exposures / 8m 16s
Repro: connect the simulator camera ▸ **Imaging** ▸ Save **on** ▸ **Loop** at 2 s ▸ let it
run ~10 minutes (248 frames) ▸ **Stop** ▸ nav **Analytics ▸ Session**.
Expected: EXPOSURES = every light frame of the session; INTEGRATION = their total exposure.
Actual: the Quick Capture header reads **EXPOSURES 100**, **INTEGRATION 3m 20s**
(= 100 × 2 s) and the frame list footer reads **Total: 100**, while
`sqlite3 …/data/skotiq.db "select count(*) from captured_images"` returns **248** and
`ls captures/*.fits | wc -l` returns **248**. True integration is 8m 16s; the first and last
`captured_at` are 621 s apart. The screen silently truncates to the newest 100 frames and
presents the truncated numbers as the session totals — the charts even say "All four charts
plot the same 100 accepted light frames", so the cap is known to the code but the summary
tiles are not labelled as capped. Integration time is the headline number of a night;
reporting 40 % of it is a trust-breaking error.
**Provable without the database:** switch to **Analytics ▸ Equipment Stats** on the same
data and it reads **Total Exposures 248**, **Accepted Integration 8m 16s**, **Avg HFR 2.79**.
Two tabs of the same screen, one dataset, numbers off by 2.5×.
Evidence: `/tmp/ns-audit/gui-science-review/s40-session-pop.png`; the chart x-axis stops at
4m for a 10m 21s session.

### SCI-12 — P2 — Quick Capture session shows DURATION "—" even with 100 exposures and a 10-minute wall time
Repro: as SCI-11, read the DURATION tile.
Expected: elapsed wall time of the session.
Actual: literal em dash. `imaging_sessions` is empty and every `captured_images` row has an
**empty `session_id`**, so loop captures belong to no session and the tile can never fill —
but the screen still presents itself as a session summary with three of four tiles
populated.
Evidence: `s40-session-pop.png`.

### SCI-13 — P2 — Every single frame of a clean run is badged "NEEDS REVIEW"
Repro: as SCI-11 ▸ scroll to **Captured Images**.
Expected: a clean simulated sky (HFR 2.7–2.9 px, ecc 0.22–0.25, 39 stars, flat focus, flat
temperature) grades mostly Good.
Actual: **Good: 0 · Needs Review: 100 · Poor: 0 · Total: 100** — 100 % of frames carry an
amber NEEDS REVIEW badge with scores 68–69. A badge that fires on every frame of a
textbook-clean run is noise, and it is the first thing a user sees about their data.
Evidence: tree output (`image: NEEDS REVIEW / 2.9 / R / 2s / 68 score`, ×100),
`s40-session-pop.png`.

### SCI-14 — P3 — Captured Images filter chips omit a category that the summary counts
Repro: as SCI-13.
Actual: the summary counts three grades (Good / Needs Review / Poor) but the chip row is
`All | Needs Review | Poor` — **Good has no chip** even though it is counted, while `Poor`
gets a chip at count 0. Whatever the rule is (hide-empty vs show-all) it is applied
inconsistently within one row.

### SCI-15 — P3 — Captured Images points the user at "Science > Grade frames", which is not a place in this app
Repro: as SCI-13, read the explainer under the "Captured Images" heading.
Actual: "Quality badges are advisory and never change acceptance on their own. Nothing is
deleted. **Science > Grade frames** is what rejects frames." The Science tab's sub-tabs are
*Science*, *First Light*, *Observing Alerts*; nothing on any of them is called "Grade
frames", so the one instruction telling a user how to reject frames names a menu path that
does not exist.

### SCI-7 — P2 — Live Stacking "Start" opens a bare GTK "Open File" chooser with no explanation; Cancel leaves it silently Idle
Repro: connect the Simulator camera/mount/focuser/filter wheel ▸ **Imaging** ▸ start a
2 s **Loop** ▸ right panel tab **Stack** ▸ click **Start** under *Live Stacking*.
Expected: stacking starts (Status → Stacking), or a prompt that says what it needs.
Actual: a GTK **"Open File"** window opens over the app — no title text, no instruction,
filter reads "Image files" while the app writes `.fits`. Nothing in the panel says a
reference frame is required. Verified with `xdotool search --onlyvisible --name "."
getwindowname %@`: before the click only `Skotiq`, after the click `Skotiq` +
`Open File` — reproduced 3×.
Pressing **Escape** (or Cancel) closes it and the panel goes back to `Status: Idle`,
`Stacked Frames 0`, with **no message at all** — the user gets no hint that Start did
anything or why nothing happened.
Picking a frame (`Ctrl+L`, `/tmp/ns-audit/gui-science-review/captures/Unknown_R_…_0010.fits`)
*does* start it (`Frame 3 stacked (3 total, …)` in the log), so the feature works — the
control just gives no clue what it is asking for.
Evidence: `/tmp/ns-audit/gui-science-review/s34-raw.png` (the chooser over the app).

### SCI-8 — P2 — Stack panel contradicts itself: "Alignment Quality: Excellent" beside "alignment may be off"
Repro: with live stacking running (SCI-7), let ~30 frames stack, read the Statistics block.
Expected: one verdict.
Actual: `Alignment Quality: Excellent` and, in the same card, an amber warning
**"Elevated sigma rejection on last frame — Above 5% rejected -- seeing, dithering, or
alignment may be off"** with `Rejection Rate (Last Frame) 10.57%`. The panel both grades
alignment Excellent and tells the user alignment may be off, on the same screen, from the
same data.
Evidence: `/tmp/ns-audit/gui-science-review/s38-stackrunning.png`.

### SCI-9 — P3 — Live Stacking statistics use four different placeholders for "no value"
Repro: **Imaging ▸ Stack** on a fresh session, before starting.
Expected: one empty-value convention.
Actual: in one 8-row block — `0` (Stacked Frames, Total Attempted, Rejected, Sigma-Rejected),
`—` em dash (Avg Matched Pairs, Avg Alignment Residual), `--` two hyphens (Rejection Rate),
and `No data` (Alignment Quality). Analytics ▸ Equipment Stats mixes the same two idioms
(`0` for counts, `No data` for averages) and the Imaging header uses a third (`---`).
Evidence: `/tmp/ns-audit/gui-science-review/s32-stackpanel.png`,
`/tmp/ns-audit/gui-science-review/s04-equipstats-empty.png`.

### SCI-10 — P4 — Shipped copy uses an ASCII double hyphen as a dash
Repro: as SCI-8; read the warning card.
Actual: "Above 5% rejected **--** seeing, dithering, or alignment may be off". Everywhere
else the product uses a proper em dash (e.g. "Alerts from TNS appear here", "Turn pretty
pictures…", the Diagnostics blurb all use —).
Evidence: `s38-stackrunning.png`.

### SCI-16 — P1 — Session Review of a FAILED run shows "Total 0 · Successful 0 · Failed 0" and never says why it failed
Repro: **Sequencer ▸ Builder** ▸ add *Target* + *Take Exposures* (2 s × 3) ▸ set the target
RA/Dec ▸ **Start** ▸ **Start Sequence** ▸ the run ends in seconds ▸ nav **Analytics ▸ History**
▸ click the session row.
Expected: the review of a failed run leads with the failure and its cause.
Actual: the detail dialog shows `Total Exposures 0 · Successful 0 · Failed 0 ·
Integration 0.00h` and `Images (0) — No images captured in this session`. **Failed: 0** for a
run whose own list row is badged **FAILED**, and there is no error text anywhere in the
dialog. The executor knew exactly what happened —
`WARN Daylight gate: refusing light-frame exposure — Sun altitude 15.1° is above the maximum
-12.0° for on-sky light imaging` — and that sentence never reaches the user's review of the
night. Reviewing a failed night is the entire job of this screen.
Evidence: `/tmp/ns-audit/gui-science-review/s48-sessionreview.png`; app.log
`Child 'Take Exposures' completed with status: Failure`.

### SCI-17 — P2 — Pre-Flight says "Ready with Warnings" for a condition that makes every frame fail
Repro: as SCI-16, with the sun up.
Expected: a condition that refuses 100 % of light frames is an error, not a warning.
Actual: Pre-Flight Validation reports **"Ready with Warnings — 2 warning(s) found"**, enables
**Start Sequence**, and shows the relevant line as a yellow warning: *"Sequence is expected
to start at 10:33, before the dark window starts at 01:09."* The run then fails on the very
first exposure with the daylight gate. Pre-flight is the feature that exists to prevent
exactly this, and it green-lit it.
Evidence: `/tmp/ns-audit/gui-science-review/s43-preflight.png` (the earlier, blocking state),
tree output `panel: Ready with Warnings / 2 warning(s) found`.

### SCI-18 — P2 — After a run that captured nothing, the app asks "How did this run go?"
Repro: as SCI-16; wait for the run to end.
Actual: a prompt appears — **"How did this run go? A quick note now is worth a long memory
later"** with *Write note* / *Don't ask again* — after a run that produced **0 frames** and is
recorded as `failed`. The retrospective prompt is identical whether the night succeeded or
collapsed on the first exposure; nothing in it acknowledges the failure.

### SCI-19 — P2 — Session Review's five header actions are unlabelled icons and are absent from the accessibility tree
Repro: as SCI-16, look at the dialog header.
Actual: five icon buttons sit to the left of the close X — a sparkle and **four
near-identical document glyphs**. None has a visible label or a tooltip discoverable
without hovering, and `tree` for the open dialog lists **no button nodes at all** (only
`panel: New Sequence`, `panel: Statistics`, … `panel: No images captured in this session`).
A user cannot tell the four export-looking icons apart, and a screen-reader user cannot
reach them.
Evidence: `/tmp/ns-audit/gui-science-review/s48-sessionreview.png`.

### SCI-20 — P2 — Analytics ▸ Diagnostics: the "Select session" control stays disabled even when a session exists
Repro: after SCI-16 (History now lists one session) ▸ **Analytics ▸ Diagnostics**.
Expected: the newly present session is selectable, or the screen explains why it is not
eligible (no plate-solved frames).
Actual: a **`Select session [DISABLED]`** button appears in the header — it did not exist at
all on the empty profile — and the body still reads "Select an imaging session to analyze".
The control the empty state tells you to use is present and dead, and nothing says the
session was skipped because it has no solved frames. (This is SCI-1 with a session in hand.)
Evidence: tree output `button: Select session [DISABLED]`.

### SCI-21 — P2 — Analytics ▸ History denies the session that Analytics ▸ Session is showing
Repro: capture a loop of frames as in SCI-11 (no sequencer run) ▸ **Analytics ▸ Session**
shows a populated "Quick Capture" session with duration/exposure/integration tiles and 100
graded frames ▸ switch to **Analytics ▸ History**.
Actual: "**No session history — Complete an imaging session to see history here**". The user
did complete one; the neighbouring tab is displaying it. Underneath, loop captures are
written with an empty `session_id` and no `imaging_sessions` row, so the two tabs are reading
different worlds — but the copy blames the user for not having done the thing they just did.

### SCI-22 — P2 — Science ▸ Plate solve health blames an unreachable solver when the solver is running and failing
Repro: after capturing frames (SCI-11) ▸ **Analytics ▸ Science**.
Actual: `0% · 0 of 100 solved` and the explanation **"No frames have solved this session —
most science products will stay empty until a solver is reachable."** ASTAP *is* configured
and *is* being invoked — app.log shows `Running ASTAP: "…/astap_cli" -f …` followed by
`No solution found!  :(` and `ERROR ASTAP exited with non-zero status 1`. The solver is
reachable; the solves are failing. The message sends the user to check their solver install
instead of their pointing/scale.
Evidence: `/tmp/ns-audit/gui-science-review/s41-science-pop.png`, app.log.

### SCI-23 — P2 — Science header chip truncates to "Plate solve…" inside a 1050 px-wide empty banner
Repro: as SCI-22, top of the Science tab.
Actual: a full-width status banner contains the label **"Plate solve…"** — ellipsised at
~13 characters — with roughly 900 px of unused space to its right, and the sub-line
"139 more queued". Truncating a two-word label in an almost-empty banner is the kind of
thing that gets screenshotted in a review.
Evidence: `s41-science-pop.png` (banner at y≈164).

### SCI-24 — P3 — Science: "139 more queued" cannot be reconciled with "0 of 100 solved"
Repro: as SCI-22.
Actual: the header says **139 more queued** while the Plate solve health card says
**0 of 100 solved** — the queue is larger than the population the card claims to be
measuring, and neither number is the 248 frames actually captured (see SCI-11).

### SCI-25 — P3 — Science guide marks step 2 complete while step 1 is not, and still offers "Run calibration"
Repro: **Analytics ▸ Science** after capturing frames.
Actual: the 5-step ladder shows step **2 "Track a star" with a green check** while step
**1 "Measure your sky" is unchecked** and the card's only CTA is still "Run calibration"
(= step 1). A numbered ladder that completes out of order, with the CTA pointing back at the
incomplete first rung, reads as broken progress tracking.
Evidence: `s41-science-pop.png`.

### SCI-26 — P3 — Analytics ▸ Science: stat cards in one row have ragged heights and mixed empty values
Repro: as SCI-22.
Actual: the four cards (CALIBRATION / TRANSPARENCY / UNIFORMITY CV / MOVING OBJECTS) are
top-aligned but not equal height — UNIFORMITY CV runs ~20 px lower than its neighbours
because of an extra badge row — and the row uses `N/A`, `—`, `0` and "No candidates" for the
four "nothing here" states. Equipment Stats has the same ragged-height problem (Camera card
3 rows, Mount card 1 row, in the same row band).
Evidence: `s41-science-pop.png`, `s04-equipstats-empty.png`.

### SCI-27 — P3 — Stacked Preview renders black while the same frames render a star field in the viewer
Repro: run the loop + live stacking (SCI-7) ▸ scroll the Stack panel to **Stacked Preview**.
Actual: with 8+ frames stacked and `Alignment Quality: Excellent`, the preview is an almost
entirely black rectangle with two or three barely-visible dots, while the main viewer beside
it shows the same sky with 39 detected stars. There is no stretch/auto-scale control on the
preview, so the one visual confirmation that a stack is working shows nothing.
Evidence: `/tmp/ns-audit/gui-science-review/s39-preview.png`.

### SCI-28 — P1 — Stopping a live stack silently destroys the stack: 32 frames of result reset to zero, nothing written to disk
Repro: run the loop + live stacking ▸ let ~30 frames stack (`Stacked Frames 32`,
`Alignment Quality Excellent`, preview populated) ▸ click **Stop** — nothing else.
Expected: stop ends accumulation and keeps the result (there is a separate **Reset Stack**
button for discarding it).
Actual: immediately after Stop the panel reads `Status: Idle`, `Stacked Frames 0`,
`Avg Matched Pairs —`, `Alignment Quality: No data`, and the Stacked Preview disappears.
Verified twice by reading only the `tree` between the two clicks (11 → 0). Nothing is
written out: `find /tmp/ns-audit/gui-science-review -newermt '-15 minutes' -type f` shows no
stack product, and the panel offers no save/export control. **Stop** is the only way to end
a live stack, and it is indistinguishable from **Reset Stack** — the user's stacked result is
gone with no confirmation and no recovery.

### SCI-6 — P3 — Analytics filter controls disagree with each other about empty data
Repro: **Analytics ▸ History** (filters `All Time`, `All Targets` are `[DISABLED]`), then
**Analytics ▸ Science ▸ First Light** and **▸ Observing Alerts** (filter chips
`All/Unnamed/Confirmed/Dismissed` and `All/New/Queued/Observed` are all enabled), all with
the same zero rows.
Expected: one convention for "filters over an empty list".
Actual: two conventions inside the same screen. History also leaves its **search field
enabled** while disabling the filters beside it, which is a third behaviour.
**And the History filters never enable**: after a real session exists and is listed,
`All Time` and `All Targets` are still `[DISABLED]`.
Evidence: tree outputs for the three tabs, before and after SCI-16.

### SCI-29 — P3 — Observing Alerts filter chips float in a bordered box that hugs nothing
Repro: **Analytics ▸ Science ▸ Observing Alerts** (empty or populated).
Actual: the `All | New | Queued | Observed` chips sit inside a bordered container that is
centred and only ~250 px wide, ending mid-screen at x≈853 while the source strip directly
above it spans the full width. It reads as a stray box rather than a toolbar.
Evidence: `/tmp/ns-audit/gui-science-review/s09-alerts-empty.png`.

### SCI-30 — P3 — Alert Settings names "Settings > Science" but does not link to it
Repro: **Analytics ▸ Science ▸ Observing Alerts** ▸ gear ▸ read the Alert Sources note.
Actual: "TNS … needs a bot ID, bot name and API key **from Settings > Science**" and the
empty state's status strip says "TNS: skipped — no API key". Neither is a link; the user has
to close the dialog, leave Analytics, open Settings, and find the Science section by hand.
Every other blocked state in the app I hit today shipped a button (Equipment's *Set
location*, Science's *Configure plate solver*).

### SCI-31 — P3 — The Narrator calls one minute of data "Best seeing of the night"
Repro: start the capture loop on a fresh profile and watch the Imaging viewer toast (also
feeds Analytics ▸ Science ▸ Night Story).
Actual: within ~60 s of the first frame ever recorded, a toast announces **"Best seeing of
the night — FWHM 5.4 px"**, and it is still on screen 5 minutes later. A superlative over a
population of one is noise, and 5.4 px FWHM is not a result worth celebrating.

### SCI-32 — P3 — "Set location" on Equipment ▸ Ready-to-image opens Settings on **General**, not Location
Repro: **Equipment** ▸ STATUS ▸ Ready to image ▸ **Set location**.
Expected: Settings ▸ Location, focused on the latitude field.
Actual: Settings opens on **General** (Startup / Behavior). The user must find *Location* in
the settings nav themselves. (Cross-cluster; recorded because it is on the path to every
Analytics screen that needs a site.)
Evidence: `/tmp/ns-audit/gui-science-review/s23-settings.png`.

### SCI-33 — P3 — Imaging ▸ Session card ships truncated button labels
Repro: **Imaging** ▸ right panel ▸ *Session* card.
Actual: the two buttons read **"View Quic…"** and **"Clear Sess…"**. Both are ellipsised in a
card with room to stack them.
Evidence: `/tmp/ns-audit/gui-science-review/s31-imaging2.png`.

---

## Screens covered

| Screen | State reviewed |
|---|---|
| Analytics ▸ Session | empty + populated (100/248-frame quick capture) |
| Analytics ▸ History | empty + populated (one FAILED session) |
| Analytics ▸ Projects | empty (before and after capture — never populated) |
| Analytics ▸ Equipment Stats | empty + populated |
| Analytics ▸ Science ▸ Science | empty + populated |
| Analytics ▸ Science ▸ First Light | empty |
| Analytics ▸ Science ▸ Observing Alerts | empty + Alert Settings dialog |
| Analytics ▸ Diagnostics | empty + with-a-session |
| Session Review (session detail dialog from History) | populated (failed run) |
| Stack Result (Imaging ▸ Stack ▸ Live Stacking) | idle, running (32 frames), post-Stop, Stacked Preview |

Reached as means, reviewed only where it touched the cluster: onboarding (skipped),
Equipment, Settings ▸ General/Location/Files & Storage, Imaging, Sequencer builder +
pre-flight.

## Screens I could not exercise

| Screen | Why |
|---|---|
| Analytics ▸ Projects (populated) | needs a *target* with multi-night history; quick-capture frames create no target and the one sequencer run captured 0 frames, so the tab never left its empty state. |
| Analytics ▸ Science ▸ First Light (populated) | needs solved frames differenced against an atlas ≥5 frames deep; **no frame solved** (ASTAP returns "No solution found" for the simulated field at the RA 0/Dec 0 default), so no candidate can exist. |
| Analytics ▸ Science ▸ Observing Alerts (populated) | TNS needs a bot ID/name/API key; none available offline. |
| Analytics ▸ Diagnostics (populated) | requires plate-solved frames with PSF/residual data — blocked by the same solve failure; see SCI-20. |
| Session Review of a **successful** run | the daylight gate refuses every light frame while the sun is up (SCI-17), so no successful sequencer session could be produced in this window. A verifier should re-drive SCI-16 after dark, or with the sun-altitude gate relaxed, to see whether the review screen fills in for a good night. |
| Science ▸ Photometry / Field Quality / Anomalies sub-views | rendered `[DISABLED]` throughout — gated on solved frames. |

