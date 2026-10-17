# Cross-screen design-language audit (cluster: consistency)

Driven live against the release bundle on `NS_AUDIT_DISPLAY=:88`, profile `gui-consistency`,
fresh scratch profile (first-run onboarding). Read-only review; no app code was changed.

Harness note for whoever re-drives this: `drive_linux.py` accepts `--profile` on both sides of the
subcommand, but the subparser's default wins, so `--profile X start` silently runs as profile
`main`. Put the flag **after** the subcommand (`start --profile X`) or agents collide on one
scratch profile and one pid file.

## Summary

43 findings. The app's screens are individually well made; what this cluster found is that they
were not made to one specification. The recurring shapes are:

1. **The app states its own state in several voices at once.** A dialog titled "Ready to image"
   opens with a red "Not ready" alert (CON-20); an empty sequence is told both that it cannot run
   and that it will run (CON-27); a red "Weather Critical" alarm fires because weather monitoring
   is switched off (CON-30); a blocking banner keeps asking for a capture folder after one is
   entered (CON-10).
2. **Vocabulary drift.** The focuser is "Focuser", "Focus" and "sim_focuser_1"; one number is
   "Effective focal length", "Focal length" and "Telescope" on three consecutive screens; the
   simulator is "Sim", "Simulator" and "Simulated"; seconds are "s" and "sec"; the same idle device
   is "Idle", "Parked" and "Ready"; dismissal is "Maybe Later" and "Not now".
3. **No single design token for "nothing".** `---`, `--`, `- - -`, an em dash, "-- not set --",
   "No data" and "No Image" are all in use (CON-26, CON-35).
4. **Capitalisation has no rule.** "Image tonight" and "Plan Tonight" sit next to each other in one
   card (CON-16); card titles mix caps and sentence case in one column (CON-41).
5. **Accessibility stops at the shell.** The primary navigation is neither in the accessibility
   tree nor reachable by Tab (CON-14); text fields announce their placeholder or nothing at all
   (CON-5); open dropdowns expose no options (CON-39).
6. **Layout clips content while leaving the page empty below it** (CON-34, CON-23, CON-28).

Severity: 7 x P2, 26 x P3, 10 x P4. No P0/P1 was found in this cluster - nothing here loses a
night on its own; the accumulation is what makes the product read as assembled rather than
designed.

Things deliberately **not** claimed, having been checked and found fine: the Light theme is applied
consistently (title bar, nav rail and status bar all repaint - measured, not eyeballed); Escape
closes dialogs; Tab traversal inside the onboarding form is in visual order and wraps correctly;
rapid clicking through all seven nav destinations left the app rendering correctly; the free-storage
numbers are accurate for the scratch volume; per-item singular/plural copy ("Guider. It will be
unavailable") is handled. The app log contains no exceptions - but note this is a release build, in
which Flutter does not report RenderFlex overflows, so a clean log is not evidence of clean layout.

## Findings

### CON-1 (P2) - Onboarding discovery shows red "failed" chips with no reason, no detail, no recovery
Screen: first-run onboarding, step 3 "Pick your camera" (same chip row repeats on Mount/Focuser/
Filter wheel/Guider steps).
Repro: `start --fresh` -> Next -> on "Which drivers should we scan?" tick **Sim** -> Next.
The protocol chip row renders `Native (0)` and `Sim (1)` in green with a check icon, and
**`Alpaca` and `INDI` in red with a warning triangle**.
Expected: a failed scan states what failed and what to do ("No Alpaca server found on this
network - check the address in Settings > Drivers"), or is at least clickable for detail.
Actual: the red chips carry no count, no message, no tooltip; clicking one
(`click-img 05-camera.png 543 180`) does nothing and no text appears anywhere on the card. The
a11y tree exposes them as inert `panel:` nodes. A first-run user's very first impression is two
red error badges with zero explanation.
Evidence: /tmp/ns-audit/shots/cons/05-camera.png

### CON-2 (P3) - Disabled buttons are styled disabled but not exposed as disabled to a11y
Screen: onboarding footer (step 1), and the pattern is the shared button component.
Repro: `start --fresh`; on step 1 of 13 the footer "Back" button is rendered dimmed
(/tmp/ns-audit/shots/cons/03-back-step1.png) versus the bright "Back" on step 2
(/tmp/ns-audit/shots/cons/02-footer-step2.png), and clicking it does nothing.
Expected: `tree` reports `button: Back [DISABLED]` (the harness prints `[DISABLED]` when the
semantics say so, and does print state flags such as `[ON]`/`[off]` for this app's checkboxes).
Actual: `tree` prints a plain `button: Back` on step 1, identical to the live one on step 2, so a
screen-reader user is told the control is actionable when it is inert.

### CON-3 (P4) - Terminal punctuation and voice are inconsistent inside a single list
Screen: onboarding step 2 "Which drivers should we scan?".
Repro: read the four driver rows.
- "Direct SDK connection where the release includes the required vendor library"  (no period)
- "ASCOM Alpaca over network. Device capabilities are reported by the Alpaca server."  (period)
- "INDI protocol through a reachable INDI server. Feature support depends on the driver."  (period)
- "Simulated device where that workflow is enabled for testing"  (no period)
Two of four sentences also misuse "where" for "when/if", so the two shortest rows read as
sentence fragments. Expected: one punctuation and voice convention per list.
Evidence: /tmp/ns-audit/shots/cons/04-drivers.png

### CON-4 (P4) - Driver is called "Sim" in onboarding and "Simulator" elsewhere
Screen: onboarding step 2 checkbox label "Sim"; the same protocol is labelled "Sim" on the chip
row and the device subtitle, while the device itself is "Simulated Camera" and the Equipment
screen calls the family "Simulator". Three names for one concept in the first two minutes of use.
Evidence: /tmp/ns-audit/shots/cons/04-drivers.png, /tmp/ns-audit/shots/cons/05-camera.png

### CON-5 (P3) - Text fields announce their placeholder instead of their label, and one announces nothing
Screen: onboarding step 8 "Tell us about your optics" (four fields).
Repro: reach step 8, then Tab through the form and read the focused node.
Traversal order is correct (Skip onboarding -> Choose from telescope library -> focal length ->
aperture -> reducer -> pixel size -> Back -> Next -> wraps), but the accessible names are:
`text: e.g. 500, 1000, 2000`, `text: e.g. 80, 102, 200`, `text: (no name)`,
`text: Not in the camera library - check your camera's datasheet`.
Expected: each field announces its visible label ("Telescope focal length", "Aperture",
"Reducer / Barlow factor", "Camera pixel size").
Actual: three announce the placeholder (so once you type a value the announcement is stale/wrong)
and the **Reducer / Barlow factor field, which is the one field that ships with a value (1.00),
has no accessible name at all** - a screen-reader user tabbing into it is told nothing.
Second instance, same build: onboarding step 12 "Review and save" renders a "Profile name" field
containing the visible text "My First Rig", and `tree --all` exposes it as a bare `text: ` with an
empty name - neither the label nor the value reaches assistive tech. The rule appears to be: a
text field announces its placeholder if it is empty and nothing at all once it holds a value.

### CON-6 (P3) - Multiplication sign is "x" in the field suffix and "x" (proper multiplication sign) in the copy directly below it
Screen: onboarding step 8, "Reducer / Barlow factor".
Repro: look at the field: the in-field suffix is a lowercase ASCII letter `x` set in the same
weight as the value "1.00", so it reads as a stray character or a clear button. The helper text on
the same control uses the proper sign: "1.0 = no reducer, 0.79 = a 0.79x reducer, 2.0 = a 2x
Barlow" (both rendered with U+00D7 in the app). The neighbouring fields use real units in the same
suffix slot (`mm`, `mm`, `um`), so this one slot is the only non-unit glyph.
Evidence: /tmp/ns-audit/shots/cons/06-optics.png (suffix at image 1022,326)

### CON-7 (P3) - Telescope library prints raw enum values as user-facing optical types
Screen: onboarding step 8 -> "Choose from telescope library" dialog.
Repro: open the dialog and read the subtitles.
Actual: "203mm ritchey-chretien", "203mm schmidt-cassegrain", "200mm newtonian reflector",
"51mm corrected lens / astrograph". These are proper nouns rendered in lower case, i.e. the enum
name with underscores swapped for spaces, in a paid product's device library.
Expected: "Ritchey-Chretien", "Schmidt-Cassegrain", "Newtonian reflector".
Evidence: /tmp/ns-audit/shots/cons/07-telescope-lib.png plus the `tree` dump of the dialog.

### CON-8 (P3) - The onboarding switch has no accessible name, unlike the identical switches in Settings
Screen: onboarding step 9 "Set your capture defaults" (the "Regulated cooling" switch).
Repro: reach step 9, run `tree --all`. The switch is exposed as:
`toggle button:  [off]` - role and state are correct, **name is empty**.
Compare Settings -> General, where the same component is exposed correctly:
`toggle button: Start minimized / Launch app minimized to system tray [off]` and
`toggle button: Confirm before closing / Show confirmation when closing during capture [ON]`.
So the pattern exists and works; the onboarding instance simply never got a label, and a
screen-reader user there hears "toggle button, off" with no idea what it controls. (Settings ->
Appearance -> "Sidebar collapsed by default" is likewise named, confirming this is a miss rather
than a platform limitation.)

### CON-9 (P4) - One row in a form uses inline help while every sibling hides help behind a "?" icon
Screen: onboarding step 9 "Set your capture defaults".
Repro: compare rows. Gain / Offset / Bin X / Bin Y each render a bright label plus a small "?"
info icon and no inline description. "Regulated cooling" renders a dimmer, lower-contrast label,
**no "?" icon**, and its description inline underneath ("Turn on for a cooled camera; leave off
for a DSLR or an uncooled sensor."). Three inconsistencies in one row: label contrast, help
affordance, and help placement.
Evidence: /tmp/ns-audit/shots/cons/08-camdefaults.png

### CON-10 (P4) - Blocking banner contradicts the field it is about
Screen: onboarding step 10 "Where should we save captures?".
Repro: with the folder field empty press "Next" -> an amber banner appears above the footer,
"Pick a capture folder." Now type any non-existent path (e.g. `/tmp/ns-audit/x/captures`).
Expected: the banner updates to the real problem or disappears, since a folder IS now entered.
Actual: the banner keeps saying "Pick a capture folder." while the field says "That folder does
not exist." - two different explanations of one failure, one of them wrong. It only clears once
validation passes. Also note validation is blur-only: while you are typing a *valid* path the
field keeps showing red "That folder does not exist." and only flips to green "Folder is
writable." after focus leaves.
Evidence: /tmp/ns-audit/shots/cons/11-two-errors.png, 12-folder-ok.png, 13-folder-blur.png

### CON-11 (P3) - One value in a four-row summary table is set at a different type size
Screen: onboarding step 13 "You're all set" summary card.
Repro: finish onboarding and look at the four-row key/value block.
Actual: "1000 mm", "Simulated Camera" and "40.7100 deg, -74.0100 deg" are set in the bold value
style; **"0.78 arcsec/px" is visibly smaller and dimmer** than its three siblings in the same
column of the same table.
Evidence: /tmp/ns-audit/shots/cons/17-summary-type.png (crop of just that block)

### CON-12 (P3) - The same number is labelled three different ways on three consecutive screens
Screen: onboarding steps 8 -> 12 -> 13.
Repro: enter focal length 1000, aperture 200, pixel size 3.76, then step through.
- Step 8 computed values: "Effective focal length" = "1000.0 mm"
- Step 12 review: "Focal length" = "1000.0 mm x 1.00"
- Step 13 summary: "Telescope" = "1000 mm"
Three labels ("Effective focal length" / "Focal length" / "Telescope") and two precisions
("1000.0" / "1000") for one quantity, inside one wizard, in the space of three clicks. Step 13
also silently drops the reducer factor that step 12 considered important enough to show.

### CON-13 (P4) - Two labels for one action on the same screen, and a "Skip" affordance on the terminal step
Screen: onboarding step 13 "You're all set".
Repro: look at the footer and the "Where to next?" list.
- The footer secondary button is "Capture first light"; the first card in the list is
  "Capture your first light". Same destination, two names, ~300px apart.
- The header still offers "Skip onboarding" on step 13 of 13, after the profile has already been
  created and the success banner "Profile created. Welcome to Skotiq." is showing. There is
  nothing left to skip.
Evidence: /tmp/ns-audit/shots/cons/16-allset.png

### CON-14 (P2) - The primary navigation rail is invisible to accessibility and unreachable by keyboard
Screen: every screen (the app shell).
Repro: on the Dashboard, dismiss the coach marks, then run `tree --all` - 101 nodes, and
`grep -iE "equipment|sequencer|guiding|weather|analytics|collapse"` matches only the dashboard's
own "Connect equipment" button. The nine rail destinations (Dashboard, Equipment, Imaging,
Sequencer, Guiding, Weather, Plan Tonight, Analytics, Collapse) are **not in the tree at all**.
Then click on empty dashboard background and press Tab 14 times, reading the focused node each
time: focus visits Glance mode -> Edit Dashboard -> Image tonight -> Connect equipment -> Open
planner -> (unnamed button) -> Not now -> Plan Tonight -> the status-bar profile chip -> then five
consecutive unnamed panels. **The nav rail is never focused.**
Expected: the primary navigation is exposed as named buttons and reachable by Tab.
Actual: navigating this app requires a mouse; a screen reader is never told the destinations exist.
Same for the window-chrome buttons (notifications, account, settings, minimise/maximise/close),
which are also absent from the tree.

### CON-15 (P3) - Dashboard Tab order does not follow the visual layout and ends in dead stops
Screen: Dashboard.
Repro: as above, Tab 14 times from the dashboard background.
- "Plan Tonight" sits immediately to the right of "Image tonight" in the header, but is focus stop
  **8**, after "Connect equipment" and "Open planner" from cards far below it.
- Stop 6 is a `button` with **no accessible name** (the kebab "..." menu on the "Build tonight's
  plan?" nudge, /tmp/ns-audit/shots/cons/21-coachmark2.png).
- Stop 9 is the status-bar profile chip, which `tree` reports as
  `panel: ... My First Rig / 1/5 [DISABLED]` - it takes keyboard focus while advertising itself as
  disabled.
- Stops 10-14 all land on unnamed `panel` nodes with no visible focus ring, so a keyboard user
  presses Tab five times with no feedback about where they are.

### CON-16 (P3) - Button label capitalisation is inconsistent, including two buttons side by side
Screen: Dashboard (and the app generally).
Repro: look at the Dashboard header and cards.
Title Case: "Plan Tonight", "Edit Dashboard", "Start Tour", "Maybe Later", "Glance mode"(mixed).
Sentence case: "Image tonight", "Connect equipment", "Open planner", "Not now", "Scan again",
"Save profile", "Capture first light", "Skip this step".
The clearest instance: the header renders **"Image tonight" and "Plan Tonight" as adjacent
buttons**, one sentence case and one Title Case, in the same row of the same card.
Evidence: /tmp/ns-audit/shots/cons/18-dashboard.png

### CON-17 (P3) - Two dismissal nudges on one screen use different copy, casing and placement
Screen: Dashboard, first launch.
Repro: finish onboarding -> "Go to dashboard". A "Dashboard Tour" card appears bottom-right with
"Maybe Later" / "Start Tour". Dismiss it, and a second card, "Build tonight's plan?", takes its
place with "Not now" / "Plan Tonight" plus an unlabelled "..." kebab menu the first card did not
have. Two consecutive nudges in the same corner, with two different dismiss labels
("Maybe Later" vs "Not now"), two different capitalisation rules, and two different chrome.
Evidence: /tmp/ns-audit/shots/cons/18-dashboard.png, /tmp/ns-audit/shots/cons/21-coachmark2.png

### CON-18 (P3) - Status bar shows the same "Idle" chip twice and calls the focuser "Focus"
Screen: bottom status bar (present on every screen).
Repro: read the bar left to right:
`Idle | My First Rig 1/5 | Camera Disconnected | Mount Disconnected | Guider Disconnected |
Focus --- | Idle | ... | --- | gui-consistency | Dashboard | 10:14:06 | LST 06:38`
- "Idle" appears twice, ~500px apart, with no qualifier telling the two apart.
- The focuser is "Focus" here, "Focuser" in the Dashboard Readiness card, in the onboarding rail
  and in the profile review. Three of the four device chips use the noun ("Camera", "Mount",
  "Guider"); the fourth uses a verb.
- The temperature chip and the focuser value both render the empty token as `---`, while the
  onboarding review renders "not set" as an em-dash-wrapped phrase and the top status strip uses
  spaced `- - -`. At least three empty-value tokens are in play.
Evidence: /tmp/ns-audit/shots/cons/19-statusbar.png

### CON-19 (P4) - "15.2 GB / 15.2": the total in the storage readout has no unit
Screen: Dashboard -> Readiness card -> Free storage.
Repro: read the value. It renders `15.2 GB / 15.2`, putting the unit on the numerator and leaving
the denominator bare. (The numbers themselves are right - the scratch profile is on a 16 GB tmpfs
with 34 MB used.)
Evidence: /tmp/ns-audit/shots/cons/18-dashboard.png

### CON-20 (P2) - A dialog titled "Ready to image" opens with a red "Not ready" alert as its first line
Screen: Equipment -> STATUS panel.
Repro: Equipment screen -> right-hand STATUS panel -> click "View all (1 more)".
Actual: the dialog's title bar reads **"Ready to image"**; the first element in its body is a red
alert reading **"Not ready - 1 item is blocking first light and 3 items need attention. Resolve
the blocking items below."** The same words head the inline panel behind it, where the summary is
truncated to "1 item is blocking first light." (the "and 3 items need attention" half is dropped),
while the System Health chip in the same panel says "1 issue" and the list below it enumerates
four (Critical devices, Profile devices, Dark library, Focus).
Expected: one heading and one count per state - e.g. title "Readiness", state "Not ready", one
issue count used everywhere.
Actual: four different statements of the same state on one screen, the most prominent of which
("Ready to image", in the dialog title) is the opposite of the truth.
Evidence: /tmp/ns-audit/shots/cons/23-readiness-dialog.png, /tmp/ns-audit/shots/cons/22-equipment.png

### CON-21 (P3) - Two different dialog chrome patterns in the same build
Screen: onboarding "Telescope library" dialog vs Equipment "Ready to image" dialog.
Repro: open each.
- Telescope library: icon + title, header "x", **and** a footer action bar ("+ Add custom",
  "Close").
- Readiness: icon + title, header "x", **no footer at all**; the content list runs to the bottom
  edge of the panel with the last row's description clipped against it.
Expected: one dialog shell (same header, same footer rules, same content inset).
Evidence: /tmp/ns-audit/shots/cons/07-telescope-lib.png vs /tmp/ns-audit/shots/cons/23-readiness-dialog.png

### CON-22 (P3) - Device name truncates inside a card that is two-thirds empty
Screen: Equipment -> device card for the connected filter wheel.
Repro: connect nothing; the Simulated Filter Wheel auto-connects on profile activation. Its card
titles read "FILTER WHEEL" / "Simulated Filter ..." - the device name is ellipsised because the
"Connected" pill shares the row, while the card below has roughly 120px of unused vertical space
and the panel to its right is entirely empty.
Expected: the device name gets the space it needs before a status pill wins the row.
Evidence: /tmp/ns-audit/shots/cons/22-equipment.png (card at image 385,110-640,265)

### CON-23 (P2) - Button and tab labels are truncated on the Imaging screen with space to spare
Screen: Imaging.
Repro: Equipment -> "Connect All" (4/5 devices connect) -> Imaging. Dismiss the "Imaging Tour"
nudge so nothing overlaps.
- Session card: the two actions render as **"View Quic..."** and **"Clear Sess..."**
  (/tmp/ns-audit/shots/cons/27-session-card.png). The card is ~290px wide and the two buttons use
  ~250px of it; the labels are cut for want of a few pixels.
- Right-hand tab grid: the eighth tab renders **"Annotatio..."**
  (/tmp/ns-audit/shots/cons/28-imaging-tabs.png), while its seven siblings fit.
Expected: a primary action's label is readable.

### CON-24 (P2) - After connecting, the status bar swaps friendly device names for raw driver IDs
Screen: bottom status bar, after Equipment -> Connect All.
Repro: before connecting, the bar reads "Camera Disconnected / Mount Disconnected". After
connecting it reads **"Camera sim_camera_1"**, **"Mount sim_mount_1"**, **"Focus 25000"**.
Expected: the same names the rest of the app uses - "Simulated Camera", "Simulated Mount" - or a
status word.
Actual: the app shows its internal device identifiers in permanent chrome that is visible on every
screen, and the focuser chip shows a bare step count (25000) with no unit and no label.
Evidence: /tmp/ns-audit/shots/cons/25-imaging.png (status bar)

### CON-25 (P3) - Units and precision for the same quantity differ across one screen
Screen: Imaging.
Repro: compare the capture bar with the Exposure Settings card, both visible at once.
- Capture bar: `Dur  2 s`  (abbreviated label "Dur", unit "s", value "2")
- Exposure Settings: `Exposure  2.0  sec` (full label, unit "sec", value "2.0")
Two unit spellings and two precisions for a duration in seconds, ~600px apart on one screen.
Evidence: /tmp/ns-audit/shots/cons/25-imaging.png

### CON-26 (P3) - At least four different "no value" tokens are in use
Screens: Imaging, Dashboard, Equipment, onboarding.
Repro: read the placeholders for absent data.
- `---`   (Imaging HFR/Stars/Median/Mean, status-bar temperature, top-strip Temp/Focus/HFR/RMS)
- `--`    (Imaging overlay bar, "Sky --")
- `- - -` (Dashboard top strip renders the same token with wide letter-spacing)
- `-- not set --` (onboarding review, "Capture defaults")
- `No data` / `No Image` / "No runs yet - your first night will appear here." (prose empty states)
A design system should ship one empty token and one empty-state voice; this build has at least
four of the former.

### CON-27 (P3) - The two validation messages for one empty sequence contradict each other
Screen: Sequencer -> Builder.
Repro: Sequencer (a brand-new "New Sequence" with 0 nodes) -> click the red "1" / amber "1" badges
in the sequence header. The "Sequence issues" dialog lists, one above the other:
- "Empty Sequence - The sequence has no runnable instructions. **Add at least one instruction to
  run.**"
- "No Exposures - No exposure nodes found. **The sequence will run** but capture no images."
One says it cannot run, the other says it will run, about the same empty document, in the same
dialog. The issue titles are also Title Case where the rest of the app's headings are sentence
case.

### CON-28 (P3) - Node palette is clipped by its own hint bar
Screen: Sequencer -> Builder -> Nodes palette (left column).
Repro: open the Sequencer. The palette lists Target / Take Exposures / Change Filter / Smart
Exposure / Dither / Live Stacking. The "Live Stacking" card is **sliced horizontally** by the
"Drag nodes or double-click to add" hint bar that floats over the bottom of the list, hiding its
description. Every card's description is also ellipsised
("Root node containing imaging instructio...", "One row per filter; handles rotation + di...").
Evidence: /tmp/ns-audit/shots/cons/29-sequencer.png

### CON-29 (P4) - The "opens a dialog" ellipsis convention is applied to exactly one menu item
Screen: Sequencer -> Start menu (the tree exposes the same labels as toolbar buttons).
Repro: read the action names: "New Sequence", "Quick-Start Wizard", "Open Sequence",
"Import from NINA / SGP", **"Export Sequence File..."**, "Plan Mosaic", "Polar Alignment".
Only the export action carries the trailing ellipsis that signals "this opens a dialog", although
Open / Import / New all open one too.

### CON-30 (P2) - A red "Weather Critical" alert fires because weather monitoring is switched OFF
Screen: Weather.
Repro: fresh profile -> Weather. A full-width red banner pushes the entire app chrome down:
**"Weather Critical / Weather safety is off - conditions are not being checked"** with a "Snooze"
action. The same screen's status panel says "Safety Status: Not monitoring - weather safety is
off, conditions are not being checked" and "Weather safety is switched off, so none of the above
is in effect."
Expected: "off" is a configuration state, not a critical condition; at most an informational
prompt to enable it.
Actual: the highest-severity alert style in the app is spent on a feature the user has not turned
on, on first run, before any weather data could be judged. It also offers "Snooze", which implies
the condition will pass on its own - it will not, because nothing is being measured.
Evidence: /tmp/ns-audit/shots/cons/33-weather.png

### CON-31 (P3) - The safety alert banner is inserted above the shell and moves the whole nav rail
Screen: any screen once the weather alert is raised (it appears after the Weather screen is first
opened and then persists app-wide).
Repro: compare /tmp/ns-audit/shots/cons/29-sequencer.png (no banner) with
/tmp/ns-audit/shots/cons/33-weather.png and /tmp/ns-audit/shots/cons/34-plantonight.png (banner),
all at 1600x900. The "Dashboard" nav item sits at y=61 without the banner and **y=111 with it**:
the banner is stacked above the entire application shell, so raising or snoozing it shifts the
primary navigation, the window title area and every screen's content by ~50px at once.
Expected: a transient app alert occupies the content area (or overlays), leaving global navigation
anchored.

### CON-32 (P3) - Three vocabularies for on/off, and two relative-time formats, in one panel
Screen: Weather -> status panel ("Current Settings").
Repro: read the value column:
- Weather Safety: "Off - not monitoring"
- Auto-Park: "On, not armed"
- Auto-Resume: "Disabled"
Three different ways to say the same two states, stacked vertically.
Same screen, timestamps: the radar source card says **"Updated just now"** while the status panel
says **"Updated 0 sec ago"** - two formats for the same relative time, one of which ("0 sec ago")
is a raw formatter output.

### CON-33 (P3) - Guiding shows the same RA/Dec/Total row twice, with different abbreviations
Screen: Guiding -> Guide Graph card.
Repro: look at the card header and the toolbar directly beneath it.
- Header, top right: `RA: -   Dec: -   Total: -`
- Toolbar, ~40px below: `RA: -   Dec: -   Tot: -   Time: 5m   Scale: +/-2"`
The same three statistics are rendered twice in one card, and the third label is spelled "Total"
in one and "Tot" in the other.
Evidence: /tmp/ns-audit/shots/cons/30-guiding.png

### CON-34 (P3) - Screens clip their own cards while leaving a wide empty band below
Screens: Guiding (clearest), Sequencer, Imaging, Equipment.
Repro: Guiding at 1600x900 - the "Calibration" card's body text is cut mid-sentence at the card
edge, the right column hides the whole Dither section behind a small chevron, and the left column's
"Star Statistics" card is cut to its header - while **~135px of empty page** sits below all three
columns. Enlarging the window to 1750x1040 (`resize 1750 1040`) grows the cards but reproduces the
same shape: an empty band at the bottom and a clipped last card.
Evidence: /tmp/ns-audit/shots/cons/30-guiding.png, /tmp/ns-audit/shots/cons/31-guiding-tall.png

### CON-35 (P3) - Guiding uses a fifth empty-value token
Screen: Guiding (see also CON-26).
Repro: with no guider connected, SNR / Star Mass / RA / Dec / Total all render as an **em dash**
"-", whereas Imaging renders absent values as `---`, the status bar as `---`, the Dashboard strip
as `- - -` and onboarding as "-- not set --".

### CON-36 (P3) - "Estimated integration: 3h 60m" on the same card that says "~4.0h integration"
Screen: Plan Tonight -> Recommendation -> Night Outlook -> first target card (NGC7063).
Repro: open Plan Tonight on a fresh profile with the site set to 40.71 / -74.01.
Actual: the chip row reads "~4.0h integration" and the line directly below it reads
**"Estimated integration: 3h 60m"** - a duration formatter that carries 60 minutes instead of
rolling over to the next hour, printed 25px under the correctly-rounded version of the same
number.
Evidence: /tmp/ns-audit/shots/cons/34-plantonight.png

### CON-37 (P4) - Section subtitle starts in lower case
Screen: Plan Tonight -> "NIGHT OUTLOOK".
Repro: read the eyebrow row: `NIGHT OUTLOOK  best for the whole night - peak altitude, transit &
window hours`. Every other eyebrow/subtitle pair in the app capitalises the subtitle ("Weather
Radar / Live cloud tracking and safety monitoring", "Equipment / Connect devices"). This one does
not, and uses "&" where the neighbouring copy spells out "and".

### CON-38 (P2) - The Dashboard equipment panel names devices by driver ID, in three different formats
Screen: Dashboard (the live layout shown once equipment is connected).
Repro: Equipment -> Connect All -> Dashboard. The right-hand Equipment card lists:
- Camera / **sim_camera_1**      (chip: "Idle")
- Mount / **sim_mount_1**        (chip: "Parked")
- Focuser / **sim_focuser_1**    (chip: "Idle")
- Filter wheel / **Simulator filterwheel 1** (chip: "Ready")
Expected: the names the user chose in onboarding - "Simulated Camera", "Simulated Mount",
"Simulated Focuser", "Simulated Filter Wheel".
Actual: three devices show the raw driver identifier, the fourth shows a fourth spelling
("Simulator filterwheel 1" - lower case, no capitals, spaces instead of underscores), and the four
idle-state chips use three different words ("Idle", "Parked", "Ready") for the same condition.
Evidence: /tmp/ns-audit/shots/cons/38-light-dashboard.png

### CON-39 (P3) - Dropdown menu options are invisible to accessibility, and so is the rest of the app while one is open
Screen: any dropdown; verified on Settings -> Appearance -> Theme.
Repro: Settings -> Appearance -> click the "Dark" dropdown. The menu paints Dark / Light /
Red night (/tmp/ns-audit/shots/cons/37-theme-menu.png). Now run `tree`: the **entire tree collapses
to the status bar** - the three options are absent, and so is every other control on the page.
Expected: menu items exposed as selectable nodes with the current one marked.
Actual: a screen-reader user who opens any dropdown in Settings (Theme, Font size, UI scale,
Language) or Imaging (Frame Type, Binning) is presented with nothing at all.

### CON-40 (P4) - The accent-colour picker is colour-only, and ships two options whose names differ by a suffix
Screen: Settings -> Appearance -> Accent color.
Repro: seven unlabelled swatches. `tree` collapses all seven into one button whose name is
"Accent color / Primary accent color / Cyan-blue / Emerald / Amber / Red / Deep sky / Pink / Cyan",
so neither a screen reader nor a colour-blind user can tell which swatch is which. Two of the
seven are named "**Cyan-blue**" and "**Cyan**", and the naming convention switches from hyphenated
("Cyan-blue") to spaced sentence case ("Deep sky") within the same list.

### CON-41 (P3) - Card titles in one dashboard column mix ALL CAPS and sentence case
Screen: Dashboard (live layout, after Connect All).
Repro: read the card titles top to bottom: "Equipment" and the middle column's cards are sentence
case, while "GUIDING" and "SAFETY" in the same view are ALL CAPS. The Dashboard's own briefing
layout does the same thing ("TONIGHT'S BRIEFING", "ASTRO DARK IN", "IMAGING WINDOW", "EXPOSURE",
"USABLE", "SCORE" in caps next to "Tonight's targets", "Readiness", "Last run", "Moon" in
sentence case).
Evidence: /tmp/ns-audit/shots/cons/39-after-rapid-nav.png, /tmp/ns-audit/shots/cons/18-dashboard.png

### CON-42 (P4) - Ellipsis characters are mixed between the real character and three periods
Screens: several.
Repro: compare - Dashboard live layout "Waiting for first frame**...**" (three ASCII periods),
Sequencer palette "Search nodes**...**", against onboarding "Awaiting inputs**...**" (U+2026),
Settings "Search settings**...**" (U+2026) and the telescope dialog "Search by brand or
model**...**" (U+2026). Two search fields on two screens use two different glyphs for the same
placeholder idiom.

### CON-43 (P3) - Every keystroke in the site fields is committed to the backend as a real location
Screen: onboarding step 11 "Where do you observe?" (charter: state truthfulness while typing).
Repro: type `-74.01` into Longitude and watch `log --tail`:
```
[API] api_set_location called with lat=40.71, lon=-7
[API] api_set_location called with lat=40.71, lon=-74
[API] api_set_location called with lat=40.71, lon=-74.01
```
The app briefly sets the observer's site to longitude **-7** (Portugal) and then **-74** while the
user is still typing, each time recomputing the sky. Expected: commit on submit/blur/debounce, as
the capture-folder field on the very next step already does.

## Coverage

Screens visited and reviewed (all driven live, dark theme unless noted):

| Screen / surface | What was exercised |
| --- | --- |
| Onboarding steps 1-13 | every step walked, both validation paths on the capture-folder step, Tab traversal, telescope-library dialog, profile saved |
| Dashboard (empty state) | first-run layout, both coach marks, Tab traversal (14 stops), status bar |
| Dashboard (live layout) | after Connect All: equipment card, guiding card, safety card, light theme |
| Equipment | profile card, device card, discovery bar, STATUS panel, readiness dialog, Connect All |
| Imaging | capture bar, right-hand tab grid, Exposure/File/Session cards, empty preview state |
| Sequencer -> Builder | node palette, toolbar, sequence header, "Sequence issues" dialog |
| Guiding | guide-star/target/graph/controls/calibration cards, at 1600x900 and 1750x1040 |
| Weather | radar, source card, opacity slider, global "Weather Critical" banner + Snooze |
| Plan Tonight -> Recommendation | filter chips, autopilot card, transient alerts, target card + altitude chart |
| Analytics -> Session | empty state, tab bar |
| Settings -> General | Startup/Behavior rows, switches, Language row |
| Settings -> Appearance | theme dropdown (incl. switching to Light and back), accent swatches, font/UI-scale rows |
| App shell | title bar, nav rail, bottom status bar, alert banner, tour nudges on 7 screens |

Not reached in this pass (each needs its own drive; none were blocked by a defect):
Sequencer Templates/Sequences/History tabs; Plan Tonight Projects/Schedule/Framing/Planetarium/
Discover tabs; Analytics History/Projects/Equipment Stats/Science/Diagnostics tabs; the remaining
Settings groups (Location, Files & Storage, Help & Tutorials, About, EQUIPMENT, IMAGING,
AUTOMATION & SAFETY, SCIENCE, NOTIFICATIONS & REMOTE, ADVANCED - the last two are the ones clipped
out of view per CON-34); the "Red night" theme; the title-bar notification/account menus; and any
running-sequence state (no run was started, since this cluster reviews chrome rather than
behaviour).
