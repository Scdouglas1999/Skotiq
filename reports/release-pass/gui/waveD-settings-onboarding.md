# Wave D verification — cluster: settings-onboarding

Instance: `NS_AUDIT_DISPLAY=:84 python3 tools/ui_audit/drive_linux.py <cmd> --profile waveD-settings-onboarding`
(profile **after** the subcommand; `start --fresh --profile waveD-settings-onboarding`)
Build: `apps/desktop/build/linux/x64/release/bundle/skotiq_desktop` (binary dated 2026-08-13 18:31), Xvfb :84, softpipe.
Window: 1600x900 for all repros unless stated; one pass at 1000x800.
Date: 2026-08-13. Nothing was fixed in this pass — verification only.

Fresh profile driven end to end: onboarding steps 1-13 (Sim backend enabled at step 2 so the device
steps have something to select), Dashboard + Dashboard Tour, Settings (General, Remote Access,
Remote Connection Pairing, Equipment Profiles, Help & Tutorials, Autofocus).

---

## Verdicts on assigned findings

| ID | Verdict |
| --- | --- |
| SET-17 | VERIFIED_FIXED |
| SET-1 | VERIFIED_FIXED (with a new defect in the replacement text — WD-N1) |
| SET-3 | VERIFIED_FIXED |
| SET-9 | VERIFIED_FIXED |
| SET-8 | VERIFIED_FIXED |
| SET-12 | STILL_BROKEN (primary claim; the "step 12 unreachable" secondary is fixed) |
| SET-18 | STILL_BROKEN (3 of 4 sub-claims fixed; the screen-reader path is still dead — WD-N4) |
| SET-23 | VERIFIED_FIXED |
| SET-2 | STILL_BROKEN (repro (a) unchanged; repro (b), the invented "Filter 7", is fixed) |
| SET-5 | VERIFIED_FIXED (with a residual on step 13 — WD-N3) |
| SET-11 | VERIFIED_FIXED |
| IMG-1 | VERIFIED_FIXED |

### SET-17 — inherited pairings on a fresh install — VERIFIED_FIXED
`start --fresh` → onboarding completed → Settings → Remote Access → Enable Remote Access →
Manage Pairing. The Paired Devices card reads **"No paired devices / Start pairing mode to connect a
device"**. On disk the store is now inside the scratch profile:
`/tmp/ns-audit/waveD-settings-onboarding/data/pairing.db` exists with `paired_devices` = **0 rows**,
while the developer's own `~/Documents/Skotiq/pairing.db` still holds its 13 rows — i.e. the two
stores are no longer the same file. **Revoke All exists**: I paired a real device to prove it
(`Start Pairing Mode` → code `METEOR-MOON-8511` read from `pairing_sessions` →
`POST /api/pairing/verify` with `deviceId=waveD-test-phone`, scope `control`). The list then showed
`WaveD Test Phone · Android phone or tablet · Can control the rig · Paired: Just now · Not seen yet`
and a red **Revoke All** button appeared in the Paired Devices header. Clicking it raised
"Revoke Every Paired Device — Revoke access for all 1 paired devices? …"; confirming set
`is_active=0` on the row and the token was immediately rejected (`GET /api/status` with that bearer →
**403**). Revocation is real, not cosmetic.

### SET-1 — bare red backend chips — VERIFIED_FIXED (see WD-N1)
Step 3 "Pick your camera" now renders `⊙ Native (0)`, `⚠ Alpaca (0)`, `⚠ INDI (0)`, `⊙ Sim (1)` —
counts on every chip — plus per-backend explanation lines that the a11y tree exposes verbatim
(`panel: Native: scan complete, 0 found`, `panel: Alpaca: nothing answered — …`). The "no message,
no count, nothing for a screen reader" defect is closed. What replaced it is not shippable copy: see
WD-N1.

### SET-3 — PHD2 green-over-red / stale red line — VERIFIED_FIXED
Step 7, no PHD2 running. **Test** → `No response on localhost:4400. Is PHD2 running with "Enable
Server" turned on?`. **Use PHD2** → a **single** amber line replaces both:
`Guider set to PHD2 at localhost:4400, but nothing answered there yet. No response on
localhost:4400. Is PHD2 running with "Enable Server" turned on?` (button becomes `PHD2 selected`,
with a `Clear` beside it). Selecting **Built-in Multi-Star Guider** reverts the button to
`Use PHD2` **and removes the PHD2 status line entirely** — a11y tree grep for `respon|Guider set`
returns nothing. Evidence: `/tmp/ns-audit/waveD-settings-onboarding/s07b-crop.png`.

### SET-9 — "No site on record yet" after a successful detect — VERIFIED_FIXED
Step 11 → Use my current location → Detect location. After the detect the "No site on record yet…"
banner and its **Estimate from IP** button are **gone** from the card, and the fields read
`39.9527` / `-75.1635` — **4 decimals**, matching the Review step's `39.9527°, -75.1635°`.
Evidence: `/tmp/ns-audit/waveD-settings-onboarding/s11b-crop.png`.
Residual (not a regression): the accuracy caveat now disappears with the banner — nothing on the
screen afterwards says the site came from an IP estimate good to ~10 km.

### SET-8 — 680 px consent dialog — VERIFIED_FIXED
Step 11 → Use my current location. The dialog is content-sized: it spans y≈228→491 of a 720-px
capture (~263 px, i.e. ~330 px of the 900-px window), title at the top, two paragraphs immediately
below, Cancel / Detect location directly under the text. No floating body, no dead bands.
Evidence: `/tmp/ns-audit/waveD-settings-onboarding/s11-consent.png`.

### SET-12 — Dashboard Tour narrates panels that are not there — STILL_BROKEN
Default dashboard after onboarding (a11y tree + `s13-dash.png`) contains exactly:
Tonight's Briefing, the twilight bar, **Tonight's targets**, **Readiness**, **Last run**, **Moon**.
Walking the tour with `Right` this build still reports:
`step 2 of 12: Customize Layout`, `step 5 of 12: **Session Progress**`,
`step 6 of 12: **Weather Status**`, `step 9 of 12: **Focuser Control**`,
`step 10 of 12: **Equipment Overview**`, `step 12 of 12: Dashboard Complete`.
Four of the five mid-tour steps I sampled still describe panels that are not on this dashboard.
Fixed half: the tour now reaches **step 12 of 12 ("Dashboard Complete")**, which the previous pass
could not reach, and the tour card exposes `Skip tour` / `Next step` as named buttons.

### SET-18 — pairing mode promises a phrase — STILL_BROKEN (mostly fixed)
Settings → Remote Access → Pair phones and tablets → **Start Pairing Mode** now produces:
a centred QR, a visible **Pairing phrase `ZENITH-NOVA-5610`**, **`Expires in 4:49`** counting down,
and a **`Stop pairing mode`** button. The QR itself is now labelled for a11y
(`panel: Skotiq pairing QR for 192.168.1.20:8080`). Evidence: `s30-crop.png`.
What is still broken is the part the finding called out last: **the phrase value is not exposed to
accessibility**. The tree gives `panel: Pairing phrase` and then `panel: Expires in 4:49` — grep for
`ZENITH|NOVA|5610` returns nothing. A screen-reader user is told a phrase exists and is not told what
it is, so the "no path for a blind user to pair" complaint survives the fix (see WD-N4; the same
applies to the numeric code in the Manage Pairing page).

### SET-23 — fake-editable read-only boxes — VERIFIED_FIXED
Settings → Equipment Profiles → My First Rig. Focal Length / Aperture / Focal Ratio / Default Gain /
Default Offset / Cooling Temp now render as plain values with small grey captions on the card ground
— no filled, bordered input chrome. Binning X/Y remain visibly interactive segmented controls (blue
selected chip), so live and dead controls no longer share one visual language. a11y also joins them:
`panel: Focal Length: 1234 mm`, `panel: Cooling Temp: -10°C`.
Evidence: `/tmp/ns-audit/waveD-settings-onboarding/s31-crop.png`.

### SET-2 — "Add slot" on a full wheel — STILL_BROKEN (part a)
Step 6 → Simulated Filter Wheel → 7 slots, caption "All 7 positions on this wheel are listed."
Clicking **+ Add slot** produces **no eighth row, no toast and no message**: `tree` before and after
the click is byte-identical (`diff` of two dumps = empty), and the button is **not** reported
`[DISABLED]` by the role-based dump, so it is an enabled control that does nothing.
Fixed half (repro b): deleting slot 7 ("SII") flips the caption to "Simulated Filter Wheel reports 7
positions.", and **+ Add slot** then restores slot 7 as **"SII"** — not the invented "Filter 7".
The saved profile agrees: Review step and Equipment Profiles both list `L, R, G, B, Ha, OIII, SII`.
Evidence: `/tmp/ns-audit/waveD-settings-onboarding/s06b-crop.png`.

### SET-5 — telescope-library badge — VERIFIED_FIXED (see WD-N3)
Step 8 → Choose from telescope library → Askar FRA400 → badge `Askar FRA400`. Editing Telescope focal
length to `1234` flips the badge to **`Askar FRA400 — edited`** while the computed rows update
(1234.0 mm, f/17.14). The green "validated" assertion is gone.

### SET-11 — camera preset silently rewrites the typed pixel size — VERIFIED_FIXED
Typed `3.76` on step 8 → step 9 → Choose from camera library → search `294` → ZWO ASI294MC Pro.
The step-9 card now shows a disclosure: **"Defaults loaded from preset — Pixel size changed from 3.76
to 4.63 µm by the ZWO ASI294MC Pro preset. Edit it on the previous step if your camera differs."**
Step 8's pixel-size placeholder was also rewritten to `e.g. 3.76 — or load it with your camera on the
next step`, so the two screens no longer contradict each other about whether the library knows it.

### IMG-1 — capture-folder validation latches — VERIFIED_FIXED
Step 10, typed `/tmp/ns-audit/waveD-nonexistent/captures`, **Next** → blocked with
`That folder does not exist.` Then, without leaving the step, ctrl+a and typed `/tmp`: within ~3 s
the field re-validated to **`Folder is writable.`** — the stale error and the stale
`Pick a capture folder.` snackbar both cleared, and Next advanced. No Back-then-Next remount needed.
(Note: while the path is *invalid*, the app still shows both `That folder does not exist.` and the
snackbar `Pick a capture folder.` at once — SET-7's contradiction, unassigned here, is unchanged.)

---

## New findings from the adversarial sweep

### WD-N1 — P2 — First-run device steps print raw Rust error debug text at the user
Onboarding steps 3-7, any backend that is not answering (default state on a machine with no Alpaca /
INDI server — i.e. the common case):

> `Alpaca: nothing answered — Alpaca server connection failed:
> SkotiqError.connectionFailed(deviceId: localhost:11111, reason: Failed to connect to Alpaca
> server: error sending request for url (http://localhost:11111/management/v1/configureddevices):
> error trying to connect: tcp connect error: Connection refused (os error 111))`

Four wrapped lines of red developer text on the third screen of the product, twice over (Alpaca and
INDI), on every device step. The useful half is the prefix the fix added ("Alpaca: nothing
answered —"); everything after the em dash is an internal enum dump with a URL, a Rust error chain
and an errno. Evidence: `/tmp/ns-audit/waveD-settings-onboarding/s03-camera.png`, and the same string
verbatim in the a11y tree.
Related, unresolved: the native log for the same scan still reports
`Discovery complete for Camera: 1 devices, 0 backend errors` while the UI shows two backend errors —
the original SET-1 log/UI disagreement was not settled by this fix.

### WD-N2 — P3 — Onboarding step 6 draws two texts on top of each other
Step 6 "Pick your filter wheel", 1600x900, with a wheel selected: the caption
"All 7 positions on this wheel are listed." and the hint "No matching device? You can skip this step
and add it later from the Equipment screen." are painted **over each other** at image y≈314, both
legible as overlapping glyph soup. Evidence: `/tmp/ns-audit/waveD-settings-onboarding/s06-fw.png`.
Likely triggered by the taller backend-error block that WD-N1 describes pushing the Filters header
row into the hint line.

### WD-N3 — P3 — Step 13 re-asserts the library scope that step 8 had marked "edited"
After editing the Askar FRA400's focal length to 1234 mm (badge correctly reads
`Askar FRA400 — edited`), the final step's summary says flatly **`Telescope: Askar FRA400`** beside
`Image scale 0.77 arcsec/px` — a scope model that does not have this focal length. The honest marker
is dropped exactly where the wizard makes its closing statement about the rig.

### WD-N4 — P2 — The pairing credential is the one thing not exposed to a screen reader
Two places, same shape:
* Remote Access → Pair phones and tablets → Start Pairing Mode: `panel: Pairing phrase` is exposed;
  the value `ZENITH-NOVA-5610` is not (grep of the tree finds no such node).
* Settings → Manage Pairing → Start Pairing Mode: `Enter this code on your device:` and
  `Expires in 04:55` are exposed; the code (`METEOR-MOON-8511`, read out of `pairing_sessions`) is
  not.
So the SET-18 fix labelled the QR but left the only non-visual credential unreadable. The Manage
Pairing page's back arrow (image 198,54) also has no accessible name.

### WD-N5 — P3 — "X paired" success banner survives revoking that very device
Manage Pairing: after **Revoke All** the page shows the green banner `WaveD Test Phone paired` at the
top and `No paired devices` in the list below it, at the same time. Evidence:
`/tmp/ns-audit/waveD-settings-onboarding/s27-dlg.png` (taken after the revoke).

### WD-N6 — P4 — Revoke confirmation has no singular form
`Revoke access for all 1 paired devices?` — shown verbatim with one device paired.

### WD-N7 — P3 — The Settings Tour coach mark covers the Manage Pairing button
Settings → Remote Access at 1600x900 with remote access on: the bottom-right "Settings Tour" card
sits on top of the **Manage Pairing** button in the "Pair Remote Browsers" row; the button is only
clickable after dismissing the card with Maybe Later.
Evidence: `/tmp/ns-audit/waveD-settings-onboarding/s25b-crop.png`.

### WD-N8 — P4 — "Reset All Progress" promises a tour it does not bring back
Settings → Help & Tutorials → Reset All Progress → confirm ("…you will see the welcome tour again").
Returning to the Dashboard in the same session shows no tour nudge and no tour; the Tutorial Tours
list is still five entries, all "Not started", still with no Dashboard Tour or Settings Tour among
them (SET-21, unassigned, unchanged).

### WD-N9 — P4 — SET-20 residual: the "Pair phones and tablets" card is still shrink-wrapped when idle
In a ~1150 px content column it draws ~530 px wide while every other card on the leaf is full width;
it snaps to full width only once pairing mode is running. (The Library Management instance of SET-20
was not re-checked.)

---

## Things that were checked and are clean

* **Settings shell (SET-14)**: the rail and content now run to the bottom of the window and
  **ADVANCED** is visible without scrolling, at both 1600x900 and 1000x800.
* **Card widths (SET-20)** on Remote Access: Web Server / Open on this computer / Share on your
  network / Pair Remote Browsers are all full width. (Idle pair-phones card is the exception, WD-N9.)
* **Onboarding switch a11y (SET-6)**: step 9 reports
  `toggle button: Regulated cooling [off]` → `[ON]`, and `toggle button: Start cooling when the
  camera connects [off]`.
* **Autofocus leaf a11y (SET-19)**: `toggle button: Auto-learn focus models` is named and there are
  **zero** unnamed `text:` nodes in the leaf.
* **Two coach marks fighting (SET-13)**: only one card ("Dashboard Tour") is shown after onboarding.
* **Layout at 1000x800**: Dashboard collapses to a single column and Settings keeps its rail +
  content; no clipping or overflow seen. Nothing regressed at the narrow width.
* **Camera step now blocks Next** until a camera is picked ("Pick a camera to continue, or use
  'Skip onboarding' to set it up later") — a behaviour change from the previous pass, and correct.

## Not covered

* Tour steps 3, 4, 7, 8 titles (the walk sampled 2/5/6/9/10/12) and whether any step spotlights a
  target — after step 12 the tour ends and the nudge does not come back in-session (WD-N8), so a
  second run needs a restart.
* SET-4, SET-7, SET-10, SET-15, SET-16, SET-21, SET-22, SET-24…SET-29 were not re-verified (not
  assigned); SET-7's double message and SET-27's `1/5` vs four status-bar devices were both observed
  unchanged in passing.
