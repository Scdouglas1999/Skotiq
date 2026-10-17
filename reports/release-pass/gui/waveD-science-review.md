# Wave D verification — cluster: Analytics / Science / Session Review / Stack Result

**Date:** 2026-08-13 (evening). **Harness:** `tools/ui_audit/drive_linux.py`, display `:77`
(the harness picks the display; `--profile` after the subcommand), profiles
`waveD-science-review` (populated) and `waveD-sci-fresh` (empty-state check).
**Binary:** `apps/desktop/build/linux/x64/release/bundle/skotiq_desktop`, built
18:31 today, with `lib/libskotiq_bridge.so` of the same timestamp — i.e. the fresh
bundle, not a stale one.

**State built for the repros:** Skip onboarding ▸ Equipment ▸ *I'll do it manually* ▸
Discovery ▸ Expand ▸ Connect **Simulated Camera** + **Simulated Mount** ▸ Settings ▸
Files & Storage ▸ Image output = `/tmp/ns-audit/waveD-science-review/data/captures` ▸
Imaging ▸ Save on ▸ **Loop** 2 s → 37 light frames ▸ Sequencer ▸ Builder ▸ Take Exposures
(3 s × 4) ▸ Start ▸ Start Anyway → a **completed** run, 4/4 frames. ASTAP is installed and
was invoked per frame (38 attempts, all exit 1), which is the state SCI-22/SCI-48 need.

Screenshots for every claim below are in
`/tmp/claude-1000/-home-scdouglas-Documents-Skotiq2/224b7868-cbfc-40e1-8fb0-99c71d23f174/scratchpad/`
(`s01`–`s29`).

---

## Verdicts on assigned findings — 10 of 10 VERIFIED_FIXED

| ID | Verdict | What I saw |
|----|---------|-----------|
| SCI-34 | VERIFIED_FIXED | Fresh profile ▸ Analytics lands on **Session**: *"Nothing captured yet / Start a capture or a sequence and this tab fills in as the frames arrive."* **History** on the same empty profile still says *"No session history / Complete an imaging session to see history here"* — the two tabs no longer print the same sentence. |
| SCI-36 | VERIFIED_FIXED (all 4 instances) | (1) Analytics ▸ Projects ▸ Mosaic projects header is `button: Back` with no `[DISABLED]`, and clicking it returns to Projects. (2) Analytics ▸ Diagnostics is `button: Learn more about optical diagnostics`, enabled. (3) History's chips are `button: All Time` / `button: All Targets`, and the menu they open lists `button: All Time`, `button: This Month`, `button: This Year` — no `[DISABLED]` anywhere. (4) Same on the empty profile, so it is not a data-state artifact. |
| SCI-37 | VERIFIED_FIXED | Tiles now read **`Advisory 74`** / **`Advisory 75`**, and the frame dialog reconciles the two numbers explicitly: rows **`Recorded quality score 84.4 / 100`** and **`Advisory score 74 / 100`**, with the sentence *"Advisory 74/100 — the recorded quality score (84) minus the review penalties listed above."* DB cross-check for the same frame (`captured_images` id 37): `quality_score = 84.3744`, `star_count = 39`, `hfr = 2.1796` — matches the dialog's 84.4 / 39 / 2.18 px. |
| SCI-38 | VERIFIED_FIXED | The frame dialog's summary line now reads **"Good — noted but not disqualifying: Low star count (39)"**. The dash-clause is explicitly framed as a non-disqualifying note, so it no longer reads as the reason for the grade. Grid still counts `Good: 37 · Needs Review: 0 · Poor: 0`. |
| SCI-41 | VERIFIED_FIXED | **Integrate now** on a run with 4 accepted frames does real work: the panel switched to *"An integration is already running."* with a **Preview… 100%** progress readout, and ~40 s later the card rendered an actual integrated master image with a **Rejection** overlay toggle, plus "Integration improvement / Predicted SNR vs subs kept". Not a no-op. |
| SCI-42 | VERIFIED_FIXED | The focuser sentence appears **exactly once** in the Session Report (`grep -c` over the full a11y dump of the dialog = 1). There is no longer a *"Noticed but Did Not Fire"* subsection repeating it; **Diagnostics** now carries a different item ("Cooler Out of Setpoint Band"). |
| SCI-44 | VERIFIED_FIXED | Symmetric check. With **Narrative** open, "Narrative" is the accent-blue chip with bright text and "Workbench" is plain (`s22`); with **Workbench** open the treatment swaps exactly (`s23`). The state is no longer inverted, and both are `button:` with no `[DISABLED]`. |
| SCI-46 | VERIFIED_FIXED (assigned scope) | Analytics ▸ Diagnostics ▸ Select session offers **"Quick captures (no session)"**, and selecting it renders real diagnostics for the 37 loop frames: Optical Health with **Tilt 66**, a **48-tile PSF Field Map**, findings, and an honest *"Collimation not measured — no astrometric residuals on both sides of the field"*. History also now lists a **Quick captures** card describing the 37 frames instead of denying them. **But see NEW-1**: the Session and Science pickers do not offer the same entry. |
| SCI-22 | VERIFIED_FIXED | Analytics ▸ Science ▸ Plate solve health now reads: *"No frames have solved this session, and a solver (ASTAP, catalog D05) is installed — so it is running and failing, not missing. Check focal length and pixel scale first, then whether the catalog covers this field."* That matches `app.log` exactly (`Running ASTAP: …astap_cli -f … -wcs` followed by `ASTAP exited with non-zero status 1: Using star database D05`, 38 times). The message no longer sends the user to check their solver install. |
| SCI-48 | VERIFIED_FIXED | The solver now runs in a per-attempt scratch dir — `Running ASTAP: … -f "/tmp/skotiq-solve-1490486-4/Unknown_NoFilter_2026-08-13_0004.fits"` — instead of in the capture folder. After **38 solve attempts** over 41 frames, `ls` of `/tmp/ns-audit/waveD-science-review/data/captures` is `41 fits · 41 jpg · 1 masters/` and `find … -name '*.ini'` returns **0**. The scratch dirs are also cleaned: only the single in-flight `/tmp/skotiq-solve-*` dir existed at any sample point. |

---

## New findings

### NEW-1 (P2) — Analytics ▸ Session and ▸ Science can never go back to the quick captures once a sequence run exists
Repro: with the 37-frame quick capture **and** the 4-frame run both present, open
**Analytics ▸ Session**. The new **Reviewing** selector reads *"Quick captures (no session
selected)"*. Open it → the menu contains exactly one entry, **"New Sequence · Aug 13, 2026
18:45 · 4 frames"**; there is no "Quick captures" entry. Select the run → the tab switches
to the run (`MEDIAN HFR 5.70`, 4 exposures). Re-open the selector → still only the run.
Navigate to History and back to Session → still the run. Identical behaviour on
**Analytics ▸ Science** ("Analysing" selector, same single entry).
Why it matters: the 37 frames' charts, Captured Images grid, photometry and field-quality
products become unreachable for the rest of the app's life, and **History's own Quick
captures card instructs the user to "open Analytics ▸ Session to review them frame by
frame"** — an instruction that cannot be followed. Clicking that History card does nothing
either. This is the same family as SCI-46, and the fix appears to have landed in only one
of the three pickers: **Diagnostics** does offer "Quick captures (no session)".
Evidence: `s25.png`, tree dumps of both popup menus (one entry each).

### NEW-2 (P3) — Science's Photometry / Field Quality / Anomalies jump chips are announced as disabled panels while working
Repro: **Analytics ▸ Science** with quick-capture frames ▸ `drive_linux.py tree`.
The three chips are exposed as `panel: Photometry [DISABLED]`, `panel: Field Quality
[DISABLED]`, `panel: Anomalies [DISABLED]`. Clicking **Field Quality** works — it jumps the
page to the FIELD QUALITY section (`s18.png`). Same defect shape as the four SCI-36
instances that were fixed; these three were missed.

### NEW-3 (P3) — Pre-Flight Validation's primary action is not exposed as a button
Repro: **Sequencer ▸ Start** ▸ `tree`. Siblings are `button: Re-check` and `button: Cancel`,
but the green primary action prints as **`panel: Start Anyway`** — no button role, no state.
A screen-reader user is never told the run-anyway control is a control. (It works when
clicked, so this is announcement-only.)

### NEW-4 (P3) — At 900 px the Analytics tab strip's scroll chevrons paint on top of the tabs
Repro: `resize 900 800` ▸ **Analytics** ▸ click the right-hand `>` affordance.
The left `‹` chevron is drawn over the selected tab rather than in a reserved gutter, so
**History** renders as `Hi ‹ y` (`s27.png`) and later as `lis ‹` (`s28.png`), and
**Diagnostics** is clipped mid-word under the right chevron. The strip scrolls correctly —
only the chevron placement is wrong. Not reproducible at 1600×900.

### NEW-5 (P3) — Night Doctor scores a run 100/100 "no problems detected" while the same screen badges every sub of that run POOR
Repro: after the 4-frame run ▸ **Session Report ▸ Review & Integrate**. The header says
*4 accepted · 0 rejected*, **Narrative** shows **100 / 100 · "A clean night — no problems
detected." · Excellent · 0 findings**, and **Workbench** shows all four subs badged red
**POOR** with **HFR 5.7** against the panel's own cull line of 3.5 (`s22.png`, `s23.png`).
The accept-vs-badge split is documented policy elsewhere ("quality badges are advisory and
never change acceptance"), so the defect is narrower: a night in which *every* frame is
graded POOR is reported as having **0 findings** and a perfect score.

---

## Observations (other cluster findings seen in passing — not assigned, not re-filed)

- **SCI-39 is addressed**: pre-flight now warns *"No Observing Location Set … This run
  proceeds with the daylight gate and the altitude limits switched off"*, and the run
  completed 4/4 instead of being refused with a Null-Island Sun altitude.
- **SCI-40 still reproduces**: pre-flight still demands darks at `temp=-10.0C` for a camera
  reporting 20.0 °C everywhere.
- **SCI-23 still reproduces**: the Science header chip is still ellipsised to
  **"Plate solve…"** in an otherwise empty full-width banner, at both 1600 px and 900 px.
- **SCI-24 still reproduces in spirit**: the same banner said *"25 more queued"* while the
  card below read *"0 of 4 solved"* for the selected run.
- **SCI-25 is session-dependent**: with the quick captures selected the science ladder still
  shows step 2 green-checked while step 1 is not; with the run selected it renders 1–5
  unchecked.
- Sequencer frames measured HFR 5.68 / FWHM 11.37 while quick-capture frames on the same
  simulated camera minutes earlier measured HFR 2.15. Flagged only as something to explain,
  not as a finding — I could not attribute it from the GUI.

## Coverage

Analytics ▸ Session (empty + populated + per-frame dialog + session selector), ▸ History
(empty + two entries + both filter menus), ▸ Projects (+ Mosaic drill-in and Back),
▸ Science (quick-capture view and run view, jump chips, plate-solve health, night story,
science guide), ▸ Diagnostics (empty, picker, quick-capture selection with PSF map),
Session Report (completed run, all sections), Session Review (Narrative + Workbench,
Integrate now through to a rendered master), plus the supporting Equipment/Imaging/Settings/
Sequencer path. Layout checked at 1600×900 and 900×800.
