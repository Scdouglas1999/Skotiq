# Wave E dryness check — cluster: imaging-stacking-polar

Harness: `tools/ui_audit/drive_linux.py`, display `:82`, profile `waveE-imaging-stacking-polar`,
release bundle `apps/desktop/build/linux/x64/release/bundle/skotiq_desktop`
(`libapp.so` + `libskotiq_bridge.so` both **Aug 13 20:33** — newer than the last D-fix commit
`baddf35fd` at 20:30; freshness confirmed by string-grep: `libapp.so` carries
`Live-stack masters are saved as PNG` and `No catalog objects in this frame`,
`libskotiq_bridge.so` carries `Plate-solve scale hint provided but NAXIS2 unreadable; skipping
ASTAP -fov hint`).

Rig: built-in **Sim** drivers only (Simulated Camera / Mount / Focuser / Filter Wheel, plus the
Built-in Multi-Star Guider added mid-session). Optical train re-created to match Wave D:
600 mm / 100 mm / 3.76 µm → **1.29 arcsec/px**. Site 42.36, -71.06. Captures in
`/tmp/ns-audit/waveE-imaging-stacking-polar/caps`, log `…/app.log`, shots `…/shots`.

---

## Verdicts on the assigned D-fix items

### ND-1 — VERIFIED_FIXED (P1, live-stack counters frozen / Stop dialog under-reports)
Two runs, both driven to well past 20 frames.

*Rejecting run* (reference frame captured **before** the polar run moved the mount, so the field
genuinely no longer matches): panel climbed to `Total Attempted 42 · Rejected (Alignment) 41 ·
Stacked Frames 1`, `Alignment Quality **Poor**` in red. The log carries exactly 41
`Frame rejected: alignment residual 29.78px exceeds max 2.00px` warnings. The counters now move
with the engine instead of freezing at the last accepted frame (`shots/s30-stack-counters.png`).

*Accepting run* (Reset, fresh reference from the current pointing): `Stacked Frames 29 · Total
Attempted 29 · Rejected 0`, `Avg Matched Pairs 98.0 stars`, `Avg Alignment Residual 0.44 px`,
`Alignment Quality Excellent`. Log at rest: 69 `Adding frame to stack` lines − 41 rejected in run 1
= 28 accepted, +1 reference = **29**, matching the panel exactly.

*Stop dialog*: “Stopping releases the stacker, and the **29 stacked frames** accumulated so far
cannot be recovered…”. In the earlier run the same dialog said “the **1** stacked frame”, which was
also true (41 of 42 rejected). Truthful in both directions.

### IMG-4 / ND-2 — VERIFIED_FIXED (P2, failed solve wearing the success treatment)
Three states measured on the same screen:
* **solve succeeds, no catalog hit** — neutral amber card, `No catalog objects in this frame / The
  frame was solved but nothing in the installed catalogs falls inside it…` (`shots/s18-annot.png`).
  The claim is **true**: running the app's own ASTAP invocation by hand on that exact frame
  (`astap_cli -f … -ra 0 -spd 90 -r 30 -z 2 -wcs`) solves in 0.04 s, `Solution found: 00:00 00.0
  +00d 00 01`, and writes a valid `.wcs`. Wave D read the missing sidecar as failure; since SCI-48
  the sidecar lives in the per-attempt scratch dir, so that half of the old evidence is void.
* **solve succeeds with a catalog hit** — green `Found 1 objects` chip with `PGC 7511` plotted on
  the frame (`shots/s30-stack-counters.png`).
* **solve genuinely fails** — frame type set to `Dark` (0 stars): `Plate solve failed / Too few
  stars (0 found, need 10+) — increase exposure time or check focus`. No green, no invented count.

ND-2 (annotate solving a different path from the polar wizard) is closed with it: annotate now runs
through the same service, and on the same sim sky it succeeds where the wizard succeeds and fails
honestly where there is nothing to solve.

### IMG-13 — VERIFIED_FIXED (P2, slew headline one point behind)
Full TPPA run sampled every ~2 s. At 00:47:45 and 00:47:47 the status headline and the detail line
read the **same** point: `Slewing to point 2 of 3` (headline) + `Slewing to point 2...` (detail).
Capture and solve phases stayed consistent too (`Capturing point 2/3...` + `Capturing point 2 of
3`; `Plate solving point 2/3...` + `Plate solving point 2 of 3`). The off-by-one is gone.

### IMG-14 — STILL_BROKEN (P2, both halves)
**(a) No field-scale hint anywhere.** `grep -c -- "-fov"` over the whole session log = **0**. The
polar wizard still logs `Polar alignment solve scale hint: focal length 600.0 mm, pixel pitch
3.76 um (1.29"/px unbinned)` at 00:47:38 and then every one of its five solves is
`Blind plate solving: …` with `astap_cli -f … -z 2 -d … -wcs` — no `-ra`, no `-spd`, no `-fov`.
Imaging-screen solves carry the position hint (`-ra 0.000000 -spd 90.000000 -r 30.00`) but never
`-fov`. The native code the D-fix batch pointed at is in the shipped `.so`
(`platesolve.rs:864 fov_deg = scale * naxis2 / 3600`), so the gap is that **no caller passes
`hint_scale`** — the Dart-side `-fov` work landed in `PlateSolveService.astapArguments`, which is
not the implementation that runs. Two implementations, one runs.

**(b) The parked-mount refusal is still silent.** Mount `Parked` → Polar Alignment → click
`Start Alignment`: log 310 → 310 lines, no run, no message, footer still `Ready to start polar
alignment`, and the button is **not** `[DISABLED]` in the a11y tree (`shots/s22-polar-full.png`).
Unchanged from Wave D; the D-fix batch's report does not claim to have addressed this half.

### IMG-16 — VERIFIED_FIXED (P2, bullseye denies a measurement that is on screen)
Completed run (`shots/s23-polar-done.png`, crop `shots/s24-bullseye-done.png`): the marker is
plotted (red/blue dot just off centre, correct for a 3.2" error against 30"/60"/120" rings), the
`No measurement yet` caption is **gone**, and the numeric row beneath reads `Azimuth 2.7" ·
Altitude 1.8" · Total 3.2"` in green — all three elements now agree with the `Alignment Complete —
Final error: 3.2"` headline. During the run, before the first measurement, the caption correctly
reads `No measurement yet`; at idle the panel shows the explainer and `-- / -- / --`.

### ND-3 — VERIFIED_FIXED (P2, green “Complete” beside a red “Worse”)
Same completed run: `Before 3.3" (Az 2.8"/Alt 1.7") → After 3.2" (Az 2.7"/Alt 1.8")` and the chip
now reads a neutral **No change** instead of red *Worse* (`shots/s23-polar-done.png`).

### ND-6 — VERIFIED_FIXED (P3, master save silently rewrote .fits → .png)
Stop → `Save master` → typed `/tmp/ns-audit/waveE-imaging-stacking-polar/out/stack_master.fits`:
**nothing is written** (`ls` of the directory is empty) and a dialog appears —
*“Live-stack masters are saved as PNG … a ".fits" master cannot be written here — the format
carries no FITS header, WCS or integration metadata … The stack is still running and was not
discarded.”* (`shots/s33-fitsrefusal.png`). Status stayed `Stacking` afterwards, as promised. The
chooser's own type label reads `Stacked master (16-bit PNG)` and the Stop prompt names the format
up front. Re-saving as `.png` still works: `stack_master.png` = *PNG image data, 1920 x 1080,
16-bit grayscale*.

### IMG-10 — VERIFIED_FIXED, with a residual (P2, Pause does nothing observable)
With the Built-in Multi-Star Guider connected, clicking `Pause` now raises a dismissible inline
notice in the control panel: *“Pause is a PHD2 feature. The built-in guider has no pause — use Stop
to suspend guiding.”* (`shots/s43-pausenotice.png`). The click is no longer silent, and the reason
reaches touch users, not just hover.

Residual (not a new defect, a correction to the D-fix report's own claim): the button is **not**
disabled. It is not marked `[DISABLED]` in the a11y tree, it renders in the same enabled treatment
as `Start`/`Loop Exposures`, and it plainly responds to the click. The batch report says
`onPressed == null` and “the button IS disabled”; the running app disagrees.

### IMG-9 residual — STILL_BROKEN (P3, Auto Select is silent)
Guiding → `Loop Exposures` → `Auto Select`, three times (including once immediately after
`Deselect`, and once with a clean panel and no other notice on screen): **no notice, no toast, no
status line appears anywhere in the a11y tree**, and no dedicated line appears in either log
stream — only the loop's own `[STAR_DETECT]` / `camera_start_exposure` entries. The D-fix batch
claims `_autoSelectStar` now “logs the attempt, logs and reports the star it locked (with
coordinates)”; nothing of the sort is observable in the running app.
(The other half of IMG-9 — `Frame Count 0` for the whole loop — is unchanged and was adjudicated an
owner-decision item, so it is not counted here.)

---

## New findings (adversarial sweep of the same screens)

### ND-E1 — P3 — a 100 %-rejecting stack never shows the number that explains it
When every frame is refused, `Avg Matched Pairs` and `Avg Alignment Residual` both stay `—`,
because they are averages over *accepted* frames. So the panel shows `Rejected (Alignment) 41`
and `Alignment Quality Poor` with no residual figure and no threshold anywhere on screen, while the
log has the whole story: `Frame rejected: alignment residual 29.78px exceeds max 2.00px (27 of 27
matches used)`. Repro: start live stacking with a reference frame from a different pointing, loop
2 s frames for a minute. This is ND-1's own shape one level down — the counters now move, but the
one number that would tell the operator to fix their reference or raise the tolerance is still
missing. (Control: with a reference from the current pointing, 29/29 frames stacked and both fields
populate — `98.0 stars`, `0.44 px` — so the fields work, they are just scoped to accepted frames.)

### ND-E2 — P3 — some captures launch two concurrent ASTAP solves of the same frame, one of them blind
Three snapshots early in the session (00:41:27, 00:44:17, 00:44:30) each produced a hinted solve and
a **blind** solve of the same file, started 3.6–23 ms apart:

    00:41:27.651770  Plate solving near RA:0.00°, Dec:0.00°: …/Unknown_R_2026-08-14_0001.fits
    00:41:27.652267  Running ASTAP: … -f /tmp/skotiq-solve-1704317-0/… -ra 0.000000 -spd 90.000000 -r 30.00 …
    00:41:27.656196  Blind plate solving: …/Unknown_R_2026-08-14_0001.fits
    00:41:27.695193  Running ASTAP: … -f /tmp/skotiq-solve-1704317-1/… -z 2 -d … -wcs

A process poller sampling every 5 ms measured **max concurrent `astap_cli` = 2**. The 4 ms gap rules
out a fallback-after-failure: this ASTAP solves the frame in 0.04 s and the second process starts
before the first can have finished. So the “blind demoted to fallback” ordering is real in the log
but two callers still solve the same frame at once, and one of them throws away the position hint
the other used — on real hardware a blind solve is tens of seconds and can return the wrong field.
Intermittent: it reproduced 3/3 in the first minutes (mount reading RA 0.00 / Dec 0.00) and 0/4
later (mount tracking at RA 30, and again after re-parking to RA 0 / Dec 90), so the trigger is not
simply “parked”; the mechanism is not identified. Evidence is in the log lines above plus
`/tmp/astap-poll.txt`.

### ND-E3 — P3 — after saving an edited profile, the status bar names devices by driver id
Before the edit the bottom status bar read `Camera Simulated Camera · Mount Simulated Mount`
(`shots/s19-equip2.png`). After Equipment → Edit Profile → assign the Built-in Multi-Star Guider →
`Save Changes` → Connect All, the same bar reads `Camera **sim_camera_1** · Mount **sim_mount_1**`
(`shots/s46-statusbar.png`, `shots/s45-guiding3.png`) — the raw driver ids — while the Equipment
cards one screen away still show `Simulated Camera` / `Simulated Mount` for the same devices. Same
family as the open L36 item (devices reporting their ProgID rather than their model), but here the
app *had* the friendly name and lost it on a profile save.

---

## Unresolved observation (not filed)

The viewport's `Sky --` readout never showed a position, including on the snapshot whose annotation
card asserts *“The frame was solved”* and whose frame I independently solved with ASTAP. Moving the
pointer over the image (`wheel x y 0`) did not change it. I could not establish what `Sky` is meant
to display (cursor coordinates vs frame centre), so I am recording it rather than filing it; Wave D
cited the same `Sky --` as evidence that IMG-4's solve had failed, and that inference is now known
to be wrong.
