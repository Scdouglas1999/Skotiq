# GUI release pass — cluster: Mosaic / Collaborative Sky / Transients / Suggestions / Catalogs

Driven live on `NS_AUDIT_DISPLAY=:87`, profile `gui-collab-catalogs`, fresh scratch profile
(`/tmp/ns-audit/gui-collab-catalogs`), release desktop bundle. Site set to 40.02, -105.27,
optics 530 mm / 80 mm / 3.76 um, simulator camera + mount + focuser + filter wheel selected in
onboarding. All findings below were observed in the running app.

Findings are numbered COL-n. Screenshots cited live in `/tmp/ns-audit/shots-collab/`.

A real Constellation hub was stood up locally to review the connected state of Collaborative Sky
(`server/skotiq_hub`, `dart run bin/server.dart --db /tmp/ns-audit/hub/hub.db --atlas-root
/tmp/ns-audit/hub/atlas --port 8088`), so the connected paths below are not speculation.

---

## COL-1 — "Enable sharing" silently does nothing unless a second checkbox is ticked (P2)

Screen: Plan Tonight -> Discover -> Collaborate -> a live co-imaging session card -> "Turn on sharing".

Repro:
1. Connect to a hub, start a co-imaging session (any target).
2. The card reads "Joined - not contributing (sharing off)". Click "Turn on sharing".
3. In "Share your co-imaging subs", tick only the last box ("I understand this shares my completed
   subs ... and consent"). Leave "Let this rig contribute my completed subs unattended" unticked.
4. "Enable sharing" lights up as enabled. Click it.

Expected: either sharing turns on, or the dialog explains what else is required.
Actual: the sheet closes as if it succeeded and the card still reads "Joined - not contributing
(sharing off)" with the "Turn on sharing" button still present. No toast, no inline error, nothing
in the log. Only after re-opening the sheet and additionally ticking the *unattended* box does the
card flip to "You are pooling light here". A user who ticks the consent box, presses the primary
action and sees the dialog close will believe their subs are pooling into the shared stack all
night; they are not.
Evidence: `/tmp/ns-audit/shots-collab/26-consent.png`, `28-session-card.png` (after "Enable
sharing"), `29-consent3.png`, `31-collab-tall.png` (after ticking both).

## COL-2 — "Open calibration library" from the Shared calibration card lands on the local, hub-less page (P2)

Screen: Plan Tonight -> Discover -> Collaborate -> "Shared calibration" section.

Repro:
1. Connect to a hub. Scroll to "Shared calibration": "Shared calibration library - Never shoot the
   same dark twice - pull a sensor-matched master a member already shot", with YOU SHARED 0 /
   YOU PULLED 0 and a button "Open calibration library".
2. Click "Open calibration library".

Expected: the shared/hub library, where a member's masters can be browsed and pulled.
Actual: it navigates to Settings -> Imaging -> Calibration Library, the purely *local* master list
("No calibration masters yet. Stacked darks, flats, and defect maps appear here automatically"),
whose accessibility tree contains no occurrence of hub / shared / pull / member. The advertised
"pull a master a member already shot" workflow has no reachable UI; the only button that promises it
leads somewhere it does not exist.
Evidence: `/tmp/ns-audit/shots-collab/33-tabfocus.png` (card), `34-calib-settings.png` (destination).

## COL-3 — Co-imaging consent sheet reports inverted states to assistive tech (P3)

Screen: "Share your co-imaging subs" sheet (see COL-1 step 2).

Repro: open the sheet and run `drive_linux.py tree`.
Expected: the three checkboxes and the licence dropdown report as enabled checkables; the primary
button reports `[DISABLED]` while it is greyed out.
Actual: exactly inverted. `check box`-style rows and the licence button all carry `[DISABLED]`
("CC BY - credit required, any use [DISABLED]", "Credit me as a contributor... [DISABLED]", …),
while `button: Enable sharing` carries no disabled state at all even in the greyed-out state that
ignores clicks (COL-1 step 4 shows it ignoring a click). A screen-reader user is told the controls
they must operate are dead and the dead control is live.

## COL-4 — Consent sheet copy says "mosaic" inside a co-imaging session (P3)

Screen: "Share your co-imaging subs" sheet, reached from a *co-imaging* session card.
Actual copy: "Credit me as a contributor. Uncheck to be listed as an \"Anonymous contributor\" on
the finished mosaic." There is no mosaic in this flow - the sheet is shared with the mosaic
contribute path and was not re-worded for co-imaging. The sheet's own title says "co-imaging subs"
two lines above.
Evidence: `/tmp/ns-audit/shots-collab/26-consent.png`.

## COL-5 — "From mount" in the co-imaging sheet is a silent no-op when no mount is connected (P3)

Screen: Collaborate -> "Start session" -> "From mount".

Repro: with no mount connected (fresh profile, devices never connected), click "From mount".
Expected: a message such as "Connect a mount to use its position", or a visibly disabled control.
Actual: nothing happens - no snackbar, no inline error, no log line, and the RA/Dec fields stay
empty. The explanation exists *only* as a hover tooltip ("Connect a mount to use its position",
visible in `25-filled.png`), which a click-first user never sees, and the accessibility tree reports
`button: From mount` with no disabled state. The neighbouring "Look up coordinates" button is styled
almost identically and does work, so the pair reads as one working and one broken button.
Evidence: `/tmp/ns-audit/shots-collab/22-coimg-sheet.png`, `23-frommount.png`, `25-filled.png`.

## COL-6 — Hub sign-in shows a stale validation error after the field is corrected (P4)

Screen: Collaborate -> "Connect to a hub".

Repro: press Connect with the address empty -> "Enter a valid hub address (including http://)."
appears. Now type a valid address (e.g. `http://127.0.0.1:8088`).
Expected: the error clears as soon as the input becomes valid (or at least on the next edit).
Actual: the red error row stays on screen contradicting the field beside it until Connect is pressed
again. Because the error row also grows the dialog, the fields shift up by ~12 px the moment it
appears, which moves controls under a user's cursor mid-interaction.
Evidence: `/tmp/ns-audit/shots-collab/18-hub-filled.png`.

## COL-7 — Publishing a mosaic that straddles RA 0h sends a centre 144 degrees away from the truth (P1)

Screen: mosaic project (`/mosaic/:id`) -> "Publish to hub"; result visible on Plan Tonight ->
Discover -> Collaborate -> "Collaborative mosaics".

Repro:
1. Analytics -> Projects -> "Mosaic projects" -> "New mosaic". Leave the default centre (the wizard
   opens at RA 0.000h Dec 0.00 with no target prompt). Set Columns 5, Rows 3. "Create mosaic project".
2. The project screen shows "Mosaic 0.00h 0.0deg", "5 wide x 3 high - 15 panels - 00:00:00.00
   +00:00:00.00".
3. Click "Publish to hub", then open Collaborate.

Expected: the hub card shows the same centre, RA 0h.
Actual: the card reads "Mosaic 0.00h 0.0deg / 5 wide x 3 high - 9h 36m - +0deg 00'" - the title says
0.00h and the subtitle says 9h 36m for the same mosaic. The hub database confirms the app *sent* the
wrong value: `collaborative_mosaics.center_ra_deg = 144.0` while its own panels are stored at RA
358.595, 359.298, 0.0, 0.702, 1.405. 144.0 is exactly the arithmetic mean of those five panel RAs -
the publish path averages right ascension without wrap-around, so every mosaic crossing RA 0h is
published at a centre ~9.6 h away. Other club members browsing the hub see it in the wrong part of
the sky, and anything that filters or slews by the published centre is wrong.
Evidence: `/tmp/ns-audit/shots-collab/54-mosaic-project.png`; hub row via
`sqlite3 /tmp/ns-audit/hub/hub.db "select name,center_ra_deg from collaborative_mosaics;"`.

## COL-8 — "Publish to hub" leaves the Collaborative-mosaic section blank; no success state at all (P2)

Screen: mosaic project (`/mosaic/:id`), "Collaborative mosaic" section.

Repro: click "Publish to hub" on a project connected to a hub.
Expected: a published state - "Published to <hub>", a link to the hub listing, panel-claim status, an
unpublish/withdraw control.
Actual: the button and its explanatory line disappear and *nothing* replaces them. The section
renders as a heading + subtitle ("Collaborative mosaic" / "Split the panels across your club and fuse
centrally") with an empty body, indefinitely (still empty 6 s later, and after re-entering the
screen). The publish actually succeeded - it is visible under Collaborate -> Collaborative mosaics -
but nothing on the originating screen says so, and there is no way back to the hub listing or any way
to unpublish.
Evidence: accessibility tree before/after in the transcript; hub listing shows the mosaic as
"Open for panels - 0 of 15 panels - AuditRig".

## COL-9 — The mosaic wizard preview draws fewer panels than the plan it is previewing (P2)

Screen: Mosaic Wizard (Analytics -> Projects -> Mosaic projects -> New mosaic).

Repro:
1. Open the wizard. Default grid is 3 columns x 3 rows; the summary says "Active panels: 9,
   Grid: 3x3".
2. Look at the sky preview.

Expected: nine numbered cells centred on the centre marker.
Actual: only six cells are drawn - two columns wide (labels 8,9 / 5,6 / 2,3); panels 1, 4 and 7 are
missing, and the drawn block sits to the *right* of the centre marker instead of around it. Raise
Columns to 5 (summary "Active panels: 15, Grid: 5x3") and the preview draws nine cells - three
columns (13,14,15 / 8,9,10 / 3,4,5) - so panels 1,2,6,7,11,12 are missing. The preview is the only
tool for aiming a mosaic ("Drag centre"), so what the user frames is not what the plan contains.
Evidence: `/tmp/ns-audit/shots-collab/50-mosaic-wizard.png`, `51-grid-zoom.png` (3x3),
`53-grid5-wide.png` (5x3, full width of the preview so nothing is cropped).

## COL-10 — Catalog "package" download changes only the labels, and silently downgrades plate-solving depth (P2)

Screen: Settings -> Imaging -> Catalogs.

Repro:
1. On a fresh install the cards read: HYG Star Database - Objects 119.6k, Size 32.4 MB, Version 4.2,
   Package **Complete**, Depth **mag <= 9.0**; OpenNGC - 14.0k, 3.7 MB, Package Complete,
   Depth mag <= 20.0.
2. Scroll to "Download Catalogs". The preselected tier is **Standard** (~30 MB, "Stars: mag <= 8.0 -
   DSOs: mag <= 12.0") - i.e. shallower than what is installed, with nothing on the page marking the
   installed tier or warning that this is a downgrade.
3. Click "Download Selected Package". It starts immediately, with no confirmation.

Expected: either the installed tier is preselected, or the app warns that Standard is shallower than
the Complete catalogs already installed (the HYG card itself says "Required for plate solving").
Actual: the download runs and the cards become HYG - Objects **119.6k**, Size **32.4 MB**, Version
4.4, Package **Standard**, Depth **mag <= 8.0**; OpenNGC - **14.0k**, **3.7 MB**, Package Standard,
Depth **mag <= 12.0**. The object counts and file sizes are byte-identical to the "Complete"
catalogs, so either the depth labels are fiction or the numbers are stale - one of the two facts on
screen is false either way - while the user has been told their plate-solving catalogue is now two
magnitudes shallower.
Evidence: `/tmp/ns-audit/shots-collab/35-catalogs.png` (before), `44-catalogs-after.png` (after).

## COL-11 — A catalog shows "Update available" immediately after being downloaded, with no way to take it (P3)

Screen: Settings -> Imaging -> Catalogs.

Repro: download any package (COL-10) and look at the HYG card; then press Actions -> "Refresh Status".
Expected: no update badge on a catalogue installed seconds ago, or a control to install the update.
Actual: HYG shows an orange "Update available" badge next to "Installed", version 4.4, installed
today - and the badge survives "Refresh Status". The card offers no "Update" action, so the badge is
both unexplained and unactionable.
Evidence: `/tmp/ns-audit/shots-collab/44-catalogs-after.png`.

## COL-12 — "Delete Catalogs" confirmation understates what it destroys (P2)

Screen: Settings -> Imaging -> Catalogs -> Actions -> "Delete Catalogs".
Actual copy: "Are you sure you want to delete the downloaded star and deep-sky catalogs? You will
need to download them again to use the affected **planetarium features**." The HYG card three
sections above says "Required for **plate solving**; draws the star field in the planetarium and
finder", and OpenNGC says it "Powers deep-sky target search, framing, and on-image NGC/IC labels".
The confirmation names the least important consequence and omits that plate solving, target search
and framing stop working - a user deletes to reclaim 36 MB and finds centring broken that night.
The dialog is also a plain flat AlertDialog, unlike every other dialog in this area (Connect to a
hub, Start co-imaging session, Transient Alert Settings all use the icon-header glass style).
Evidence: `/tmp/ns-audit/shots-collab/46-delete-confirm.png`.

## COL-13 — Deep-Star tier ships developer instructions as its user-facing copy (P3)

Screen: Settings -> Imaging -> Catalogs -> "Deep-Star Tier (Tycho-2 / Gaia)".
Actual copy: "Streams faint stars below the bundled HYG floor (mag 9.0) as view-culled tiles when
zoomed in. **No tileset is published yet: host one built with tools/catalog_prep and point the URL
below at it.**", with a "Tileset base URL" field repeating "point this at a tileset you host yourself
(see tools/catalog_prep in the Skotiq repository)". A paying user is told to build and host their
own tileset from a repo directory; the section is a shipped feature with no data behind it.
Evidence: accessibility tree of the Catalogs page; `/tmp/ns-audit/shots-collab/45-actions.png`.
