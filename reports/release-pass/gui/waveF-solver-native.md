# Wave F dryness check — cluster `solver-native`

Bundle: `apps/desktop/build/linux/x64/release/bundle/` — `lib/libapp.so` and
`lib/libskotiq_bridge.so` both mtime **Aug 13 23:56** (rebuilt after the E-fix batch).
Driven on display `:83`, profile `waveF-solver-native` (fresh runtime dir, seeded with the
Wave-E `waveE-imaging-stacking-polar` SQLite DB so the same 5-device sim profile —
Simulated Camera / Mount / Focuser / Filter Wheel / Built-in Multi-Star Guider — was connected).
Session log preserved at `reports/release-pass/gui/shots/waveF-solver-native/session.log`.
ASTAP concurrency sampled every 5 ms for the whole drive
(`/tmp/ns-audit/waveF-solver-native/astap-poll.txt`, 801 samples).

**Nothing assigned to this cluster is still broken.** Four new findings, none of them a
regression from the E-fix; two of them are the E-fix's own new output being wrong or arbitrary.

---

## Verified fixed

### IMG-14 (a) — the field-scale hint now reaches the solver that runs — FIXED

Whole-session tally: **6 ASTAP invocations, 6 of them carry `-fov`, 6 `ASTAP field-scale hint`
lines, 0 `skipping ASTAP -fov hint`.** Wave E's number was `grep -c -- "-fov"` = 0.

Polar wizard (5 solves — 3 measurement + 2 adjustment), binned 2×2:

    04:04:25.559732  Polar alignment solve scale hint: focal length 600.0 mm, pixel pitch 3.76 um (1.29"/px unbinned)
    04:04:30.627377  ASTAP field-scale hint: 2.59"/px over 540 px = -fov 0.3878 deg
    04:04:30.627389  Running ASTAP: … -f …/polar_align_point_1_… -fov 0.3878 -z 2 -d … -wcs
    04:04:30.656325  Point 1 solved: RA=0.0022°, Dec=0.0010°

The hint is the binned scale (1.29 × 2 = 2.59"/px) over the binned height (1080/2 = 540 px),
which is the number the frame actually has — the earlier `log_scale` line and the ASTAP argument
now agree, and the wizard ran to completion (`Polar alignment complete! Total error 2.7 arcsec`).

Imaging-screen snapshot solves, unbinned:

    04:06:37.250895  ASTAP field-scale hint: 1.29"/px over 1080 px = -fov 0.3878 deg
    04:08:20.367324  Running ASTAP: … -f …/Unknown_R_2026-08-14_0010.fits -ra 2.000156 -spd 90.001131 -r 30.00 -fov 0.3878 -z 2 -d … -wcs

The second line is the E-fix's explicit claim that "a near solve carries position **and** scale",
observed live. The solve succeeded and annotated the frame (`Found 1 objects` / PGC 7511,
`shots/waveF-solver-native/15-snapshot.png`).

### IMG-14 (b) — the parked-mount refusal now says something — FIXED

Mount Parked → Imaging → Mount tab → Three-Point Polar Alignment: the footer renders, in warning
colour with a warning icon, **`Cannot start: Mount is parked — unpark it before aligning`**, and
the same string is in the a11y tree as a panel node
(`shots/waveF-solver-native/07-polar.png`). Wave D/E read `Ready to start polar alignment` here.
Clicking Start Alignment is inert (log 630 → 630 lines, no phase change) — but the reason is
already on screen and stays there, which is the substance of the item. Unparking the mount flips
the same footer to `Ready to start polar alignment` and the run then starts normally, so the
notice is live state, not a static string.

The one part of the E-fix claim I could **not** confirm is the disabled *state* reaching the
platform: the tree still reads `button: Start Alignment` with no `[DISABLED]`. That is not
specific to this button — see WF-SN-N4 — so it is filed as its own finding rather than counted
against IMG-14.

### ND-E2 — no concurrent duplicate solves — FIXED

The duplicate caller still exists, but it is now coalesced and **named in the log**, and the
5 ms poller measured **max concurrent `astap_cli` = 1** across the entire drive (6 solves,
including both snapshot cases that produced two callers).

Snapshot 1 — blind led, near followed:

    04:06:37.250394  Blind plate solving: …/Unknown_R_2026-08-14_0009.fits
    04:06:37.250910  Running ASTAP: … -fov 0.3878 …            (one process)
    04:06:37.261222  Plate solve (near): …/Unknown_R_2026-08-14_0009.fits is already being solved;
                     waiting for that result instead of starting a second solver process

Snapshot 2 — near led, blind followed (proving the guard releases and re-arms per frame):

    04:08:20.367324  Running ASTAP: … -ra 2.000156 -spd 90.001131 -r 30.00 -fov 0.3878 …
    04:08:20.371659  Plate solve (blind): …_0010.fits is already being solved; waiting for that result …

Wave E's `max concurrent astap_cli = 2` does not reproduce.

### IMG-9 — Auto Select attempt + lock observable in UI and log — FIXED

Guiding → Built-in Multi-Star Guider → Loop Exposures → Auto Select. The panel's own notice
banner appears inside the Guiding Controls card and **persists**: still on screen and in the a11y
tree 21 s after the click (`panel: Guide star selected at (25.5, 24.5)` + `button: Dismiss notice`,
`shots/waveF-solver-native/04-autoselect.png`). Wave E found no notice, no toast and no status
text anywhere. Three dedicated log lines, in the implementation that runs:

    04:09:01.406124  Auto Select: asking the built-in guider 'native:builtin_guider:multi_star' to pick a guide star
    04:09:01.406559  Auto Select: chose a guide star at (967.8, 724.3) px out of 107 detections
    04:09:01.406581  Auto Select: locked guide star at (24.8, 25.3) px

Reproduced twice (looping, and stopped-with-a-cached-frame). The detection count that separates
"empty frame" from "full frame, none usable" is present. The number itself is wrong — WF-SN-N1.

---

## New findings

### WF-SN-N1 — P3 — Auto Select reports the guide star in crop coordinates, so its two lines contradict each other

The E-fix made a number operator-visible that is not the star's position. Same click, consecutive
log lines, twice:

    Auto Select: chose a guide star at (967.8, 724.3) px out of 107 detections
    Auto Select: locked guide star at (24.8, 25.3) px

and the new panel banner renders the second one: **`Guide star selected at (24.8, 25.3)`**
(`shots/waveF-solver-native/17-autoselect-stopped.png`; the first run read `(25.5, 24.5)` for a
star chosen at `(963.5, 722.5)`).

Mechanism: `builtin_guider/control.rs::find_star` stores the full-frame position
(`manual_lock = selected_pos`, and publishes `GuidingEvent::StarSelected { x: selected.x, y: selected.y }`)
but **returns** `snapshot.star_x / star_y` (control.rs:340-344), which is inside the 50 px crop
built one line earlier by `update_snapshot_from_frame(&mut guard, &guide_frame, 50)`. That return
value is what `api/phd2.rs:857` prints as "locked" and what the new UI banner shows. The same file
proves the two spaces are different: `set_lock_position` converts the other way by adding
`snapshot.crop_origin_x/y` to the incoming coordinate.

Why it matters: the operator is told the guider locked a star at pixel (25, 25) — the extreme
corner of a 1920×1080 guide frame — when it locked one near the centre at (963, 722). Any attempt
to reconcile that with PHD2, a manual lock position, or a bug report reads as a different star.

### WF-SN-N2 — P3 — the coalescer serves whichever caller wins the race, so an available position hint is discarded at random

ND-E2's fix dedupes the two callers but does not decide *which* solve should run; the first
arrival leads. Live, the same button 103 s apart produced opposite winners: snapshot 1 ran a
**blind** solve while the near caller with `-ra/-spd` waited on it; snapshot 2 ran the **near**
solve while the blind caller waited (both transcripts above). On the simulator a blind solve costs
0.04 s so the coin-flip is invisible; on a real rig a blind ASTAP solve is tens of seconds against
a few for a hinted one, and it is the case that can lock onto the wrong field — so half the
centering/annotate solves on a real night pay the blind cost while holding a perfectly good
position hint. The underlying defect Wave E actually reported — that one snapshot issues two solve
requests for one frame — is still there; only its symptom (two processes) was closed.

### WF-SN-N3 — P4 — the Guide Star panel draws a bright star and labels it `SNR: 0.0`

Guiding, loop stopped, cached frame present → Deselect → Auto Select: the panel renders the star
crop with crosshairs and the badge reads **`SNR: 0.0`** (`shots/waveF-solver-native/17-autoselect-stopped.png`);
the same panel read `SNR: 445.9` while looping, and the moment Loop Exposures is pressed again the
a11y tree reads `panel: SNR: 70.6`. A guide star that is plainly visible and was just selected out
of 107 detections is being labelled with a signal-to-noise ratio of zero rather than the value from
the frame it was selected from, or a blank.

### WF-SN-N4 — P3 — a disabled SkotiqButton reaches the Linux a11y bridge as an enabled button, so `[DISABLED]` can never be evidence

`SkotiqButton` sets `Semantics(button: true, enabled: !isDisabled)` (skotiq_button.dart:194-196,
`isDisabled = widget.onPressed == null || widget.isLoading`), and the polar screen passes
`onPressed: canStart ? _startAlignment : null` — so the parked-mount Start Alignment button *is*
disabled (the click is provably inert, and it renders in the muted style). The AT-SPI tree still
reports `button: Start Alignment` with no `[DISABLED]`. Same for `button: Start Track` on the
Imaging → Mount panel while the mount is parked (it flipped to the enabled style the instant the
mount was unparked). Corroborating negative: **no** `button: … [DISABLED]` line exists in any tree
dump under `/tmp/ns-audit/` from Waves D, E or F — only `panel: … [DISABLED]` nodes, i.e. other
widget families that lose the button role when disabled.

Two consequences. For an operator on Orca, a disabled primary action announces as an ordinary
button. For this campaign, the E-fix's "the Start button's semantics node has `isEnabled == false`"
is true in the widget tree and untestable at the platform, and Wave D/E's "button not `[DISABLED]`
in the a11y tree" was never evidence of anything — no wave should use that as a claim again.
Root cause may be Flutter's Linux a11y bridge rather than app code; it needs one experiment
(a plain `ElevatedButton(onPressed: null)` in this app) to attribute.

---

## Settled, not filed

Wave E left `Sky --` in the imaging toolbar as an unresolved observation and Wave D cited it as
evidence a solve had failed. It is neither: `imaging_preview_toolbar.dart:87-88` renders
`'Sky --'` when there is no transparency reading and `'Sky <bucket>'` otherwise — it is a sky-quality
readout, unrelated to plate solving or cursor coordinates. It stayed `--` here on a frame that
solved and annotated successfully because this rig has no transparency source
("No weather data sources available" on the dashboard). Wave D's inference from it was wrong.

Also checked and correct: the polar screen's adjustment card ("Azimuth Right 0.5″ / Altitude Down 2.7″"
against readouts −0.5″ / 2.7″) — the instruction opposes the error sign in both axes, so the two
surfaces agree; and Stop on the wizard clears the run and returns the screen to its intro state,
which is the documented difference from Done.
