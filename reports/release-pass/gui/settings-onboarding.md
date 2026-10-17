# GUI release pass — cluster: settings-onboarding (wave 2)

Instance: `NS_AUDIT_DISPLAY=:84 python3 tools/ui_audit/drive_linux.py <cmd> --profile gui-settings-onboarding`
Build: `apps/desktop/build/linux/x64/release/bundle` (softpipe, Xvfb :84), fresh scratch profile.
Date: 2026-08-13

Scope driven: first-run onboarding, First Night Walkthrough (tutorial), every Settings leaf, pairing
screens. This is a second adversarial pass over the same cluster; the 2026-08-11 report (SET-1..SET-21)
is superseded by this file, and every finding below was re-observed live on today's build.

> Harness note, not an app finding: `drive_linux.py --profile X <cmd>` silently ignores the profile
> (the subparser re-declares `--profile` with default `main`, which wins). The profile must come
> **after** the subcommand: `start --fresh --profile gui-settings-onboarding`.

---

## Findings

### SET-1 — Device-discovery backends render as bare red ⚠ chips with no message, no count, and no way to find out what is wrong (P2)

Screen: Onboarding step 3 of 13 "Pick your camera" (and every later device step — Mount, Focuser,
Filter wheel, Guider — which reuse the same chip row).

Repro:
1. Fresh profile → step 2 "Which drivers should we scan?" — leave the shipped defaults
   (Native ON, Alpaca ON, INDI ON, Sim off).
2. Next → step 3 "Pick your camera".

Expected: each backend chip says what happened — `Alpaca (0)`, or a chip the user can click/hover to
get "No Alpaca server answered on this network".

Actual: the row renders `⊙ Native (0)` in green, then `⚠ Alpaca` and `⚠ INDI` in red, with no count
and no explanation. The chips are inert: `click-img` on the Alpaca chip changes nothing in the tree
and opens nothing. The accessibility tree exposes them as `panel: Alpaca` / `panel: INDI` — no role,
no state, no error text, so the alarm is invisible to a screen reader as well.
The app's own log for the same scan says `Discovery complete for Camera: 1 devices, 0 backend errors`,
so the UI is showing two red alarm states for a scan the backend considered clean.
Evidence: `/tmp/ns-audit/shots-set3/03-camera.png`, `/tmp/ns-audit/shots-set3/03b-chips.png`.

Why it matters: this is the third screen of the product's first run. Two unexplained red warnings on
a rig that is working is exactly the impression a paid product cannot afford.

### SET-2 — "Add slot" is a live-looking button that silently does nothing on a full wheel, and re-adding a slot invents a filter name (P3)

Screen: Onboarding step 6 of 13 "Pick your filter wheel (optional)".

Repro (a):
1. Step 6 → select **Simulated Filter Wheel**. Seven slots populate (L, R, G, B, Ha, OIII, SII) under
   the caption "All 7 positions on this wheel are listed."
2. Click **+ Add slot**.

Expected: the button is disabled (with a reason) or it tells you the wheel is full.
Actual: nothing at all happens — no eighth row, no toast, no message; the tree is byte-identical
before and after. The button renders in its normal enabled style.

Repro (b), the invented name:
3. Click the trash icon on slot 7 ("SII"). The caption honestly changes to
   "Simulated Filter Wheel reports 7 positions." and six rows remain — good.
4. Click **+ Add slot** again.

Actual: slot 7 comes back containing **"Filter 7"**, a name the user never typed, and the caption flips
back to "All 7 positions on this wheel are listed." Filter names travel into FITS headers, flat
matching and per-filter focus offsets, so a silently invented name is a data-quality problem, not just
cosmetics. Evidence: `/tmp/ns-audit/shots-set3/06-filterwheel.png`,
`/tmp/ns-audit/shots-set3/06b-slot7.png`.

### SET-3 — Guiding step shows a green "Guider set to PHD2" line directly above a red "No response" line, and the red line outlives the choice it belongs to (P2)

Screen: Onboarding step 7 of 13 "Set up guiding (optional)".

Repro:
1. Step 7, with no PHD2 running, click **Test** beside Host `localhost` / Port `4400`.
   Red line appears: `No response on localhost:4400. Is PHD2 running with "Enable Server" turned on?`
2. Click **Use PHD2**.
   Actual: the card now stacks two contradictory status lines —
   green `✓ Guider set to PHD2 at localhost:4400.` directly above
   red `⚠ No response on localhost:4400. Is PHD2 running with "Enable Server" turned on?`
   Evidence: `/tmp/ns-audit/shots-set3/07c-guider2.png`.
3. Now select the **Built-in Multi-Star Guider** radio underneath.
   Actual: PHD2 is correctly deselected (button reverts to "Use PHD2") and the green line clears, but
   the red PHD2 failure line **stays on screen** even though PHD2 is no longer the chosen guider. The
   user ends the step having picked a working native guider while the screen still shows a red error.

Expected: one status line that matches the current selection, cleared when the selection changes.

### SET-4 — One invalid optics input produces three different behaviours, including a confidently asserted "0.0 mm" (P3)

Screen: Onboarding step 8 of 13 "Tell us about your optics".

Repro:
1. Step 8: focal length `1000`, aperture `200`, pixel size `3.76`. Computed values read
   `1000.0 mm` / `f/5.00` / `0.78 arcsec/px` — all correct.
2. Click the Reducer / Barlow field, `ctrl+a`, type `0`.

Expected: all three computed rows agree that the input is invalid.
Actual, simultaneously:
- Effective focal length: **`0.0 mm`** — asserted as a fact, with no error styling.
- Focal ratio: `Check your inputs`.
- Image scale: `Awaiting inputs…` — untrue; every input has been supplied, one is just invalid.
3. Click **Next**: correctly blocked, but the app then shows the same problem worded two different ways
   at once — `Reducer must be > 0 (use 1.0 for no reducer).` under the field and
   `Reducer factor must be greater than zero.` at the bottom of the form.

Evidence: `/tmp/ns-audit/shots-set3/08b-computed-zero.png`.

### SET-5 — The telescope-library badge keeps asserting a scope model after you edit the numbers out from under it (P3)

Screen: Onboarding step 8 of 13 "Tell us about your optics".

Repro:
1. Click **Choose from telescope library** → pick **Askar FRA400** (`400mm f/5.6 · 72mm refractor`).
   The fields fill in and a green `✓ Askar FRA400` badge appears beside the library button.
2. Click the Telescope focal length field, `ctrl+a`, type `1234`.

Expected: the badge clears (or changes to something like "Askar FRA400 — modified") once the values no
longer describe that scope.
Actual: the badge still reads a green-ticked `✓ Askar FRA400` while the form says 1234 mm, 72 mm,
f/13.71 — a scope that does not exist. The green check reads as "validated against the library".
Evidence: `/tmp/ns-audit/shots-set3/08d-askar-label.png`.

### SET-6 — Every switch in the wizard is invisible to accessibility, while the checkboxes two steps earlier are not (P2)

Screen: Onboarding step 9 of 13 "Set your capture defaults" — switches "Regulated cooling" and
"Start cooling when the camera connects". Same component appears in Settings leaves.

Repro:
1. Walk to step 9. `tree` → the screen exposes `panel: Regulated cooling` and its description, and
   **no checkable node at all**; grep for `check box`, `[ON]`, `[off]` returns nothing on this screen.
2. Screenshot shows a real switch drawn at image (1017, 339) (`09-camdefaults.png`).
3. `click-img 09-camdefaults.png 1017 339` → the switch flips and two new panels appear
   ("Cooling set-point", "Start cooling when the camera connects"), so the control works — it just
   never announces itself.
4. Contrast step 2 "Which drivers should we scan?", where the same wizard exposes
   `check box: Native… [ON]` / `check box: Sim… [off]` correctly.

Expected: role=switch/checkbox with label and checked state, as the drivers step already does.
Actual: a screen-reader or keyboard user gets a label with no control. A first-run wizard that cannot
be completed without a mouse is an accessibility failure on the very first screen of the product.

### SET-7 — Capture-folder step: two contradictory messages for one condition, and no way to create the folder you just typed (P3)

Screen: Onboarding step 10 of 13 "Where should we save captures?".

Repro:
1. Step 10 opens with an empty field (`Type or paste a folder, or use Browse`) — no suggested default
   such as `~/Pictures/Skotiq`, and ~450 px of empty card below it.
2. Type a path that does not exist (`/tmp/ns-audit/gui-settings-onboarding/captures` before it is
   created) and click **Next**.

Actual, simultaneously:
- inline under the field: `⚠ That folder does not exist.` (correct)
- a snackbar at the bottom-left of the window: `Pick a capture folder.` (untrue — a folder *is*
  entered; it merely does not exist yet)
There is no "Create it" affordance anywhere, so a user who wants a new folder must leave the wizard,
create it in a file manager, and come back. Evidence: `/tmp/ns-audit/shots-set3/10b-folder-error.png`,
`/tmp/ns-audit/shots-set3/10d-toast.png`.
(For the record, the same field correctly reports `Folder is writable.` once the directory exists,
and **Browse** does open a working GTK directory chooser.)

### SET-8 — The location-consent dialog is ~680 px tall for two short paragraphs, with the body floated in the middle of a sea of empty space (P2)

Screen: Onboarding step 11 of 13 → **Use my current location** → "Detect this site's location?" dialog.

Repro:
1. Step 11, click **Use my current location**.

Expected: a dialog sized to its content.
Actual: the dialog occupies the full window height (image y≈18 → y≈700 of a 720-px capture). The title
sits at the top, the two paragraphs of body text are vertically centred with roughly **230 px of empty
space above** and **225 px below** them, and the Cancel / Detect location buttons are pinned to the
bottom edge. Evidence: `/tmp/ns-audit/shots-set3/11b-consent.png`.

### SET-9 — After a successful location detection the card still says "No site on record yet", and the result is printed to 7 decimal places for a value the app calls "about 10 km" accurate (P2)

Screen: Onboarding step 11 of 13 "Where do you observe?".

Repro:
1. Click **Use my current location** → **Detect location**.
2. Detection succeeds — the app log shows
   `[API] api_set_location called with lat=39.9527237, lon=-75.1635262, elev=0` and the latitude and
   longitude fields fill in.

Expected: the informational banner becomes something like "Site set from IP estimate — accurate to
about 10 km", and the coordinates are rounded to the precision the estimate actually has.
Actual (both visible in `/tmp/ns-audit/shots-set3/11c-after-detect.png`):
- the banner immediately above the filled-in fields still reads **"No site on record yet.** Skotiq
  can ask a third-party service to estimate your position…", still offering **Estimate from IP** — the
  screen denies the thing it just did;
- the fields read `39.9527237` / `-75.1635262` — **7 decimal places, ~1 cm resolution**, on a value the
  app's own consent dialog describes as city-level, about 10 km. False precision invites the user to
  trust a number that is a guess.
  (The Review step then prints the same site as `39.9527°, -75.1635°` — 4 decimals — so the wizard
  disagrees with itself about how precise the number is.)

### SET-10 — The 13-step rail looks like navigation and is completely inert (P3)

Screen: onboarding, all steps — the left rail listing Welcome … What's next, with tick marks on
completed steps.

Repro:
1. Reach step 12 ("Review and save").
2. Click the rail entries **Optical train**, **Camera**, **Welcome** — each with `click-img` on the
   label itself (confirmed hits: root 526,497 / 512,327 / 460,258).

Expected: completed steps are reachable, the way every other multi-step wizard's rail behaves.
Actual: the step never changes; `tree` still reports `Step 12 of 13`. The rail draws state (blue
ticks, a highlighted current step, per-step icons and "optional" dashes) but has no behaviour, so a
user who spots a mistake on step 8 while reviewing must press **Back** four times. Nothing on screen
distinguishes this rail from a clickable one.

### SET-11 — Choosing a camera preset on step 9 silently rewrites a value the user typed on step 8 (P3)

Screen: Onboarding steps 8 and 9.

Repro:
1. Step 8 "Tell us about your optics": type `3.76` into **Camera pixel size** (whose placeholder,
   note, is the sentence "Not in the camera library — check your camera's datasheet").
2. Next → step 9 → **Choose from camera library** → search `294` → pick **ZWO ASI294MC Pro**
   (4.63 µm).
3. Press **Back** to step 8.

Expected: either the pixel size stays as typed, or the app tells you it replaced it
("Pixel size updated from the ZWO ASI294MC Pro preset").
Actual: the field now reads `4.63` with no message anywhere — the value the user typed two steps
earlier was overwritten silently, and the image scale on the review page (2.39 arcsec/px) is computed
from the replacement. The two screens also contradict each other about whether a pixel size can be
looked up at all: step 8's placeholder says it is not in the library, step 9's library supplies it.
Evidence: `/tmp/ns-audit/shots-set3/08e-pixelsize.png`.

### SET-12 — The 12-step Dashboard Tour narrates panels that are not on the dashboard, and its card floats with nothing highlighted (P2)

Screen: Dashboard → "Dashboard Tour" nudge → **Start Tour**.

Repro:
1. Finish onboarding. On the Dashboard, click **Start Tour** in the "Dashboard Tour" card.
2. Advance with the **Next** button, or with `Return` / `Right` / `space` (all work).
   Step titles, read from `tree` (`Tutorial step N of 12: …`):
   1 Welcome to Dashboard, 2 Customize Layout, 3 **Live Image Preview**, 4 **Quick Capture**,
   5 **Session Progress**, 6 **Weather Status**, 7 **Guiding Status**, 8 **Mount Position**,
   9 **Focuser Control**, 10 **Equipment Overview**, 11 **Active Sequence**.
3. Compare against the dashboard underneath (`/tmp/ns-audit/shots-set3/13-dashboard.png`): the default
   layout contains Tonight's Briefing, Tonight's Targets, Readiness, Moon and Last Run — **none** of
   the nine panels the tour describes from step 3 onward.

Actual at step 5 (`/tmp/ns-audit/shots-set3/14b-tour5.png`): the card sits in the middle of the screen
telling the user "Track your current imaging session: total frames captured, integration time
accumulated… Click to view detailed session statistics", with **no spotlight, no arrow and no
highlighted target** — there is nothing on screen it could point at. A guided tour of an interface the
user is not looking at is worse than no tour.

Secondary: the tour claims 12 steps but I could not reach step 12 — at "step 11 of 12" a further
`Right` did nothing and `Return` dismissed the tour outright, leaving the dashboard with no completion
message.

### SET-13 — Two first-run coach marks fight for the same corner of the Dashboard (P3)

Screen: Dashboard, immediately after onboarding.

Repro:
1. Finish onboarding.
2. Observe the bottom-right of the Dashboard.

Actual: a "Dashboard Tour" card (Maybe Later / Start Tour) and a "Build tonight's plan?" card
(Not now / Plan Tonight) are displayed **at the same time**, edge to edge, both asking for a decision,
and the plan card covers the "Last run" panel it is sitting on top of
(`/tmp/ns-audit/shots-set3/14-tour1.png`). Starting the tour does not dismiss or defer the other card —
it stays visible behind and beside the tour card for the whole tour
(`/tmp/ns-audit/shots-set3/14b-tour5.png`).

### SET-14 — The whole Settings screen stops ~120 px short of the window bottom, so its own nav list has to scroll (P3)

Screen: Settings (any leaf).

Repro:
1. Open Settings (gear, top right).
2. Look at the bottom edge of the settings nav card and the content card versus the window.

Actual: both the category rail and the content pane end at image y≈571 of a 720-px capture, while the
app's left nav rail continues to y≈665 and the status bar sits at y≈705 — a full-width dead band of
about 120 px below Settings. The category list is *scrollable*, and the wasted band is exactly the
space it needs: at the default size the list shows GENERAL…NOTIFICATIONS & REMOTE and hides
**ADVANCED** below the fold (it is in the tree, and reachable only by scrolling or by search).
Evidence: `/tmp/ns-audit/shots-set3/15-settings.png`, `/tmp/ns-audit/shots-set3/16-search.png`.

### SET-15 — Switching to Spanish leaves the Settings tour card half-English and the status bar ungrammatical (P3)

Screen: Settings → General → Language → Spanish (beta).

Repro:
1. Settings → General → Language → **Spanish (beta)**. The app translates live (nav, settings, status
   bar) — the feature works.
2. Look at the "Settings Tour" card in the bottom right and at the status bar.

Actual (`/tmp/ns-audit/shots-set3/15c-spanish.png`):
- the tour card's title and body translate ("Tour de ajustes / Aprende a configurar tus preferencias
  de Skotiq") but its two buttons stay **"Maybe Later"** and **"Start Tour"** — a card in two
  languages, inside the Settings surface the app explicitly promises is translated;
- the status bar reads `Cámara Desconectado`, `Montura Desconectado`, `Guía Desconectado` — all three
  need the feminine `Desconectada`;
- the category rail clips **"NOTIFICACIONES Y"** mid-glyph at the panel's bottom edge, because the
  longer Spanish labels overflow the fixed-height rail described in SET-14.

### SET-16 — Files & Storage: the editable path box is ~180 px wide and clips the path it holds, while the same path is printed in full two inches to the left (P3)

Screen: Settings → Files & Storage → Storage.

Repro:
1. Settings → Files & Storage.
2. Look at the **Image output** row.

Actual (`/tmp/ns-audit/shots-set3/20-files.png`): the row prints the full path as its subtitle
(`/tmp/ns-audit/gui-settings-onboarding/captures`) and then offers a **180 px** text field on the far
right that shows `/tmp/ns-audit/gui-settings-o` — clipped, without an ellipsis — in a pane 1120 px
wide with roughly 700 px of empty space between the two. The **Sequences** row beneath it says
"Not configured" as its subtitle *and* "Not set" as the field's placeholder, two labels for one state.
The two path rows in this card also use different affordances from the two in the card below it
(text field + folder icon vs. **Change…** + **Open folder** buttons), so one leaf ships two designs
for "change a folder".

### SET-17 — A brand-new install lists 13 already-paired remote devices, most of them allowed to control the rig (P1)

Screen: Settings → Remote Access → **Manage Pairing** → "Remote Connection Pairing" → Paired Devices.

Repro:
1. `start --fresh` (the harness `shutil.rmtree`s the entire profile directory, so this is a genuinely
   empty install — onboarding runs from step 1 and the equipment-profile table is empty).
2. Complete onboarding, Settings → Remote Access → toggle **Enable Remote Access** on →
   **Manage Pairing**.

Expected on a first run: "No paired devices yet".
Actual (`/tmp/ns-audit/shots-set3/26-pairdialog.png`): the Paired Devices list is populated —
- `Dashboard · Browser · Can control the rig · Paired: 6/15/2026 · No connection recorded yet`
- `Android companion · Android phone or tablet · Can control the rig · Paired: 7/20/2026`
- `Android companion · Android phone or tablet · Can control the rig` … and more below the fold.

Dates two months before this profile existed. The store the app reads, `<data dir>/pairing.db`, was
recreated during this run and holds **13** rows — the same count and contents as an out-of-profile
file (`~/Documents/Skotiq/pairing.db`, last written Aug 1) — including android tokens with
`control` scope and one with `admin`.

Why it is P1: the pairing list is the app's only view of "who may drive my telescope from the
network". A user who wipes or reinstalls Skotiq to revoke access does not revoke anything, and a
fresh install on a shared machine inherits someone else's authorised phones. The screen states these
devices as paired facts, which is the "app says something untrue" class at its most dangerous.
(Revocation itself works: the per-row ⋮ menu offers Rename Device / Revoke Access / Delete Device.)

### SET-18 — "Start Pairing Mode" promises a QR code *and a pairing phrase*, then shows only a QR — no phrase, no expiry, no way to stop, nothing for a screen reader (P2)

Screen: Settings → Remote Access → "Pair phones and tablets".

Repro:
1. Settings → Remote Access → enable **Enable Remote Access**.
2. Read the card: "Start pairing mode to show a QR code **and pairing phrase** on this screen."
3. Click **Start Pairing Mode**.

Expected: a QR *and* the promised phrase, an expiry countdown (the sibling browser flow shows
"Expires in 04:01"), and a way to leave pairing mode.
Actual (`/tmp/ns-audit/shots-set3/25c-pairmode2.png`): the card replaces its instruction line with a
QR image and nothing else — no phrase, no countdown, no Stop/Cancel, so the only way out is to
navigate away. The whole card reduces in `tree` to `panel: Pair phones and tablets` / its description
/ `text:  [DISABLED]` — **the QR is not exposed to accessibility at all**, so a blind user has no path
to pair a phone. The QR is also pushed hard right in a card with ~400 px of empty space to its left.

### SET-19 — Autofocus is still the one Settings leaf whose switches and fields have no accessible names at all (P2)

Screen: Settings → Equipment → Autofocus.

Repro:
1. Settings → search "Autofocus" → open the leaf.
2. `tree`.

Actual: every control comes back unlabelled — `toggle button:  [ON]`, `toggle button:  [off]`,
`text: ` ×15, and `button: Star HFR`, `button: Hyperbolic`, `button: Overshoot`,
`button: Park and end the sequence` with the label rendered separately as a sibling `panel:`. The
labels ("Use filter offsets", "Step size", "Backlash IN", "If focus is past tolerance"…) exist as
panels but are not attached to the controls.
Contrast Files & Storage in the same session, which correctly reports
`toggle button: Enable automatic backups … [ON]`. The design system has a labelled control; this leaf
does not use it, so a screen-reader user hears "toggle button, on" with no idea which setting it is.

### SET-20 — Cards inside Settings randomly shrink-wrap instead of filling the column (P3)

Screens: Settings → Dark Library ("Library Management"); Settings → Remote Access
("Pair phones and tablets").

Repro:
1. Settings → Dark Library → scroll to **Library Management**.
2. Settings → Remote Access → scroll to **Pair phones and tablets**.

Actual: in a content column ~1050 px wide where every other card is full width, the Library
Management card is **320 px** wide (`/tmp/ns-audit/shots-set3/23-darklib-mgmt.png`) and the Pair
phones card is **683 px** (`/tmp/ns-audit/shots-set3/25-pairing.png`) — both stopping in mid-air with
the rest of the row empty. Two unrelated leaves show it, so it is a shared-widget problem, not a
one-off.

### SET-21 — Help & Tutorials tracks five tutorials that are not the tours the app actually runs, and never records that you took one (P3)

Screen: Settings → General → Help & Tutorials.

Repro:
1. From the Dashboard, run the **Dashboard Tour** to its end.
2. Settings → **Help & Tutorials** → "Tutorial Tours".

Expected: the tour just completed is listed and marked complete.
Actual: the list contains five entries — Equipment Setup, Target Planning, Automated Imaging,
Calibration Frames, Advanced Features — every one "**Not started**", and the Dashboard Tour and
Settings Tour (both of which the app pushes as cards on first run) are not in the list at all. The
leaf also offers "Reset All Progress → Clear all tutorial progress and start fresh", i.e. a reset for
progress the app does not appear to record.

### SET-22 — A dependent setting stays live and editable while its parent switch is off (P3)

Screen: Settings → Files & Storage → Sequence Auto-Save.

Repro:
1. Settings → Files & Storage → scroll to **Sequence Auto-Save**.
2. With **Enable sequence auto-save** off (the shipped default), look at **Sequence save interval**.

Expected: the interval is hidden or disabled, the way onboarding step 9 hides "Cooling set-point"
until "Regulated cooling" is on.
Actual (`/tmp/ns-audit/shots-set3/20b-files-scrolled.png`): the interval renders in its normal enabled
style showing "2 min" and accepts edits that change nothing, directly under a switch that is off.
(For the record, once enabled both the switch and an edited interval of 7 min survive navigating to
another leaf and back — persistence itself is sound.)

### SET-23 — Equipment Profiles renders read-only values in boxes that are pixel-identical to the editable controls beside them (P2)

Screen: Settings → Equipment → Equipment Profiles → the profile detail pane.

Repro:
1. Settings → search "Equipment Profiles" → open it → select **Audit Rig**.
2. Look at "Optical Configuration" and "Camera Defaults".
3. Click the **Focal Length** box (image 450,183 of `/tmp/ns-audit/shots-set3/28-profiles2.png`,
   root 1090,413) and type `999`.

Expected: either the box is editable, or it does not look like a text input.
Actual: `400 mm`, `72 mm`, `f/5.6`, `120`, `30`, `-10°C` are drawn as filled, rounded, bordered input
boxes — and they are inert: the click produces no focus ring, the keystrokes are swallowed, `tree`
still reports `panel: 400 mm`. Directly beneath them, **Binning X / Binning Y** use the same visual
language and *are* interactive segmented controls, so within one card the identical chrome is half
live and half dead. The only way to change these values is the ⋮ menu / "Edit Profile" elsewhere on
the screen. Evidence: `/tmp/ns-audit/shots-set3/28-profiles2.png`.

(This screen is also the third confirmation of SET-2: the saved profile's Filter Configuration reads
`L R G B Ha OIII **Filter 7**`.)

### SET-24 — Integrations: every plugin row states its state three times, and the state chips do not line up (P4)

Screen: Settings → Notifications & Remote → Integrations.

Repro:
1. Settings → search "Integrations" → open it.

Actual (`/tmp/ns-audit/shots-set3/27-profiles.png`): each plugin row carries a green `● ✓ Enabled`
chip, a **Configure** button and a blue ON switch — the chip and the switch are the same fact twice.
The fourth row (**Weather Logger**) has no Configure button, so its chip is laid out from the
Configure column instead of the chip column: the first three chips sit at x≈823-918 and the fourth at
x≈923-1020, a visible 100 px step in what should be a straight column.

### SET-25 — The meridian-flip minutes field carries two overlapping help texts, one of them a sentence fragment (P3)

Screen: Settings → Automation & Safety → Sequencer → Meridian Flip.

Repro:
1. Settings → search "Sequencer" → open the leaf → Meridian Flip section.
2. `tree` on **Minutes past meridian`.

Actual: the field reports both
`Flip past meridian. How many minutes past the meridian the mount keeps tracking before performing a
meridian flip. Set it just under your mount's safe tracking limit so it images as long as possible
without the optics striking the pier.` **and** `Flip after target crosses meridian by this amount` —
two descriptions of the same control, the first beginning with the bare fragment "Flip past
meridian." No other field in the leaf carries two.

### SET-26 — First-run driver copy: one option's description is not a sentence, and the four descriptions punctuate inconsistently (P4)

Screen: Onboarding step 2 of 13 "Which drivers should we scan?".

Repro: read the four rows (`/tmp/ns-audit/shots-set3/02-drivers.png`).

Actual:
- `Sim — Simulated device where that workflow is enabled for testing` — not a grammatical sentence,
  and "that workflow" refers to nothing the reader has seen.
- `Native — Direct SDK connection where the release includes the required vendor library` — same
  "where" construction, describing a build property rather than telling the user what to pick.
- Native and Sim end without a full stop; Alpaca and INDI end with one. Four adjacent rows, two
  punctuation styles.

### SET-27 — The status bar shows four devices but the profile chip counts five, so its "1/5" cannot be reconciled from the same bar (P4)

Screen: status bar (all screens).

Repro:
1. After onboarding with camera, mount, focuser, filter wheel and guider selected, read the status bar.

Actual: the bar shows `🔭 Audit Rig 1/5` followed by `Camera Disconnected`, `Mount Disconnected`,
`Guider Disconnected`, `Focus ---` — four devices, all disconnected, next to a chip claiming one of
five is connected. The fifth device (the filter wheel, which auto-connect did bring up — the Equipment
screen confirms "1 connected") is never shown in the bar, so from the status bar alone the count reads
as a contradiction. The chip is also `[DISABLED]` and exposes only the string `1/5` to accessibility,
with no legend anywhere for what the ratio counts.

### SET-28 — The Notifications leaf ships three overlapping notification systems at once, one of which it calls "legacy", with three near-identically named controls for the same event (P2)

Screen: Settings → Notifications & Remote → Notifications.

Repro:
1. Settings → search "Notifications" → open the leaf and read it top to bottom.

Actual — for "a sequence finished" alone, the leaf offers three separate controls:
- **Notification Events → "Sequence complete"** — "Notify when sequence finishes" `[ON]`
- **Push to Mobile → "Sequence completed"** — "Push when sequence finishes" `[ON]`
- **Per-event routing → "Sequence Completed"** — "→ In-app banner + Mobile push", with an **Edit**
  button

and the master switch above the third reads "Notification routing enabled — **When off, no per-category
routing fires (legacy push still works)** `[ON]`", i.e. the leaf itself admits two of these are
different generations of the same feature. There is nothing to tell the user which one wins, or what
happens when "Sequence complete" is on and the routing entry says in-app only.

Two secondary observations in the same leaf:
- "Push critical alerts to mobile" is `[ON]` while its own description says "No device has registered
  for push, and this host has no push delivery configured" — the honest disclosure is welcome, but the
  switch still reads as armed protection for an unattended night.
- Of the eight per-event push toggles, **"Equipment disconnected" is the only one shipped off** — the
  one event most likely to end an unattended session silently.

### SET-29 — The file-naming-pattern field is ~210 px wide and clips its own value mid-token (P3)

Screen: Settings → Imaging → File Format → File naming pattern.

Repro:
1. Settings → search "naming" → open the Imaging leaf.

Actual (`/tmp/ns-audit/shots-set3/29-naming.png`): the stored pattern is
`$TARGET_$FILTER_$DATE_$SEQ` (confirmed in `app_settings.file_naming_pattern`), and the editor shows
`$TARGET_$FILTER_$DATE_$SE` — cut mid-variable with no ellipsis — in a pane 1120 px wide with roughly
750 px of empty space to its left. Identical in shape to SET-16, so both are the same
narrow-value-editor pattern rather than two separate mistakes.


---

## Coverage

Driven live on this build (Xvfb :84, profile `gui-settings-onboarding`, bundle `libapp.so` dated
2026-08-11 09:55; the bundle's `libskotiq_bridge.so` was missing when this pass started and had to
be restored before the app would boot — see "Blocked" below).

**Onboarding — all 13 steps walked, forwards and backwards:**
1 Welcome · 2 Drivers · 3 Camera · 4 Mount · 5 Focuser · 6 Filter wheel · 7 Guider ·
8 Optical train (incl. telescope library dialog + invalid-input validation) · 9 Camera defaults (incl.
camera library dialog, search, three different presets) · 10 Capture folder (incl. GTK Browse dialog
and the invalid-path error path) · 11 Observing site (incl. the consent dialog and a real IP-based
detection) · 12 Review & save (incl. empty-name validation and a triple-click on Save, which correctly
produced exactly one profile in the database).
Step 13 "What's next" was skipped past by the extra Save clicks and is listed as blocked below.

**Tutorial:** Dashboard Tour steps 1-11 of a claimed 12, by button and by keyboard; the "Settings
Tour" nudge was observed on every Settings leaf; Settings → Help & Tutorials inventoried (4 guided
flows, 5 tutorial tours, Reset All Progress, Enable tutorials).

**Settings leaves opened and read (17):** General · Appearance (theme changed to Red night and back,
accent changed to Amber and back) · Location (values from onboarding verified, DMS entry accepted and
parsed to 44.058055…) · Files & Storage (toggle + interval changed and verified to persist across
navigation) · Backup & Restore · Help & Tutorials · About · Connection · Equipment Profiles ·
Autofocus · Plate Solving · Dark Library (incl. the Clear Library confirmation dialog) · Imaging ·
Sequencer · Weather Safety · Science · Notifications · Integrations · Remote Access.
Settings search was used as the primary navigation and works, including deep links to individual
controls.

**Pairing:** Remote Access enabled (verified the server really binds — `0.0.0.0:8080` LISTEN by the
app's pid), local + LAN dashboard links, "Start Pairing Mode" QR, "Manage Pairing" →
Remote Connection Pairing (pairing code `NOVA-NEBULA-2638`, "Expires in 04:01" countdown, Cancel
Pairing, Paired Devices list, per-device ⋮ → Rename / Revoke / Delete).

## Blocked / not covered

| Screen | Why |
| --- | --- |
| Onboarding step 13 "What's next" | Clicking **Save profile** three times in a row (a deliberate rapid-click test) advanced through step 13 to the Dashboard before it could be read. Reaching it again needs another `--fresh` run; the re-entry path (Settings → Help & Tutorials → "Re-run equipment setup") restarts at step 1. |
| Tutorial step 12 of 12 | The tour ended at step 11 (see SET-12); step 12 was never displayed. |
| Settings → Equipment → PHD2 Guiding, Calibration; Advanced category leaves | Reached only through the search index, whose top result took me to a neighbouring leaf; not opened and read in full within this pass. |
| File-naming-pattern editing | The click into the ~210 px field did not take focus (the stored value was unchanged afterwards), so the previous pass's claim about undocumented `$` variables is **not** re-verified here — only the clipping (SET-29) is. |
| Anything requiring connected hardware | Only the filter wheel auto-connected (Equipment reports "1 connected"); camera/mount/focuser/guider stayed disconnected, so settings whose effect is only visible during capture were not exercised. |

## Note on the previous pass

The 2026-08-11 report for this cluster (SET-1…SET-21 in that file) was written against the same
`libapp.so`. Several of its findings were re-observed live today and are re-reported above with fresh
evidence: the PHD2 success/failure contradiction (now SET-3), "Add slot" doing nothing (SET-2), the
invisible wizard switches (SET-6), the oversized location dialog (SET-8), "No site on record yet"
after a successful detect (SET-9), the fake-editable profile boxes (SET-23), the unlabelled Autofocus
controls (SET-19) and the clipped naming-pattern field (SET-29). None of them had been fixed in the
binary under test.
