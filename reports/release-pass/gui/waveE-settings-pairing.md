# Wave E dryness check — settings-pairing

Binary: `apps/desktop/build/linux/x64/release/bundle/skotiq_desktop`
(`lib/libskotiq_bridge.so` dated 2026-08-13 20:33, newer than the launcher — this is the
fresh bundle). Driven with `tools/ui_audit/drive_linux.py`, `NS_AUDIT_DISPLAY=:84`,
profile `waveE-settings-pairing`, started `--fresh`. Evidence:
`/tmp/ns-audit/waveE-settings-pairing/` (s01…s71).

Scope: WD-N1..N9 plus the SET-2 / SET-12 / SET-18 residuals, and the pair + revoke-all flow end
to end. Nothing was fixed in this pass.

---

## Verified fixed (11)

### WD-N1 — raw Rust error debug text in the onboarding chips — FIXED
Fresh wizard, Alpaca+INDI left ON (shipped default), no servers listening. Step 3 now prints two
one-line sentences (s03-camera.png):

```
Alpaca: nothing answered — nothing is listening at localhost:11111
INDI: nothing answered — nothing is listening at localhost:7624
```

A11y tree grep over the whole frame for `SkotiqError|os error|tcp connect|http://` returns
nothing but those two sentences. The same two lines carry through steps 4 and 6 unchanged.

### WD-N2 — step 6 painted two texts on top of each other — FIXED (residual, see WE-SP-1)
Step 6 with the Simulated Filter Wheel selected: the slot caption and the "No matching device?"
hint no longer overlap; the picker body now scrolls as one (verified with `wheel`, s06e-crop.png
shows caption, hint and Filters header in normal document order). No `RenderFlex overflowed` in
`app.log`. Residual clipping recorded as a new finding below.

### WD-N3 — step 13 re-asserted the edited-away scope name — FIXED
Step 8: telescope library → Askar FRA400 (400 mm), focal length edited to 1234, badge reads
`Askar FRA400 — edited` (s08d-edited.png). Step 13 "You're all set" now reads
`Telescope  Askar FRA400 — edited` with `Image scale 0.63 arcsec/px`
(206.265 × 3.76 / 1234 = 0.628 — the number matches the edited focal length, s15-final.png).

### WD-N4 / SET-18 residual — the pairing credential is unreadable to a screen reader — FIXED
LAN panel, Start Pairing Mode: screen shows `GALAXY-MARS-9417`; the a11y tree carries
`panel: Pairing phrase: GALAXY-MARS-9417` (s26-phrase.png + tree). Manage Pairing screen:
`panel: Pairing code: GALAXY-MARS-9417`, and the back arrow is now `button: Back to Remote
Access` (s27-manage.png + tree). Grep for the literal credential now hits in both trees.

### WD-N5 — the "paired" banner survived revoking that device — FIXED, and joined on identity
Paired `WaveE Test Phone` via `POST /api/pairing/verify`, revoked it: banner gone, list reads
"No paired devices" (s28→s30). Adversarial check that the fix is an identity join and not a
count/order heuristic: with two devices paired (`Pixel 8`, `Sean iPad`, banner naming Sean iPad),
revoking **Pixel 8** left the Sean iPad banner standing and dropped only the Pixel row
(s32-two.png → s35-after1.png). Revoking Sean iPad afterwards dropped the banner.

### WD-N6 — "Revoke access for all 1 paired devices?" — FIXED, plural intact
One device → `Revoke Device Access` / `Are you sure you want to revoke access for "WaveE Test
Phone"? …` / confirm `Revoke Access` (s29-revokedlg.png). Two devices → `Revoke Every Paired
Device` / `Revoke access for all 2 paired devices? …` / `Revoke All Access` (s37-revokeall.png).

### WD-N7 — Settings Tour coach mark covered Manage Pairing — FIXED, SET-14 not regressed
Remote Access with the server running and the tour card up: the detail pane now ends above the
card and `Manage Pairing` sits at y=380 fully clear of the card at y=578–670 (s23-remote-scroll.png).
Non-regression on SET-14: the section navigator keeps full height and `ADVANCED` is reachable at
1600×900 (s24-navcrop.png) and at 420×900 phone width with the card up (s71-phone-scroll.png).

### WD-N8 — "Reset All Progress" promised a tour that never came back — FIXED
Dashboard tour completed and Settings tour prompt dismissed ("Maybe Later") first. After
Help & Tutorials → Reset All Progress → Reset, the Dashboard Tour card is back on the dashboard
(s46-dash2.png) and the Settings Tour card is back on Settings (s47-set.png), in the same session.
(The separate complaint that "Tutorial Tours" never lists a Dashboard/Settings tour is unchanged —
that list still shows the same five workflow tutorials; the D-fix did not claim it.)

### WD-N9 — SET-20 residual: idle "Pair phones and tablets" card shrink-wrapped — FIXED
Idle (s23-remote-scroll.png) and pairing (s26-phrase.png) both draw the card from x=410 to
x=1254, identical to the full-width "Pair Remote Browsers" card above it.

### SET-2 residual (a) — "+ Add slot" on a full wheel — FIXED, round trip intact
At 7/7 the control is gone; header reads `Wheel is full` and the caption states the reason:
"All 7 positions on this wheel are listed — Simulated Filter Wheel has no slot 8 to hold another
filter." (s06b-fw-sel.png). A11y grep finds no node named "Add slot" (only `panel: Wheel is
full`), so no tap action is offered to assistive tech. Regression check on residual (b): deleting
slot 7 brings the button back and re-flips the caption to "Simulated Filter Wheel reports 7
positions." (s60-deleted.png); clicking it restores `SII`, not `Filter 7`, and the button
disappears again (s61-readded.png).

### Pair + revoke-all end to end — WORKS, and revocation is real
`Start Pairing Mode` → code read off the screen → `POST /api/pairing/verify` (three devices over
the run) → rows appear with correct type labels (`Android phone or tablet`, `Tablet`, `Mac`) →
`Revoke All` → confirm → list empty, banner gone (s38-allrevoked.png). The token minted for a
revoked device is then rejected by the API:
`GET /api/pairing/devices` with that bearer → `{"error":"Access denied","message":"Invalid
authentication token"}`. So the revoke is enforced at the wire, not only in the list.

---

## Still broken (1)

### SET-12 — the dashboard tour narrates panels this dashboard does not have
The D-fix batch recorded this as BLOCKED (owning files outside its SCOPE). Confirmed unchanged.
Dashboard after onboarding contains exactly: Tonight's Briefing + twilight bar, Tonight's targets,
Readiness, Last run, Moon (s16-dash.png, s18-dash-bottom.png — the whole scroll extent).
Walking the tour with `Right` and dumping the tree after each press:

```
Tutorial step 1 of 12: Welcome to Dashboard
Tutorial step 2 of 12: Customize Layout
Tutorial step 6 of 12: Weather Status      <- no Weather Status panel on this dashboard
Tutorial step 11 of 12: Active Sequence    <- no Active Sequence panel on this dashboard
Tutorial step 12 of 12: Dashboard Complete
```

The pass-over does now skip runs of absent steps (2→6, 6→11), but it still parks on, and
announces, absent steps 6 and 11.

---

## New findings (5)

### WE-SP-1 (P3) — the onboarding device picker clips the selected device row mid-glyph
Step 6 with the Simulated Filter Wheel selected: the device card is cut through the middle of its
subtitle — "Sim" is drawn with its lower half missing and the card's bottom border is absent
(s06b-fw-sel.png, 1:1 crop s06c-crop.png). The content is reachable (mouse wheel over the picker
scrolls it, s06e-crop.png) but at rest there is no scrollbar, no fade, no affordance — it reads as
a rendering fault, and the row it truncates is the one the operator just selected. Same at step 6
on the re-run (s60-deleted.png, s61-readded.png). This is the residual of the WD-N2 fix: the step
still hands the picker a fixed-height box, and with the two backend-error lines present the
scrollable body starts clipped.
Repro: 1600×900, `start --fresh`, enable Sim at step 2 keeping Alpaca+INDI on, walk to step 6,
select Simulated Filter Wheel, look at y≈271.

### WE-SP-2 (P3) — the first nav click after "Reset All Progress" is swallowed, and the rail lies
After Settings → Help & Tutorials → Reset All Progress → Reset, one click on the **Dashboard**
rail item repaints that row in the selected treatment but leaves the Settings screen on screen.
Six seconds later the screen is still Settings and the tree still reports
`panel: Help & Tutorials`; a second click navigates (tree then contains "Tonight's Briefing"/"No
run active"). Reproduced twice (s43/s44/s45, then s55-navafterreset.png → s56). The rail asserting
"you are on Dashboard" while Settings is displayed is the cry-wolf half of this; the swallowed
click is the cost.
Repro: Settings → Help & Tutorials → scroll to Reset Progress → Reset → confirm → click
"Dashboard" in the left rail once → screenshot.

### WE-SP-3 (P3) — the pairing empty state is drawn at 1.31:1 contrast
"Start pairing mode to connect a device" under "No paired devices" is painted with
`colorScheme.outline` as a body-text colour
(`packages/skotiq_app/lib/screens/settings/pairing_screen.dart:271-275`). Measured on
s38-allrevoked.png: brightest glyph pixel `rgb(43,49,59)` against background `rgb(24,28,34)` →
contrast **1.31:1** (WCAG AA needs 4.5:1 for body text). The string is in the a11y tree, so this
is a purely visual failure — sighted users at a dark rig will not see the only instruction the
empty state offers.

### WE-SP-4 (P4) — the pairing-code card is one giant "button", and the copy control is nameless
While pairing mode is running, the whole Pair New Device card collapses into a single semantics
node with role **button** whose name concatenates four unrelated strings:

```
button: Pair New Device
Enter this code on your device:
Expires in 04:53
Cancel Pairing
```

There is no separate node for the copy-to-clipboard icon drawn under the code — it has no
accessible name at all, and clicking it produces no toast, no label change and no other visible
confirmation (s65-code.png → s66crop.png at 3 s, s67 immediately after the click). Whether the
clipboard is actually written could not be checked on this box (no `xclip`/`xsel` installed), so
this is reported as "no feedback and no accessible name", not as "copy is broken". Same class as
the back-arrow finding WD-N4 just repaired, one card over.

### WE-SP-5 (P4) — the "Build tonight's plan?" nudge covers the Moon card's Moonrise time
Dashboard scrolled to the bottom: the floating nudge (x 537–920, y 537–645) is drawn over the Moon
card (x 258–722), hiding the Moonrise value while leaving "Moonset 20:34" visible
(s18-dash-bottom.png). Adjacent to my cluster only because the dashboard is where SET-12's tour
runs; recorded so it is not lost.

---

## Notes / non-findings

* `Unrecognised device type (phone)` on a paired row is a **harness artifact**: I POSTed
  `deviceType:"phone"`, which no real client sends (`mobile` / `android` / `ios` / `tablet` /
  `browser` / platform names are all handled). Real values render correctly — verified with
  `android` → "Android phone or tablet", `tablet` → "Tablet", `macos` → "Mac".
* The reserved band the WD-N7 fix holds for the tour card costs ~120 px of the settings detail
  pane while a nudge is up (first Tutorial Tours row is clipped, s51.png). Everything stays
  reachable by scrolling at both 1600×900 and 420×900, so this is the intended trade, not a defect.
* WD-N1's out-of-scope companion is unchanged: `app.log` still records "Discovery complete for
  Camera: 1 devices, 0 backend errors" for the same scan the UI reports two backend errors for.
