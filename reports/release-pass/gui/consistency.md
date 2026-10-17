# Cross-screen design-language audit — wave 2 (cluster: consistency)

Wave 1's report is preserved verbatim at `reports/release-pass/gui/consistency-wave1.md` (CON-1 …
CON-43). No commit in the tree references a CON- id, so those 43 findings are presumed still open;
this wave does **not** re-report them. Numbering continues at **CON-44** so the two files can be
concatenated without collisions.

Driven live against the release bundle on `SK_AUDIT_DISPLAY=:88`, profile `gui-consistency`,
fresh scratch profile (first-run onboarding). Read-only review; no app code was changed.

## Summary

20 findings (CON-44 … CON-63): **4 x P2, 12 x P3, 4 x P4**. No P0/P1 — as in wave 1, nothing here
loses a night on its own.

This wave deliberately went where wave 1 could not reach: the Sequencer's Templates / Sequences /
History tabs, all six Analytics tabs, all six Plan Tonight tabs, the Settings groups beyond
General/Appearance, the title-bar chrome, and the Red night theme. Three things came out of it:

1. **One layout bug explains a whole class of wave-1 findings.** The first-run tour nudge is laid
   out *in flow*, not floated, so on a fresh install every screen is ~16% shorter and clips its own
   cards until each of the seven nudges is dismissed. The sharpest consequence: the entire
   **ADVANCED** settings group is off-screen on first run (CON-44). Wave-1 CON-34's "wide empty
   band below" is this.
2. **The seams between screens are where the design language breaks.** Analytics ships four empty-
   state patterns across five tabs (CON-45); the Sequencer's four tabs use three header/punctuation
   rules (CON-52); "Open Settings" is a button on one Plan Tonight tab and an inert panel on the
   next (CON-55); two screens called "Projects" give contradictory instructions (CON-58); one
   action gets three button treatments in a single Settings list (CON-62).
3. **The app's chrome is the least finished surface.** The title bar is absent from the
   accessibility tree entirely — including the Settings gear, the only route to Settings — and one
   of its four icons does nothing at all (CON-61); the dialog behind another opens clipped by the
   window edge (CON-60).

Also recorded: user-facing scheduler internals ("No tick scheduled", CON-54), a run-state filter row
that is a leaked enum including "Paused-stopped" (CON-51), and a card on Plan Tonight that tells you
to go and use Plan Tonight (CON-53).

**Checked and found fine** (stated so a verifier does not re-spend the budget): the **Red night**
theme is genuinely monochrome — every colour in a full-window capture satisfies G == B with R
greater, brightest text is `#EE9999`, and there is no blue or green pixel anywhere, including the
title bar, nav rail and status bar; the accent-colour row correctly replaces its swatches with
"Red night is monochrome red, so the accent has no effect while it is selected. #5B9EC4 applies
again"; Escape closes every dialog opened this pass; focus is trapped inside a modal (three Tabs in
the Keyboard Shortcuts dialog land on its only button and stay); the Sequencer's keyboard shortcuts
are documented in-app and its controls carry their accelerators in their accessible names
("Builder (Alt+1)", "Undo (Ctrl+Z)"); a disabled control that explains itself in its own name
exists and is good ("Exposure Triggers (add an exposure node first)"); onboarding **is** resumable,
so the welcome step's "you can leave and pick this back up at any point" is true (Settings → Help &
Tutorials → Re-run equipment setup).

Harness notes for the verifier: `--profile` must follow the subcommand. `for x in "a b"; set -- $x`
does **not** split under this shell, so scripted click loops silently click nowhere — drive one
action per invocation. Mouse-wheel scrolling is not a harness command but `xdotool click 5` on the
audit display works and is sometimes needed to prove a "clipped" card is merely below the fold —
`key Page_Down` does not scroll these panes.

## Findings

### CON-44 (P2) — The first-run tour nudge is laid out in-flow and shortens every screen by ~16%
Screens: all seven nav destinations (proved on Sequencer and Analytics → Science).
Repro: `start --fresh`, skip onboarding, open **Sequencer**. The "Sequencer Tour" card sits at the
bottom-right. The three-panel workspace (node palette / canvas / Properties) stops at window
y≈865 of 1050, with a **147px black band** below it; the node palette is cut through the middle of
the "Live Stacking" card and the whole "Science" node category is out of view. Click **Maybe
Later** on the nudge and, with no other change, the workspace grows to y≈1012 and three more
palette rows appear.
Same on **Analytics → Science**: with the "Analytics Tour" nudge up, the "Science guide" card is
cut through its step row; dismiss the nudge and the card's body and its primary button ("Show me
the 5 steps") come into view.
Expected: a coach mark floats **over** the content (it is transient, dismissible chrome) — every
other overlay in this app does.
Actual: it is in the layout, so on a fresh install every screen renders ~16% shorter and clips its
own cards until the user dismisses seven separate nudges. This is very probably the root cause of
wave-1 **CON-34** ("screens clip their own cards while leaving a wide empty band below") — the
"empty band" is the space reserved for the nudge.
**The consequence that matters is in Settings**: with the "Settings Tour" nudge up, the Settings
sidebar is cut after "NOTIFICATIONS & REMOTE" and the entire **ADVANCED** group is not on screen at
all (24-settings.png). Click "Maybe Later" and ADVANCED appears immediately (25-settings-advanced.png).
On a fresh install a whole settings group is invisible, and the only way to find it is to dismiss a
coach mark that does not look related to it. This is also the Settings half of wave-1 CON-34.
Evidence: /tmp/ns-audit/shots/cons2/16-sequencer.png (nudge up) vs
/tmp/ns-audit/shots/cons2/17-sequencer-nonudge.png (dismissed); 10-science.png vs
13-after-dismiss.png; 24-settings.png vs 25-settings-advanced.png.

### CON-45 (P3) — Analytics ships four different empty-state patterns in one screen
Screen: Analytics, tabs Session / History / Projects / Equipment Stats / Diagnostics.
Repro: `start --fresh` → Analytics, click each tab.
- **Session**: centred folder icon + "No session history" + "Complete an imaging session to see
  history here" — no full stops, and the copy describes *history*, not the session tab you are on.
- **History**: byte-identical icon, title and body to Session, plus a search field and two
  disabled filter chips.
- **Projects**: no icon, left-aligned, "No targets available for project tracking yet." + "Add
  targets and capture images to track multi-night progress." — both full-stopped.
- **Equipment Stats**: no empty state at all — four cards of zeros and "No data" (see CON-46).
- **Diagnostics**: centred **star outline** icon + "Select an imaging session to analyze" +
  "Optical diagnostics require plate-solved frames with PSF and residual data."
Expected: one empty-state component (icon, title, body, optional action) with one punctuation rule.
Actual: five tabs of one screen use four different structures, two punctuation rules, and a star —
the app's "favourite" glyph — as the illustration for "no session selected". None of the five
offers an action.
Evidence: 03-analytics-session.png, 09-equip-stats.png, 14-diagnostics.png.

### CON-46 (P3) — Equipment Stats mixes "0" and "No data" for the same absence, and calls a sum an average
Screen: Analytics → Equipment Stats, fresh profile (no sessions).
Repro: read the four cards: Total Exposures **0**, Meridian Flips **0**, Autofocus Runs **0**,
Avg RMS **No data**, Accepted Integration **No data**, Avg HFR Achieved **No data**, Avg
Temperature **No data**.
Expected: one token for "no data yet" in one card grid. "Accepted Integration" is a **sum**, and
the sum over zero sessions is `0h` — it is the odd one out among the "No data" rows, which are all
genuine averages.
Actual: two tokens, split on no rule the reader can see, and "No data" is a **sixth** spelling of
absence in this build (wave-1 CON-26/CON-35 recorded `---`, `--`, `- - -`, em dash, "-- not set
--", "No data"; Analytics → Science adds a bare em dash again).
Also, the four cards are laid out as a single row with ragged bottoms (Camera 3 rows tall, Mount 1)
— sibling cards in one row do not share a height anywhere else in the app.
Evidence: /tmp/ns-audit/shots/cons2/09-equip-stats.png

### CON-47 (P3) — A live "Learn more" link is published to accessibility as a disabled panel
Screen: Analytics → Diagnostics.
Repro: open Analytics → Diagnostics. `tree` reports
`panel: Learn more about optical diagnostics [DISABLED]`. Click it
(`click-img 14-diagnostics.png 299 178`) and it **opens the "Reading optical diagnostics" dialog**.
Expected: an interactive help link is a `button`/`link` in the tree, enabled.
Actual: it is a non-interactive `panel` marked `[DISABLED]`, so a screen-reader or keyboard user is
told the only explanation of this screen's numbers is unavailable, while it works for a mouse user.
Second instance, same shape: open Settings → Appearance and click the **Theme** dropdown. `tree`
reports its three options as `button: Dark [DISABLED]`, `button: Light [DISABLED]`,
`button: Red night [DISABLED]` — yet selecting "Red night" from that menu works and repaints the
app. The build's `[DISABLED]` flag is therefore not trustworthy in either direction (wave-1 CON-2
recorded the opposite error: genuinely disabled buttons that are *not* flagged).
Evidence: /tmp/ns-audit/shots/cons2/14-diagnostics.png, 15-diag-dialog.png

### CON-48 (P3) — One Analytics tab has a page title and a 90-word jargon paragraph; its four siblings have neither
Screen: Analytics → Diagnostics.
Repro: click through the six Analytics tabs. Session/History/Projects/Equipment Stats/Science open
straight into content. **Diagnostics** alone renders an H1 ("Optical Train Diagnostics"), a
right-aligned status ("No sessions available") on the title line, and a four-line, ~1050px-wide
paragraph: "Optical-train mechanical health — collimation, tilt, sensor backfocus, and image-plane
flatness — the hardware issues that show up as systematic PSF aberrations across the field. …"
Expected: the same one-line helper voice the rest of the app uses, with the long explanation behind
the "Learn more" dialog that already exists two lines below it and says much the same thing.
Actual: a wall of unbroken technical prose at ~150 characters per line, in a tab that otherwise
has nothing on it.
Evidence: /tmp/ns-audit/shots/cons2/14-diagnostics.png

### CON-49 (P4) — "Back" on onboarding step 1 is live-looking and does nothing
Screen: first-run onboarding, step 1 of 13.
Repro: `start --fresh`; click **Back** (`click-img 01-welcome.png 256 688`). Nothing happens —
`tree` still reports "Step 1 of 13". A click on **Next** at the same y advances, so the click is
landing.
Expected: hide the button on the first step, or dim it to the disabled treatment used elsewhere.
Actual: it renders as a normal secondary button (label luminance 0.70 against Next's 0.87 — not
the app's disabled grey) and the a11y tree does not mark it `[DISABLED]`, so nothing but trying it
tells the user it is inert.
Evidence: /tmp/ns-audit/shots/cons2/01-welcome.png

### CON-50 (P3) — The Templates search box is a field drawn inside another field, and the inner one is clipped
Screen: Sequencer → Templates.
Repro: open Sequencer → Templates and look at the search control next to the title
(`shot --region 280x70+750+268`). There is an outer rounded container holding the magnifier, and a
**second bordered rounded rectangle** (the text field itself) inside it whose right edge runs past
the container and is cut off, and whose bottom border is missing.
Expected: the single-box treatment used by every other search field in the app — Sequencer →
History ("Search by sequence / target"), Analytics → History ("Search sessions..."), the node
palette ("Search nodes...") all draw one box with the icon inside it.
Actual: one screen ships a nested, clipped variant.
Evidence: /tmp/ns-audit/shots/cons2/19-search-field.png (crop), 18-templates.png (context)

### CON-51 (P3) — The run-state vocabulary is a leaked state machine: seven chips, four words for "did not finish"
Screen: Sequencer → History.
Repro: open Sequencer → History with no runs recorded. The filter row reads: **Completed, Failed,
Aborted, Stopped, Paused-stopped, Interrupted, Running**.
Expected: user-facing states a person can tell apart, and one word per outcome.
Actual: "Aborted", "Stopped", "Interrupted" and "Paused-stopped" are four labels for "it did not
finish", and **"Paused-stopped"** is a raw enum name (hyphenated compound, no such phrase appears
anywhere else in the product). Nothing on the screen says how they differ.
Second, all seven chips are live on a screen whose own empty state says "No runs yet" — two tabs
away, Analytics → History correctly renders its filters `[DISABLED]` when there is nothing to
filter.
Evidence: /tmp/ns-audit/shots/cons2/20-seq-history.png

### CON-52 (P3) — One screen, four tabs, three different header/subtitle rules
Screen: Sequencer (Builder / Templates / Sequences / History).
Repro: click the four tabs in order and read the top of each:
- **Builder** — no page header at all, straight into the toolbar.
- **Templates** — H1 "Sequence Templates" + "Start with a template or save your sequences for
  reuse" (no full stop).
- **Sequences** — H1 "Sequence Library" + "Browse and load your saved imaging sequences" (no full
  stop).
- **History** — H1 "Execution History" + "Past sequence runs with statistics and performance
  data." (full stop).
Their empty states diverge the same way: "No saved sequences / Save your sequences to access them
later / Tip: Use "Save Current" to save your sequence" (no stops, plus a one-off `Tip:` line using
straight quotes around a button name) against "No runs yet / Execute a sequence to see its history
here." (full stop).
Evidence: 18-templates.png, 20-seq-history.png

### CON-53 (P2) — The Plan Tonight screen tells you to go and use Plan Tonight
Screen: Plan Tonight → Schedule, "Unattended Autopilot" card.
Repro: Plan Tonight → Schedule. The card's description reads: "Runs hands-off and re-picks the best
target all night as the sky changes. **For a plan you can see and edit before it runs, use Plan
Tonight instead.**"
Expected: point at the surface that actually holds the editable plan (this is the Plan Tonight
screen; the editable plan lives on the *Recommendation* tab, one tab to the left).
Actual: the copy sends the user to the screen they are standing on, so the one instruction on the
card is unfollowable. This is written for a build in which Autopilot lived somewhere else.
Evidence: /tmp/ns-audit/shots/cons2/23-schedule.png

### CON-54 (P3) — "No tick scheduled.": scheduler internals, three names for one feature, and a monospace box
Screen: Plan Tonight → Schedule.
Repro: read the left card top to bottom. Title **"Unattended Autopilot"**, body "**Autopilot** is
stopped. Run **unattended** all night to begin evaluating targets every 60s.", then "**No tick
scheduled.**", then a button "Run unattended all night", then red text "Cannot start unattended
until: Camera and mount, Observing location, Capture output path, Disk space."
Expected: one product name, and no scheduler vocabulary on screen.
Actual: three names for the feature in four lines; "tick" is an implementation term that appears
nowhere else in the UI; and the requirement list is a comma-joined sentence of noun phrases rather
than the checklist pattern the Dashboard readiness card already uses.
The "Reasoning" box directly below renders its text ("No candidate targets available") in a
**monospace** face — the only monospace text found anywhere in the app's screens.
Evidence: /tmp/ns-audit/shots/cons2/23-schedule.png

### CON-55 (P3) — The same "Open Settings" control is a button on one tab and a non-interactive panel on the next
Screen: Plan Tonight → Recommendation vs Plan Tonight → Framing.
Repro: on **Recommendation** (no location set) `tree` reports `button: Open Settings` under
"Location not configured". Switch to **Framing** and the equivalent affordance under "No Equipment
Profile" is reported as `panel: Open Settings` — not a button, not focusable.
The two empty states also disagree on case and on how they name a destination: "Location not
configured" / "…in Settings" (sentence case, no path) against "**No Equipment Profile**" /
"…in Settings → Equipment" (title case, arrow path). A third variant on the same screen's Projects
tab is "No projects yet" (sentence case).
Evidence: trees quoted above; 22-plan-tonight.png

### CON-56 (P4) — Two ALL-CAPS buttons exist in the whole app, both on the Planetarium tab
Screen: Plan Tonight → Planetarium.
Repro: open the tab; the time controls are labelled **"NOW"** and **"TONIGHT"**. Every other button
in the build is Title or sentence case ("Start Tour", "Maybe Later", "Close", "New Project", "Run
unattended all night").
Also on this tab: "Bortle: 5 (lim 5.9m)" — "lim … m" (limiting magnitude) is unexplained, and the
trailing "m" reads as minutes or metres next to a row of angle values.
Evidence: `tree` on Plan Tonight → Planetarium

### CON-57 (P3) — Three incompatible copy registers, sometimes one click apart
Screens: Plan Tonight → Discover, Analytics → Diagnostics, Analytics → Science, Sequencer → History.
Repro: read the one-line description at the top of each:
- Discover → Your Sky: "**Every photon you capture becomes a brick in your growing all-sky
  atlas.**" and its empty state "Your sky is dark — for now".
- Analytics → Science: "**Turn pretty pictures into real measurements**".
- Sequencer → History: "Past sequence runs with statistics and performance data."
- Analytics → Diagnostics: "Optical-train mechanical health — collimation, tilt, sensor backfocus,
  and image-plane flatness — the hardware issues that show up as systematic PSF aberrations across
  the field."
Expected: one voice. Actual: lyrical marketing, coaching, terse spec and a PSF-aberration lecture,
all reachable within two clicks of each other, so the product reads as four products.

### CON-58 (P3) — Two screens called "Projects" describe the same feature and contradict each other
Screens: Analytics → Projects and Plan Tonight → Projects.
Repro: Analytics → Projects shows "No targets available for project tracking yet." / "Add targets
and capture images to track multi-night progress." with **no action**. Plan Tonight → Projects
shows "No projects yet" / "Create a multi-night project to track targets and integration goals
across sessions." with a **New Project** button.
Expected: one destination for a project, or copy that says how the two differ.
Actual: one tells you a project is created by adding targets and capturing, the other tells you to
create a project first; whichever the user believes, the other tab is wrong.

### CON-59 (P4) — Five duration formats in one card grid
Screen: Sequencer → Templates → Starters.
Repro: read the six starter cards' duration chips: "~1 hr 15 min", "~3 min capture", "~3 hr 30
min", "~10 min capture", "~16 hr (multi-night)". Two carry a trailing word ("capture",
"(multi-night)") that the others do not, and elsewhere the same quantity is written "3h 60m" and
"~4.0h" (wave-1 CON-36).
Evidence: /tmp/ns-audit/shots/cons2/18-templates.png

### CON-60 (P2) — The Connection Status dialog opens clipped by the bottom of the window
Screen: app shell, title-bar connection icon (the crossed-out eye, left of the bell).
Repro: click the crossed-eye icon in the title bar (`click-img 27-help-tutorials.png 1056 15`).
A modal scrim covers the app and a dialog appears **anchored to the bottom edge**: at 1600x900 only
its top ~75px are on screen — the title "Connection Status", the line "Not connected to a server",
and nothing else; the card has no bottom edge and no visible button. `resize 1750 1040` and reopen:
the same clipping, so it is a positioning bug, not a window-size one. `tree` shows the dialog holds
only those two strings, so whatever else it offers (connect, address, help) is unreachable.
Escape does close it.
Expected: centre the dialog like every other modal in the build (both help dialogs seen this pass
centre correctly).
Evidence: /tmp/ns-audit/shots/cons2/30-conn-dialog-full.png, 31-conn-dialog-tall.png

### CON-61 (P2) — The whole title bar is missing from the accessibility tree, and one of its icons does nothing
Screen: app shell (every screen).
Repro: with any screen open, `tree | grep -iE "notification|account|settings|minimi|close"` returns
nothing from the title bar. The four icon buttons at the top right (connection status, alerts bell,
account, Settings gear) and the three window controls are **not in the tree at all** — the bell's
*popup* appears once opened, but the control that opens it never does. The Settings gear is the
only route to Settings, so Settings is unreachable to assistive tech.
Second: the **account (person) icon does nothing**. Clicked three times — twice at 1600x900
(`click-img 27-help-tutorials.png 1124 15`) and once after resizing to 1750x1040
(`click-img 32-appearance.png 1137 14`) — no popup, no dialog, no tree change, while its immediate
neighbours (bell → "Transient Alerts" popup; eye → Connection Status dialog; gear → Settings) all
respond. Either it is a dead button or it is a status indicator drawn identically to three buttons.
Evidence: /tmp/ns-audit/shots/cons2/28-account-click.png (nothing opened), 27-help-tutorials.png

### CON-62 (P3) — Three button treatments for one action, and two capitalisation rules, in one Settings list
Screen: Settings → Help & Tutorials.
Repro: read the "Guided Flows" list (five rows) and "Tutorial Tours" below it. All seven rows do
the same thing — start a guided flow — with three different buttons:
- filled blue + play icon: "Start" (First Night Walkthrough, Capture your first light)
- dark outlined + refresh/box icon: "Re-run", "Re-run", "Open"
- pale blue, no icon, smaller: "Start" (Equipment Setup, Target Planning, Automated Imaging …)
Row titles in the same five-row list mix cases: "**First Night Walkthrough**" and "**Generate
Diagnostic Dump**" (Title Case) against "Capture your first light", "Re-run equipment setup",
"Re-run onboarding tour" (sentence case).
The same onboarding is named four ways across the app: "Set up your rig" (the wizard's own title),
"equipment onboarding wizard", "Re-run equipment setup", "first-launch spotlight tour".
Evidence: /tmp/ns-audit/shots/cons2/27-help-tutorials.png, 26-help-flows.png

### CON-63 (P4) — A crossed-out eye is the icon for "not connected to a server"
Screen: app shell title bar.
Repro: the leftmost title-bar icon is an eye with a slash through it, rendered with a filled
"selected" background unlike its three neighbours; clicking it opens "Connection Status — Not
connected to a server".
Expected: the crossed-eye glyph reads as "hidden / visibility off" (it is what this app uses for
hidden content elsewhere), and the filled background reads as "this toggle is on". A network
concept wants a network glyph (the app already ships a globe icon, used in the status bar for the
web dashboard).
Evidence: /tmp/ns-audit/shots/cons2/28-account-click.png (icon row), 30-conn-dialog-full.png

## Coverage

Driven live this pass (dark theme unless noted):

| Screen / surface | What was exercised |
| --- | --- |
| Onboarding step 1 | Back/Next behaviour, stepper "optional" markers, Skip onboarding path |
| Dashboard (first run) | layout, empty-state copy, tour nudge, status bar |
| Analytics → Session | empty state, tab bar, selection styling |
| Analytics → History | search + disabled filter chips, empty state |
| Analytics → Projects | empty state and copy |
| Analytics → Equipment Stats | four stat cards, zero vs "No data" tokens, ragged card heights |
| Analytics → Science | Science/First Light/Observing Alerts sub-tabs, plate-solve health card, Night Story, Science guide, scroll behaviour |
| Analytics → Diagnostics | page header, jargon paragraph, "Learn more" link + its dialog, empty state |
| Sequencer → Builder | toolbar, node palette, Properties pane, tour-nudge height test |
| Sequencer → Templates | starter card grid, filter chips, search field, duration formats |
| Sequencer → Sequences | empty state, "Tip:" line, sort control |
| Sequencer → History | seven state filter chips, search placeholder truncation, empty state |
| Sequencer → Keyboard Shortcuts dialog | contents, focus trap (3x Tab), Escape |
| Plan Tonight → Recommendation | filter chip row, "Location not configured" empty state |
| Plan Tonight → Projects | empty state + New Project |
| Plan Tonight → Schedule | Unattended Autopilot card, requirement list, Reasoning box, Target queue empty state |
| Plan Tonight → Framing | equipment-profile empty state, rotation/FOV controls, a11y roles |
| Plan Tonight → Planetarium | HUD readouts, NOW/TONIGHT buttons, Bortle readout, tour nudge |
| Plan Tonight → Discover | Your Sky / Constellation / Collaborate tabs, copy register |
| Settings → General | Startup/Behavior rows, Language row (disabled) |
| Settings → Appearance | theme dropdown + option a11y states, **Red night applied and measured**, accent row behaviour under Red night, Display rows |
| Settings → Help & Tutorials | Guided Flows list, Tutorial Tours list, button treatments, onboarding-resume claim |
| Settings nav | all 12 groups listed; ADVANCED visibility before/after nudge dismissal |
| App shell title bar | connection dialog, alerts popup, account icon, Settings gear, a11y coverage |
| Window resize | 1600x900 → 1750x1040 reflow while a dialog was open |

Not reached this pass (each needs its own drive; none was blocked by a defect): Imaging, Guiding,
Weather and Equipment screens (all four covered by wave 1); Settings groups EQUIPMENT, IMAGING,
AUTOMATION & SAFETY, SCIENCE, NOTIFICATIONS & REMOTE, ADVANCED (only their presence in the nav was
checked); Analytics → Science → First Light / Observing Alerts sub-tabs; Plan Tonight → Discover →
Constellation / Collaborate sub-tabs; any running-sequence or connected-device state (this cluster
reviews chrome, and the device clusters own that path); the Light theme (wave 1 verified it).

Blocked: nothing, once the bundle was consistent. The first two `start` attempts failed with
"Native bridge failed to initialize: libskotiq_bridge.so … is stale relative to this build"
because a concurrent agent was mid-rebuild — `libskotiq_bridge.so` was absent from
`build/linux/x64/release/bundle/lib/` at 08:36 and was replaced at 08:41. Starting after that
succeeded with no further trouble.
