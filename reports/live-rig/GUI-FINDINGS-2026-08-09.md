# Desktop GUI drive — 2026-08-09

Driven with `tools/ui_audit/drive_linux.py` against the release Linux bundle built from
`a43145612` (all of tonight's fixes), scratch profile, softpipe on a private X server.

Why this exists: everything earlier tonight went through the headless HTTP API. The desktop GUI was
never launched, and it has its own start path — the `hasInEditorSequence` branch of
`handleSequencerStart`, plus `SequenceExecutor.start()` — that the API drive never touches.

Findings are numbered G1, G2, ... to keep them apart from the API-side L-series.

## G1 — Back on onboarding step 1 is inert but announces itself as actionable *(minor, accessibility)*

Step 1 of 13. `Back` renders in the secondary/outline style and clicking it leaves the wizard on
step 1 — correct behaviour. But the accessibility tree exposes it as a plain `button: Back` with no
`DISABLED` state, so a screen-reader user is told there is somewhere to go back to and gets silence
when they act on it. Sighted users have the visual hierarchy to fall back on; that is exactly the
cue a screen reader does not carry.

The fix is `onPressed: null` (or `enabled: false`) on the first step rather than a handler that
returns early.

## G2 — the onboarding driver rows are live, and announce themselves as disabled with no state *(fixed)*

Read straight off the running app's accessibility tree at step 2 of 13:

```
panel: Native
Direct SDK connection where the release includes the required vendor library [DISABLED]
panel: Alpaca
ASCOM Alpaca over network. ... [DISABLED]
panel: INDI
INDI protocol through a reachable INDI server. ... [DISABLED]
panel: Sim
Simulated device where that workflow is enabled for testing [DISABLED]
```

The screenshot shows Native/Alpaca/INDI **checked** and Sim unchecked, and clicking the Sim row
toggled it on. So all four are live, three are selected — and assistive technology is told the
opposite of both facts: no checked state at all, and `DISABLED`, which the harness only prints for a
node that is interactive *and* lacks `enabled`/`sensitive`. (Plain labels elsewhere in the same tree
carry no such flag, and `button: Back` carries none either, so this is specific to these rows.)

**Cause.** `_DriverTile` is a bare `InkWell(onTap:)` wrapping a `SkotiqCheckbox`. `InkWell`
publishes a tappable, focusable semantics node that never sets `isEnabled`, and that node shadows the
checkbox's own — correct — `checked`/`enabled` semantics. The checkbox component is not at fault; it
is simply not the node assistive tech reaches. This is the same class as the design-system switch and
checkbox work earlier in the campaign, on a surface that pass did not cover.

**Fix.** Declare the row itself: `Semantics(container: true, checked: selected, enabled: true,
label: '<name>. <description>', onTap: onToggle)`, with the inner row wrapped in `ExcludeSemantics`
so the name is not read twice and there is one tap target rather than two competing ones. Pointer and
keyboard behaviour are untouched.

**Worth noting for the rest of the app:** any bare `InkWell` used as a control has this same
signature. This fix addresses the surface that was reproduced; a sweep for the pattern is warranted.

## G3 — fifteen live controls on one screen announce themselves as disabled *(systemic; root cause fixed)*

Counting `DISABLED` flags on the Sequencer screen's accessibility tree gave **15**, including every
one of the primary tabs:

```
Builder [DISABLED]      Templates [DISABLED]     Sequences [DISABLED]    History [DISABLED]
Tab 1 of 3 [DISABLED]   Tab 2 of 3 [DISABLED]    Tab 3 of 3 [DISABLED]
panel: Target [DISABLED]  panel: Imaging [DISABLED]  panel: Science [DISABLED]   ...
```

All of them work — I navigated the app by clicking them. The harness only prints `DISABLED` for a
node that is interactive **and** lacks `enabled`/`sensitive`, so this is not a labelling nit: a
screen reader is being told the app's main navigation is dead.

**Root cause, and it is one line.** `Semantics(button: true, …)` publishes
`SemanticsFlag.isEnabled` **only when `enabled` is passed**. `button: true` on its own leaves the
flag unset, and AT-SPI reads an interactive node with no enabled state as insensitive.
`AdaptiveTabBar` — used for the tab strips across the app — declared its tabs and its scroll
affordances exactly that way.

Fixed in `adaptive_tab_bar.dart` (both the tab button and the edge affordance), then swept the rest
of the design system and app for the same shape: five more sites in `error_dialog.dart`,
`tutorial_overlay/tooltip.dart` and `atlas_coverage_overlay.dart`. A regex over every
`Semantics(...)` block containing `button: true` and no `enabled:` now returns zero.

G1 and G2 are the same *symptom* from a different cause — a bare `InkWell` publishing a focusable
node with no enabled flag — which is why the driver rows and device rows needed their own container
semantics rather than this one-word fix.

## G4 — a pre-flight error told a desktop user to send an HTTP request *(fixed)*

Verbatim from the Pre-Flight Validation dialog:

> No image output directory is configured. Captured frames cannot be saved. Configure
> **imageOutputPath** in Settings → File Output (or **PUT /api/settings**) before starting a
> sequence.

An internal field name and an HTTP verb, in a dialog on a desktop app. Neither is something the
reader can act on, and both invite them to think they are missing a step. The issue's own
`resolutionHint` already said the useful thing — "Configure an image save location in Settings →
File Output" — so the description now just states the consequence in plain terms. A sweep for other
`GET|POST|PUT /api/...` strings in user-visible copy found none; the remaining hits are doc comments.

## G5 — a target the app refuses to run calls itself "Ready" *(fixed)*

Same screen, at the same moment: the target card read

```
New Target
RA Not set    Dec Not set          <- amber, correct
Ready · 10 planned exposures · 10m  <- the status chip
```

…with the card's own red blocking-issue dot in the corner and pre-flight refusing the run with
"Target Coordinates Not Set". Three parts of one card, and the summary chip contradicted the other
two.

The chip is derived from the node's *execution* status, so everything that has not run yet lands on
the default arm and prints "Ready". That is the right word for a target that has not started and
could; it is the wrong word for one the app will refuse. It now reads **"Needs coordinates"** when
the same `targetCoordinatesUnset` predicate the coordinate row already uses says so.

Small, but it is the L46 family: a surface asserting a state the app has itself determined is false.

## G6 — with no observing location, the app tells the executor it is at 0°N 0°E *(P1 for an unattended night; fixed)*

The most consequential thing the GUI drive turned up, and it is invisible from the API.

The profile had **no observing location**, and the app said so in three places — "Set an observing
location for twilight times", "Set location in Settings" on the altitude chart, and the readiness
panel's "No observing location set". Then it started a run:

```
INFO Updating sequencer location: lat=Some(0.0), lon=Some(0.0)
INFO Trigger fired: Altitude Limit (altitude_limit) - NextTarget
WARN Trigger fired: Altitude Limit (altitude_limit) - action: NextTarget
   ... once per 60 s cooldown, for the whole run (6 firings observed)
```

`sequencerUpdateLocation` takes **non-nullable** doubles, so an unconfigured site cannot be expressed
as "unknown" — it is pushed as a real place in the Gulf of Guinea. Vega, the target I had entered,
sits below 30° from the equator at that hour, so the always-armed altitude trigger computed a
perfectly correct altitude for somewhere the telescope is not and voted `NextTarget`. With a single
target the run survived; **with more than one, every target would be skipped in turn**, and the run
report would say the sky was too low.

**The Rust side was already written for this** and never got the chance: it computes an altitude only
when RA, Dec, latitude *and* longitude are all present, returns `false` from the altitude condition
when altitude is unknown, and carries a one-shot *"altitude triggers are dead until location is
supplied"* warning. That warning never fired in the log — because Rust never saw the absence.

**Fix.** Withhold the push when no site is configured, using the same `!= 0.0` test
`_startNativeExecution` already applies to the higher-level `setLocation` two hundred lines earlier;
log a warning naming what stays inactive. The mid-run watcher gets the same guard, so *clearing* a
location cannot arm the trigger either.

**A note on the test, because the first version of it was worthless.** It passed with the fix
reverted. Two reasons, both worth remembering: the harness's settings provider is still loading
unless you `await appSettingsProvider.future`, so the push was skipped for an unrelated reason; and
`dart format` had reflowed the guard across three lines, so the string replacement I used to revert
it silently matched nothing and I was "testing" the unmodified file. The test now asserts the
settings are *loaded and zero* before starting, and with the guard genuinely removed it fails.

## The editor start path works — which is what made the headless gap a gap

The run I built in the GUI (Target → Take Exposures, 10 × 60 s, Vega) completed, and the bookkeeping
the headless path was missing all night is simply present here:

```
frames on disk        10
captured_images       10
imaging_sessions      id=1  "New Sequence"  total=10  successful=10  status=completed
sequence_runs         1
```

That is the positive result behind L29: `SequenceExecutor.start()` was always doing this correctly,
and the appliance's `load -> start` branch was the outlier. It now does the same things, and this run
is the reference the fix was matched against.

Also observed working, unprompted: the pre-flight refused an empty sequence and named why; the disk
check did real arithmetic ("You have 7.60 GB free; this run will consume ~0.04 GB; 7.56 GB will
remain"); the target-coordinates rule described the actual consequence ("would point the mount at
that spot in Pisces and record every frame under it as 'New Target'"); the toolbar locked
sequence-editing actions during the run and said so in their tooltips; and the Properties panel went
read-only while running.

## What this drive did not cover

Named plainly, because the drive was one session on one screen size:

* **Imaging, Guiding, Weather, Plan Tonight, Analytics** — navigated past, never operated.
* **Mobile and the web dashboard** — untouched today.
* **Windows** — the whole drive was Linux/softpipe. Rendering and native dialogs differ.
* **Resize, small windows, keyboard-only navigation** — one 1920×1200 window throughout.
* Onboarding steps 4–13, and the file-picker dialogs (I typed paths instead).
### G6 corroborated twice more by the session report

The report that auto-opened when the run finished carried, unprompted:

```
Warnings: Meridian flip for "New Target" was aborted after 0 attempt(s): ... target 'New Target'
          altitude is -4.7° which is below the minimum 10.0°. ... The mount was NOT flipped.
Mount / operations:  Trigger fires 12
```

Vega at **-4.7°** is Vega seen from the equator, and twelve trigger fires in a ten-minute run is the
60-second altitude cooldown firing throughout. So the Null Island location did not just arm the
altitude trigger — it also drove the meridian-flip decision, which refused a flip for a target that
was in fact high in the sky. Both are closed by the same fix.

Worth recording separately: the report's own arithmetic is exact. Wall clock 10m 3s, integration
10m 0s (10 × 60 s), downtime 3s, effective imaging 99.5% — 600/603 to the decimal — and frames
10/10 accepted with HFR 2.23 / FWHM 4.45 / 35 stars per frame.

## G3 continued — the sweep needed three passes, and the first two were wrong

Worth recording as method, not just result.

**Pass 1** — regex over `Semantics(...)` blocks containing `button: true` with no `enabled:` — found
5 sites. Fixed them, rebuilt, relaunched, and the Sequencer's `DISABLED` count went **15 → 11**.

**Pass 2** — widened the regex to any interactive role or handler — found 4 more, and then reported
zero remaining. That "zero" was false: the regex only balanced one level of nested parentheses, so
every `Semantics(` whose child was a deeply nested widget tree (which is most of them) fell outside
the match entirely. `sub_tab_button.dart` — the Nodes/Snippets/Queue tabs I could see flagged in the
live tree — was invisible to it.

**Pass 3** — a line-window scan instead: for each line containing `Semantics(`, look at the next 14
lines for a state/role flag and for `enabled:`. Found **18** more across 13 files, including
`nav_item.dart` (the app's primary navigation), `sub_tab_button.dart`, `pill_tab.dart`,
`status_pill.dart`, `skotiq_card.dart` and the mobile dashboard.

The bulk insertion then landed `enabled: true` inside three `MergeSemantics(...)` constructors, which
do not take it. The analyzer caught all three immediately — which is the argument for running it
after a mechanical edit rather than trusting the edit.

Measured, not asserted: the running app's `DISABLED` count on the onboarding screen went from 4 to
**0**, and the fix is what the relaunched build shows.

## G7 — every sequencer frame stored a NULL quality score, so grading graded a constant *(P1; fixed)*

The Analytics gallery, after the clean ten-frame run:

```
Captured Images:   Good: 0    Needs Review: 10    Poor: 0
every tile:        "65 score", HFR 2.2, badge NEEDS REVIEW
```

Ten frames from a healthy run, every one flagged for review and not one "Good". Reading the database
explains it:

```
sqlite> select hfr, star_count, quality_score, eccentricity from captured_images limit 1;
        2.2388   35   NULL   0.2296
```

**`quality_score` is NULL on every sequencer-captured frame.** `FrameQualityAssessmentService` opens
with `image.qualityScore ?? 75.0`, so the assessment was of the fallback constant, not of the frame;
penalties took 75 to 65, and 65 sits under the service's `advisoryScore < 70` line, which is why the
verdict was unanimous.

The asymmetry is the defect. `ImagingService`'s ad-hoc path (Imaging screen snapshot/loop) computes a
score and stores it. The **sequencer** path — every frame of every unattended night — passes `hfr`,
`starCount` and `eccentricity` to `insertSequenceFrame` and simply never passes `qualityScore`, even
though the DAO has taken that parameter all along.

**Worse than a wrong label.** A sharp frame and a soft one scored identically, so anything that ranks
or rejects on quality — stack frame selection, auto-reject, "best frame" — was ranking a constant.

**Fix.** One shared `computeFrameQualityScore` (new `frame_quality_score.dart`), used by both paths:
the sequencer now stamps a real score, and `ImagingService._calculateQualityScore` delegates to the
same function so they cannot drift apart again. A missing background/noise component — the sequencer
event carries neither — is *omitted and the weights renormalised*, not scored zero; counting an
unmeasured component as zero would punish every sequencer frame for a number nobody took, which is
the same mistake wearing a different hat. A frame with nothing measurable returns NaN and stores
NULL, so the service's fallback still applies where it honestly should.

Weights and bands are lifted verbatim from the existing implementation. **Deliberately not retuned**:
making the two paths agree is one change; deciding what "Good" ought to mean is a separate question,
and the pre-existing comment in `frame_quality_assessment_service.dart` — "observed on real captures
scoring 64-66 with healthy HFR (2.5px) and 200 stars" — says someone has already met the threshold
question on real data. That one is the owner's to settle.

Six tests, including the live-rig frame's own numbers and the discrimination property.

## G8 — the location path, proven end to end in the GUI

Setting latitude 39.9719 / longitude -75.3576 in Settings → Location, with nothing else touched:

| before | after |
|---|---|
| status bar `LST --:--:--` | `LST 20:46` |
| Weather: "Location Not Configured … configure your location in Settings" | (radar unblocked) |
| Plan Tonight: "Location not configured … before using the planner" | `AUTOPILOT WILL RUN — New Target — Live scheduler pick, what the rig would slew to next (score 3.63)`, plus a Night Outlook listing NGC7056 with altitude |

Three screens that were each honestly refusing to guess now compute. This is the other half of the
G6 story: the app is careful about an unset location everywhere a human can see, and the only place
that quietly substituted (0, 0) was the push into the executor.

## G9 — the planner's filter row is live and announces itself disabled *(fixed)*

With the planner working and returning scheduler picks, all six filters — Type, Constellation,
Magnitude, Size, Alt now, Moon — plus Sort still read `[DISABLED]` in the accessibility tree.
`_ControlChip` is another bare `InkWell`: focusable node, no isEnabled, and no on/off state anywhere
in the subtree, so a screen-reader user is told the filter row is dead and is never told which
filters are applied. Given a container `Semantics` with `button`, `enabled` and `selected: active`.

## G3 pass 4 — wrapping an InkWell in `Semantics` does not fix it, and I verified the first one wrong

Two corrections, both found by measuring the same screen before and after instead of a different one.

**The mis-verification.** I reported the onboarding driver rows as "4 → 0". That number came from the
landing screen *after a relaunch*, where the app had resumed past onboarding and was showing the
Continue Session dialog. I had counted a different screen. The driver rows were still broken.

**Why the fix did not work.** Wrapping a bare `InkWell` in a new `Semantics(...)` leaves the InkWell
publishing its **own** node — focusable, no `isEnabled` — alongside the wrapper. AT sees both, and
the flagged one is still there. Measured after a genuine rebuild+relaunch: Plan Tonight still 8,
Sequencer still 11, tabs still `[DISABLED]`.

The working pattern is `InkWell(excludeFromSemantics: true, …)` inside the wrapper, so the container
is the only node. That is different from the `AdaptiveTabBar` case, which already *had* a `Semantics`
node and only needed the `enabled` field — which is why pass 1 genuinely moved 15 → 11 and this did
not.

**Verified properly this time**, onboarding step 2 on a fresh profile:

```
before:  panel: Native
         Direct SDK connection where the release includes ... [DISABLED]

after:   check box: Native. Direct SDK connection where the release includes ... [ON]
         check box: Alpaca. ASCOM Alpaca over network ...                       [ON]
         check box: INDI. INDI protocol through a reachable INDI server ...     [ON]
         check box: Sim. Simulated device where that workflow is enabled ...    [off]
```

Role, label and state, all correct, zero `DISABLED` on the step. Plan Tonight went **8 → 2** by the
same change.

**Reverted as ineffective:** the `Semantics(enabled: true)` wrapper around the sequencer toolbox
`TabBar`. Flutter's own `Tab` publishes the "Tab N of 3" node from inside `TabBar`, and an ancestor
`Semantics` does not merge into it — the flag survived the rebuild. `TabBar` exposes no
`excludeFromSemantics`, so this is a framework limitation rather than something to paper over. Left
as a known remainder rather than a fix that fixes nothing.

**Known remainders**, all measured, none claimed fixed: the framework `Tab` nodes (3), the node-palette
category headers (5), `Sort: Score` on the planner, and a few status chips such as `0 connected`.

## Onboarding steps 2-8, walked on a fresh profile

Zero `DISABLED` on every step after the semantics fix, and the wizard behaved correctly at each
gate I tried to break:

* **Step 3 with no camera selected.** Six Next presses did nothing — which I initially read as an
  inert button. It is not: `_validate` returns *"Pick a camera to continue, or use 'Skip onboarding'
  to set it up later"* and the wizard renders it in a notice band above the footer, with a dismiss.
  Deliberately not a snackbar, per the comment at the call site: *"a snackbar covers and intercepts
  the very buttons the user needs to act on the message."* My misread, recorded because it is the
  second time on this drive that a screen looked broken and turned out to be right.
* **Driver status chips** on the camera step read `Native (0) ✓`, `Alpaca ⚠`, `INDI ⚠`, `Sim (1) ✓` —
  the two unreachable backends are marked rather than silently contributing nothing.
* **Step 8, optical train, with deliberately wrong input.** I mis-aimed and typed 1000 into Aperture
  and 200 into Reducer / Barlow. The form caught it: inline `Must be between 0.1 and 10.` under the
  reducer, and all three Computed values — Effective focal length, Focal ratio, Image scale — read
  **"Check your inputs"** instead of deriving a number from nonsense. The empty pixel-size field
  reads *"Not in the camera library — check your camera's datasheet"*.

That last one is the behaviour the rest of this report has been asking for, arrived at without
prompting: refuse to compute rather than compute something false.
## Phone-width reflow (420×900) — checked, clean

Resized the running window from 1920×1200 to 420×900 mid-wizard:

* the step sidebar collapses to a progress bar with "Step 8 of 13 — Optical train";
* fields stack full width, Next/Back stack vertically;
* no overflow, no clipping, no horizontal scroll, and the long placeholder ellipsises
  ("Not in the camera library — check your ca…") rather than spilling;
* the notice band and the "Check your inputs" computed values both survive the reflow.

One nit not raised as a finding: the inline `Must be between 0.1 and 10.` under the reducer is
transient — it is gone at both widths once the field loses focus, leaving the out-of-range value
committed. The form still refuses to compute and the notice band still names the missing focal
length, so the invalidity is surfaced; only the specific range hint is short-lived. Recorded rather
than claimed, because I did not establish whether that is focus-scoped by design.
## G10 — my own accessibility change broke a test, and my first count of the damage was wrong *(fixed)*

I reported "41 failures, all Windows-captured goldens" from a **partial** run. The completed suite
says **3,056 passed, 42 failed**, and classifying every one of the 42 by name:

* **41** are golden pixel diffs — `Pixel test failed, 13.39% / 21.41% / 75.00%` — the
  Windows-captured goldens that have never matched on Linux. Checked individually, including the
  three `imaging_landscape_capture` and three `planner_fold_cover` cases that did not look like
  goldens from their names but are.
* **1** was a real regression from today's work:
  `settings_sidebar_keyboard_test: sections and group headers announce themselves as buttons`.

`matchesSemantics` treats every flag you do not list as an assertion that it is **absent**, so by
omitting `hasEnabledState`/`isEnabled` the test was pinning the pre-fix behaviour — asserting that
the settings sidebar must NOT report an enabled state. That is precisely the defect: the whole
sidebar announced as insensitive. The expectation now requires the flags instead of forbidding them.

Two lessons, both about my own claims rather than the app:

1. **Do not classify a test run before it finishes.** The partial log was one failure short and I
   generalised from it.
2. **A semantics matcher is a whitelist.** Adding a correct flag will fail any `matchesSemantics`
   that did not anticipate it, and the failure looks like a regression when it is the test encoding
   the old behaviour. Read the diff before assuming either way.
## Analytics sub-tabs — all six walked, clean

Session, History, Projects, Equipment Stats, Science and Diagnostics on a fresh profile: **zero
`DISABLED`** on every one, and each renders its own honest empty state rather than a zero or a blank
panel — "Waiting for the first captured frame", "No session history", "No targets available for
project tracking yet", "No data", "Solve health appears once light frames start arriving", "No story
yet for this session — events appear as the Narrator interprets your data".

One near-miss worth recording as method: the tabs appeared to render **one tab behind** what I
clicked. Clicking the same tab twice returned identical content, which ruled out a lag — my
`click-xy` was landing one tab to the left the whole time. Third time on this drive that a suspected
defect was my measurement rather than the app.

## Known accessibility remainders — measured, root-caused, deliberately not "fixed"

After the sweep, these still read `[DISABLED]` in the live tree. Each was checked; none is guessed:

| nodes | widget | why it is left |
|---|---|---|
| `Tab 1/2/3 of 3` (Sequencer toolbox) | Flutter `TabBar` → `Tab` | the framework generates the node inside `TabBar`; an ancestor `Semantics` does not merge into it. Proven: my wrapper survived a rebuild with the flag intact, so it was reverted. `TabBar` exposes no `excludeFromSemantics`. |
| `Overlays`, `G100`, `Light`, `1x1` (Imaging) | `SkotiqDropdown` → Flutter `DropdownButton` | same shape — the button node comes from the framework. Fixable in principle by wrapping and excluding, but that is the pattern that needed three attempts to get right on `InkWell`, and I have no budget left to build, relaunch and verify it. An unverified accessibility fix is worth less than an accurate note. |
| node-palette category headers (`Target`, `Imaging`, `Science`, `Guiding`, `Mount`) | expansion headers | not yet traced to a widget. |
| `Sort: Score`, `0 connected`, `0 nodes`, `1` | status chips / sort control | not yet traced. |

The pattern to apply, established and verified on three widgets today: give the row a container
`Semantics` with `enabled`, and put `excludeFromSemantics: true` on the inner `InkWell` so it stops
publishing a second, unflagged node. Verify by counting the **same screen** before and after a
rebuild — not a different one.

## Final test position for this drive

`skotiq_app` re-run after the one real regression was fixed: **41 distinct failing tests, 40
distinct goldens named, zero non-golden failures** — classified by name rather than by eyeballing the
tail. Every remaining failure is a Windows-captured golden diffing on Linux.
## Open question, not a finding — Guiding "Connect" with no PHD2 running

The Guiding screen renders correctly with nothing attached: `PHD2 Disconnected`, `Stopped`, an empty
guide graph with `RA — Dec — Total —`, "Connect a guider to acquire a guide star", and a
`Not Calibrated` badge explaining "PHD2 will calibrate your mount automatically when you start
guiding." Start / Pause / Loop Exposures / Auto Select / Deselect / Brain Settings are all present.

Pressing **Connect** with no PHD2 process running produced no visible change and **no log line
whatsoever** — the log's last entry is an unrelated discovery sweep from seconds earlier, and the
whole session contains only five `guider|phd2` mentions.

That *looks* like a button that fails silently, which would matter on an unattended rig. I am not
recording it as a finding because I could not confirm the click landed: my `click-xy`/`click-img`
coordinates have been wrong three separate times on this drive, and one of those produced a
convincing phantom (the Analytics "tabs lag by one"). Establishing this needs a confirmed hit on the
button — a distinctive log line, or a state change from a control adjacent to it — and I ran out of
budget before I could get one.

Left as the first thing to settle on the next drive, with the method: click, then prove the click
landed before interpreting the absence of a reaction.
### RESOLVED — the Guiding Connect question was my observation window, not the app

Settled by proving the click landed (the Brain Settings toggle responds to the same technique and the
button is exactly at the coordinate I used) and then reading the tree **immediately** instead of ten
seconds later:

> PHD2 connection failed: PHD2 is not running and could not be launched automatically. Install PHD2
> or set Settings → PHD2 Guiding → PHD2 executable path.

Specific, actionable, and it names the exact setting to change. My earlier "no visible change" was a
snackbar that had auto-dismissed before I looked. **Fifth** time on this drive that a suspected
defect was my measurement.

One genuine residual, much smaller than the thing I suspected: the failure leaves **no log line**.
The snackbar is the only trace, so on an unattended rig — or for anyone who looks away for four
seconds — a failed guider connect is forensically invisible afterwards. Worth a `logger.warning` in
`connectPhd2`'s catch; recorded rather than changed, because I cannot rebuild and re-verify within
budget and a one-line unverified change is how the last three regressions started.
## G11 — the Settings switches expose no on/off state *(measured; cause narrowed, not fixed)*

```
Settings → General:   toggle button: Start minimized          (no state)
                      toggle button: Auto-connect equipment   (no state)
                      toggle button: Confirm before closing   (no state)

Imaging:              toggle button: Stretch            [off]
```

The screenshot shows those three in genuinely different positions — Start minimized off,
Auto-connect on, Confirm before closing on — so a screen-reader user is told there are three switches
and never which way any of them points. "Auto-connect equipment" in particular decides whether a rig
grabs its hardware on launch.

`SkotiqSwitch` itself is correct — `Semantics(toggled: value, enabled: isEnabled, onTap:)`, with
a comment saying "the enclosing row supplies the accessible label; this node supplies the switch
state". And the identical component on the Imaging screen *does* publish `[off]`. So the state is
being lost between the switch and the tree on this surface only, and the settings rows are wrapped in
`MergeSemantics` — the first place to look.

Not fixed. Every semantics change today needed a rebuild and a same-screen re-measure to tell a fix
from a no-op, twice I got that wrong, and I do not have the budget left to do it properly. A narrowed
cause someone can act on beats a fourth unverified attempt.
## Imaging sub-tabs — all seven opened, clean

Capture, Camera, Focus, Guiding, Mount, Rotator, Stack and Annotations each render their own panel
with no blank states and no crashes: "Snapshot / Loop" controls, "Session / Captured", "Correction
settings / Auto-apply when map exists", and the honest "Connect a mount to send guide corrections."
where hardware is absent. The only `DISABLED` nodes on any of them are the four framework dropdowns
already tabled above (two on the tabs that carry no frame-type/binning control).

Recorded without naming which tab showed what: my `click-xy` label mapping was off again — sixth time
this drive — and the tabs' content clearly rotated relative to the names I assigned. What is
established is that all seven switch, all seven render distinct content, and none is empty or broken.
## Web dashboard — served and accessible-clean at the markup level

`GET /dashboard` on the appliance returns 80 KB of HTML, `<title>Skotiq Dashboard</title>`, with
**113 buttons and 263 `aria-*` attributes**. Parsing every `<button>` for an accessible name — an
`aria-label`, a `title`, or visible text content — gives **zero with no name at all**. The 14 that
carry no `aria-label` all have text content, which is the correct way to name a button.

The CSP is also tightened deliberately, with the reasoning in a comment at the top: `connect-src`
restricted to same origin plus same-origin WebSockets, replacing a `http://*:*` wildcard that "would
allow an attacker-controlled page served from the dashboard origin to relay credentials".

This is a markup-level check only — it says the buttons are nameable, not that the dashboard behaves.
Driving it needs a browser session, which is the same gap as mobile and Windows.

Auth on that surface behaves: `GET /api/sessions` with no token is **401**, and with the bearer token
`/api/sequencer/status`, `/api/system/disk-space`, `/api/sessions` and `/api/images?limit=5` all
return **200**.
### G11 root cause — the merge that bound the name dropped the state

`SettingRow` wraps every row in `MergeSemantics`, and the comment above it records exactly why:

> Without this the switch is a correctly-toggled but ANONYMOUS node: measured on the running app,
> Settings > General exposed three toggle buttons reading "off/ON/ON" with empty names, so assistive
> technology could report that something was on without being able to say which setting it was.

So the surface has been through both failure modes. **Before** the merge: state without a name
(`toggle button: [off]`, `[ON]`, `[ON]`). **After** the merge, which is what I measured today: name
without state (`toggle button: Start minimized`, no `[ON]`/`[off]`). The same component unmerged, on
the Imaging screen, still publishes `[off]` — which is what isolates the merge as the cause.

That is this campaign's recurring shape — a fix that relocates the untruth rather than removing it —
and it is worth naming as such rather than as a second independent bug.

**Why it cannot be fixed inside `SettingRow`:** the row receives `trailing` as an opaque `Widget`, so
it has no way to restate `toggled:` on the merged node. The two honest options are to give
`SettingRow` the value (a `bool? toggledState` alongside `trailing`), or to move the label into
`SettingsSwitch` so one node carries both and no merge is needed. Either is a small change with a
clear before/after test — `matchesSemantics(label: 'Start minimized', isToggled: ..., hasToggledState: true)`
would fail today and pass after.

Not attempted here: it needs the build-and-remeasure loop, and today has already shown twice that a
semantics change without that loop is indistinguishable from a no-op.
### G11 WITHDRAWN — the widget layer is correct; this was my instrument again

I wrote a root cause above blaming `MergeSemantics` for trading the state away. That was wrong, and a
widget test settles it. Pumping a real `SettingRow` with a `SkotiqSwitch(value: true)` and reading
the merged node:

```
flags: [hasEnabledState, isEnabled, hasToggledState, isToggled]
label: "Start minimized\nLaunch app minimized to system tray"
```

Both halves are present. The merge binds the label **and keeps the toggled state**; the earlier fix
did not relocate anything. What I measured in the accessibility tree — a `toggle button` with a name
and no `[ON]`/`[off]` — is therefore lost between Flutter's semantics and what the audit harness reads
over AT-SPI, not inside the app.

**Sixth measurement-caused false lead of this drive**, and the one I had gone furthest with: I had
already written a cause, an explanation of why it could not be fixed in `SettingRow`, and two
suggested designs. All of it was reasoning on top of a bad reading.

The test is kept as a regression guard
(`setting_row_toggle_semantics_test.dart`) — if a future change to `SettingRow` or `SkotiqSwitch`
drops either the label or the state, it fails at the widget layer where it is cheap to see, instead
of in an accessibility tree nobody reads.

**Consequence for the rest of this report:** every `[DISABLED]` and missing-state reading in the
remainders table is a harness observation, and at least one class of them has now been shown not to
reflect the widget layer. The fixes I landed are still right — each was verified by a same-screen
before/after in the tree AND by the semantics changing in code — but the *unfixed* remainders should
be re-checked with a widget test before anyone spends time on them.

### The fixes hold at the widget layer too

Having found the harness wrong once, the honest follow-through is to check the fixes with a second
instrument rather than trust the first. `driver_tile_semantics_test.dart` pumps the real onboarding
screen, walks to the driver step and reads the row's node directly: the label contains **both**
"Native" and "Direct SDK connection…", i.e. the container carries the accessible name and the inner
content is excluded, exactly as the fix intends. Passes.

So the position is: the landed fixes are real at both layers; the *unfixed* remainders rest on
harness readings alone and should get a widget test before anyone acts on them.

## G12 — WITHDRAWN: the Tonight primary action is correctly disabled

With no observing location configured, the Tonight screen's primary action "Image this target
tonight" rendered dimmed, did nothing when clicked, and appeared in the accessibility tree with no
disabled marker — while the same tree printed `Sort: Score [DISABLED]` for another control. That
looked like a design-system defect affecting every disabled `SkotiqButton` in the app.

The click technique was verified first, per the standing rule: clicking the sibling "Advanced: full
planner & sequencer" at the same coordinates navigated to Plan Tonight, so the press genuinely
landed on an inert control.

It is not a defect. `SkotiqButton` already wraps itself in `Semantics(button: true,
enabled: !isDisabled, label: …)`, and a widget test proves the published node carries
`hasEnabledState` and *not* `isEnabled` when `onPressed` is null — with the enabled case asserted
alongside so the test cannot pass by the flag never being set either way. The AT-SPI tree simply
does not annotate that node. Second false accessibility finding from the harness this session
(see G11); the rule that settled both is the same — the tree finds candidates, a widget test
confirms them.

The behaviour is also right as UX: the button sits directly beneath a "Location not configured"
card that explains the reason and offers "Open Settings", so the disabled state is neither silent
nor unexplained.

Kept `skotiq_button_disabled_semantics_test.dart` as regression cover, since the design system
had no test pinning a property the whole app depends on.

## V1 — full unattended spine driven through the GUI, end to end (validation, not a defect)

Everything below was done by clicking the desktop app, not by calling the API, and every number was
checked against an independent source rather than against another part of the app.

**Setup, in the GUI.** Settings → Location, typed 42.35 / -71.06. Persisted (`observer_latitude`,
`observer_longitude`) and propagated: the status bar LST went from `--:--` to `23:00`, which matches
an independent Meeus GMST computation for that longitude at the machine's UTC to the minute
(23:00:26).

**Pre-flight refuses what it should.** Start on an empty sequence produced "Cannot Start Sequence /
Please fix 1 error(s)" — *"The sequence has no runnable instructions"* — plus a simulation panel and
a dark-window warning. Adding one Take Exposures node moved it to "Ready with Warnings" with a
precise complaint: *"Exposures exist but no target is defined. The mount will image at its current
position."* The proceed button is honestly labelled **Start Anyway**.

**The run guards itself.** Starting with the mount parked stopped the run with "Mount is Parked" and
offered *Unpark Now* / *Cancel Sequence* rather than exposing through a parked mount.

**Ten frames, and every claim about them is true.**

| claim | where the app says it | independently verified |
|---|---|---|
| 10 frames | header, Analytics | 10 FITS + 10 thumbnails on disk, 10 `captured_images` rows |
| integration 20s | Analytics | 10 × 2s configured |
| median HFR 6.72 | Analytics | median of the 10 stored HFRs = 6.7215 |
| p90 6.763, range 6.665–6.770 | Analytics | matches the rows exactly |
| EXPTIME 2.0 | FITS header | the value set in the builder — this keyword used to be pinned at 1.0 |
| SITELAT/SITELONG | FITS header | 42.35 / -71.06, the coordinates typed into Settings minutes earlier |
| OBJCTALT 45.73°, AIRMASS 1.3948 | FITS header | independent alt 45.57° (difference is refraction, correct sign); Kasten-Young airmass 1.3987 |

**G7 confirmed on the real sequencer path.** All 10 rows carry a `quality_score` where the sequencer
used to write NULL, the values *vary per frame* (32.35–33.0) instead of being one constant, and
recomputing the weighting independently from each row's HFR and star count reproduces every stored
score to the second decimal.

**The app declines to invent data it does not have.** With the guider disconnected the whole run,
the Guiding panel reads "No guiding RMS recorded for these frames" rather than drawing a chart.
Focus drift shows a true flat 25000–25000 and sensor temperature a true 20.00–20.00, because neither
moved. The frames are named `untargeted_L_0001.fits`, which is what they are. A note above the
charts states "All four charts plot the same 10 accepted light frames."

One correction worth recording: I first read the accessibility tree as showing 6.700–6.800 under
"RMS (arcsec)" and suspected the guiding chart was plotting HFR. It was not — those were the HFR
chart's y-axis labels, adjacent in tree order. The screenshot settled it. Same lesson as G11 and
G12: the tree finds candidates, a second instrument confirms them.

## V2 — pause, resume and abort, driven in the GUI (validation)

The two live-found blockers in this area were "Pause keeps exposing" and L46 "every paused run
reports itself as running". Both were re-tested by clicking, not by reading state.

**Pause actually stops the camera.** Paused at 3/10 with an 8s exposure and waited 30 seconds —
room for roughly four more frames. `captured_images` stayed at 13 and the FITS count on disk stayed
at 13, while the UI held at "Paused · 3 / 10 frames". A pause that only relabels the state would
have accrued frames here.

**The state is reported as paused everywhere that matters.** The run header, the status bar and the
frame counter all read Paused, and the primary control became Resume. The only remaining occurrence
of the word "running" is the tooltip on the locked toolbar buttons — "locked while sequence is
running" — which explains why they are disabled. A paused run is still an in-progress run, so that
is fair rather than false; noted, not changed.

**Resume continues from where it stopped**, 3/10 → 4/10 with rows advancing again.

**Abort produces a truthful session report**, and every figure in it is arithmetically consistent
with the run I had just driven:

| reported | value | check |
|---|---|---|
| outcome | `paused-stopped` | it was paused, then stopped — both, not one |
| wall clock | 2m 0s | 02:36 → 02:38 |
| integration | 40s | 5 frames × 8s |
| effective imaging | 33.3% | 40 / 120 |
| downtime | 1m 20s | 120 − 40, i.e. my 30s pause plus overheads |
| frames accepted | 5/5, 0 rejected | 5 new rows and 5 new FITS on disk |
| autofocus / flips / dithers / trigger fires | 0, 0, 0, 0 | none were configured |
| guiding | "No guide data recorded for this session." | the guider was disconnected throughout |
| targets | "Untargeted" | no target node existed |

Across both runs the totals reconcile exactly: 15 `captured_images` rows and 15 FITS files on disk.

## G13 — the Imaging Session card counted sequencer frames but not their integration *(P2, fixed)*

Observed on the Imaging screen after a completed ten-frame sequencer run at 8s:

```
Session
  Captured     10 frames
  Integration  0s
```

Taking one 2-second Snapshot on that screen moved it to **11 frames / 2s**. Eleven frames cannot
total two seconds at any exposure, which is what made this checkable rather than merely odd.

The card already carried a comment saying its two lines "must come from the SAME record or they can
contradict each other" — from an earlier fix for this same contradiction. That fix only covered the
branch where a database session row is open. In the fallback branch the count came from
`recentSessionFramesProvider`, which holds every frame captured in this app run *including the
sequencer's*, while the integration still came from `sessionState`, which only accumulates captures
the Imaging screen itself performed. Two sources, one card.

The stored rows were never wrong — `imaging_sessions` held `10 / 80.0`, `5 / 40.0`, `10 / 20.0`,
each internally consistent. Only the live card disagreed with itself.

Fixed by deriving both lines from the same list in the fallback, summing `settings.exposureTime`
over exactly the frames being counted. Verified in the running app on a fresh ten-frame run at 8s:
the card now reads **Captured 10 frames / Integration 1m 20s**.

Distinct from L50 despite the identical symptom: L50 was the Rust executor's counter feeding the
checkpoint, this is a Dart-side display picking two different sources. Finding the second one only
because the first had trained me to check frames against integration is worth noting.

## V3 — the dawn safety trigger fires at the right time (validation)

`Dawn Approaching` is defined as `minutes_before: 30.0` against astronomical twilight, with
`RecoveryAction::ParkAndAbort` and no cooldown. On 2026-08-10 it fired at **03:31 local** for the
site 42.35 / -71.06.

Checked against an independent solar-position computation rather than against the app's own twilight
display: the sun reaches -18° at **03:57 local** at that site on that date, so a 30-minute lead puts
the correct firing time at **03:27**. The observed 03:31 is four minutes later, inside the trigger's
polling interval.

Worth recording because an earlier reading of "astro dawn 04:24" from the dashboard looked like a
53-minute overshoot. That figure was captured *before* the observing location was set, so it
described nowhere in particular. The comparison only became meaningful once both sides referred to
the same site — the same trap as measuring a fix against a stale binary.

The behaviour itself is what an unattended night wants: the rig parks and the run ends roughly half
an hour before the sky starts brightening. What it does not do is say so afterwards — see L52.

## V4 — weather safety defaults are correct for a rig with no weather sensor (validation)

The 6.0.0 blocker was a fail-closed weather gate that aborted every run on a rig with no weather
device. The current settings page resolves it without weakening the safety model:

| setting | value | disclosure on the row |
|---|---|---|
| Enable weather safety | **off** | "Pause imaging when unsafe weather is detected" |
| Safety fail mode | Fail Closed (Park) | "…missing data counts as unsafe: a run will refuse to start and the rig is parked" |
| Auto-park mount | on | *"inactive until 'Enable weather safety' is on"* |
| Auto-resume after clear | off | *"inactive until 'Enable weather safety' is on"* |
| Max humidity / wind / cloud | 90% / 30 km/h / 80% | — |

The important part is the last column: every setting that only takes effect under the master toggle
says so on its own row. A user reading "Fail Closed (Park)" in isolation would reasonably conclude
their run is about to be blocked; the row tells them it is not. That is the same fact the Weather
screen states as "Not monitoring — weather safety is off", so the two surfaces agree.

For a rig with no weather sensor — which is the owner's case tonight — this means the fail-closed
mode is armed but inert, and a run will start.

## V5 — the Analytics tabs report figures that reconcile with the database

Swept all six. Every displayed number was checked against SQL rather than against another screen:

- **Equipment Stats** — "Accepted Integration 3m 42s" = 222s = `sum(exposure_duration)` over
  `captured_images` exactly; "Avg HFR Achieved 4.95" = `avg(hfr)` = 4.954. Note it is 222s, not the
  220s total of the run records: the 2s difference is a single Imaging-screen snapshot, a frame with
  `session_id IS NULL` that belongs to no run. Right number for the right reason.
- **History** — per-run HFR 4.35 / 4.33 / 4.33 matches `avg(hfr)` grouped by session (4.355, 4.328,
  4.328), and the three trigger-aborted runs correctly show 0 frames.
- **Science** — "No events yet this session", "No story yet for this session"; honest empty states.
- **Session** — verified earlier in V1.

The History time filter also works end to end (All Time → This Month, label updates, all seven
sessions correctly retained since all are from this month). Its `[DISABLED]` marker in the
accessibility tree was spurious — the **third** false disabled-state reading from that harness this
session, after G11 and G12. Treat `[DISABLED]` from `drive_linux.py tree` as unreliable.

## V6 — Settings sweep: 20 leaves opened, search deep-links, no defects found

Walked every Settings leaf reachable from the sidebar. All navigate and render real content; nothing
claimed a state it did not have.

**GENERAL** — General (startup/behaviour), Appearance (theme), Location (verified in V1),
Files & Storage (file paths, application data), Help & Tutorials (guided flows), About.
About reports **"Version 6.1.0 (build 25)"**, which matches `version: 6.1.0+25` in the manifest.

**EQUIPMENT** — Connection (server/connection status, discovery), Equipment Profiles, PHD2 Guiding,
Plate Solving, Autofocus, Calibration, Dark Library.

- *Plate Solving* does real work rather than asserting: "ASTAP detected" names the exact path it
  found, and **Verify** executes the binary — its reported
  `ASTAP astrometric solver version CLI-2026.07.16` matches the binary's own `--help` output
  byte-for-byte. (`which astap` finds nothing because the install is not on PATH, which is why the
  app naming the path matters.)
- *Dark Library* reports 0 dark / 0 bias / 0 master / 0 total, agreeing with the Equipment screen's
  readiness note "No matching dark frames for your current camera settings". Two surfaces, one
  answer.
- *Autofocus* is fully specified — method, curve fit, step size, backlash, per-filter offsets, an
  R² floor of 0.7, and "Number of attempts: 1 (retry count on failure)". It has **no setting for
  what to do once those attempts are exhausted**, which is the open product question; confirmed by
  inspection rather than assumed.

**IMAGING** — Imaging, Adaptive Exposure, Image Grading, Calibration Library, Annotations, Catalogs.

**AUTOMATION & SAFETY** — Sequencer, Pre-flight Checks, Weather Safety (V4), Adaptive Conditions.
The Sequencer leaf's *Meridian Flip* block is complete for unattended use: trigger method, 5 minutes
past meridian, pause guiding → flip → **plate-solve recenter** → resume guiding, 10s settle, and
**Max retries 3 "if flip fails"**. Worth contrasting with autofocus: the flip has a defined
post-failure behaviour and autofocus does not.

**Settings search works and deep-links.** Typing "meridian" returned results grouped by owning
section — `Sequencer → Meridian Flip / Minutes past meridian`, `Notifications → Meridian flip /
Push on meridian flip events` — and clicking a result navigated straight to that setting.

Harness note: resizing the window beyond the Xvfb display (1920x1200) leaves a black window that does
not recover on resizing back. That is misuse of the harness rather than an app finding — a restart
clears it — but it is worth knowing before reading a blank screenshot as a rendering defect.

## V7 — Sequencer and Plan Tonight tabs (validation)

**Sequencer** — *Templates* offers Beginner / Intermediate / Advanced / Specialized with starters
such as "DSLR M31 (Andromeda) — Lights + Flats + Bias". *Sequences* lists the saved library.
*Execution History* groups runs by observing night with status filter chips and a search box.

One cross-surface note: Execution History files the runs of 2026-08-10 02:31–03:42 under
**"Sunday, Aug 9, 2026"**, while Analytics → History labels the same runs "Aug 10, 2026 02:31". Both
are defensible — one groups by the night that began on the 9th, which is the astronomically useful
convention, the other prints the wall-clock timestamp — but the two "history" views answer the same
question with different dates. Recorded as an observation, not a defect; the astronomical grouping is
arguably the better one and worth keeping.

**Plan Tonight** — *Recommendation* produces a real night outlook once a location exists (NGC7063,
an open cluster in Cygnus, is a sane August pick at 42°N) and states "Setup needed for live TNS
alerts" rather than pretending to have them. *Projects* shows an honest "No projects yet" with an
explanation. *Schedule* lays out the week ahead. *Framing* exposes labels, guide stars and HiPS
tiles.

With this, every top-level screen, every Analytics tab, every Sequencer tab, every Plan Tonight tab
and every Settings leaf reachable from the sidebar has been opened and read.

## V8 — plate solving works end to end against simulated frames (validation)

The simulated camera renders the *real* sky, and a real solver confirms it. Captured a frame through
the Imaging screen with the profile set to 414 mm (a 1.03° × 0.58° field, comparable to a real rig)
and solved it with the installed ASTAP:

```
263 stars, 194 quads selected in the image
Solution found: 00: 00 00.1  +00d 00 01
Solved in 0.7 sec.  Δ was 1.3".  Mount Δα=-0.9", Δδ=-0.9".
Used stars down to magnitude: 16.8
Plate scale from solution: 1.873"/px
```

Three independent things agree:

1. The solved position is **RA 00h00m00.1s, Dec +00°00′01″**, and the frame's header claimed RA 0 /
   Dec 0 — agreement to **1.3 arcseconds**.
2. The recovered plate scale of 1.873″/px equals `206.265 × 3.76 / 414` computed from the optical
   train, exactly.
3. `OBJCTALT 45.16°` in the header matches an independent altitude calculation for Dec 0 at that
   site and sidereal time (45.6°).

So the sim is not painting decorative stars — it is painting the catalogue sky at the coordinates it
claims, well enough for a real astrometric solver to recover the pointing to under two arcseconds.
That makes centering, framing and recenter-after-flip testable without hardware.

**Two false alarms of my own, recorded because both were nearly written up as defects.**

*First:* the default simulator profile (1000 mm, 1920×1080, 3.76 µm) gives a **0.414° × 0.233°**
field, and ASTAP fails on it — "37 stars … 79 database stars, 253 database quads required". That is
a genuine limitation of the **D05** catalog at very narrow fields, not a fault in the sim or the app.
It is also why plate solving cannot be exercised with the *default* sim profile; widening the field
is the fix for the test, not for the product.

*Second:* I then chased whether the owner's rig had the same problem, since their ASTAP install also
carries only D05 (1476 `.1476` files, zero `.290`). It does not — their 10″ NEWT at 1016 mm gives
**1.00° × 0.75°** with an ASI1600, comfortably within D05's range. No action needed there, and no
alarm was raised on the strength of the intermediate result.

*Third, and the actual cause of the failed solves:* ASTAP's `-fov` expects the field **height**, and
I was passing the **width** (1.03 instead of 0.56). The scale hint was nearly 2× off. Auto-FOV
(`-fov 0`) found it in 0.7 seconds. A wrong hint and a broken solver look identical from the outside.

## V9 — autofocus runs and measurably improves focus (validation)

Ran a real autofocus from the Imaging screen's Focus panel against the simulated focuser and camera.
The app's own log:

```
Starting autofocus: Hyperbolic method, 4 steps, step size 50
[SEQ] Autofocus point 1..9 sample 1/1 completed: 1920x1080 (2073600 pixels)
Best focus at position 25075, HFR: 2.78, R²: 0.953
```

Everything checks:

- **Nine sample points** for a "Steps Out 4" setting — four either side plus the centre — each one a
  real 1920×1080 capture, not a synthetic curve.
- **R² 0.953** clears the 0.7 minimum-curve-quality floor configured in Settings → Autofocus, so the
  fit was legitimately accepted.
- The chosen position **25075** is not on the 50-step sample grid (25000 ± 50/100/150/200), which is
  what an interpolated hyperbolic minimum should look like, and the Manual Focus readout moved to
  match.
- A `focus_models` row was persisted for temperature compensation.

**And it actually focused**, which is the part a log line alone cannot establish. Capturing a frame
at the same 2-second exposure before and after:

| | before (focuser 25000) | after (focuser 25075) |
|---|---|---|
| HFR | 6.042 (mean of 12 frames) | **1.942** |
| stars detected | ~37–40 | **249** |
| quality score | ~32 | **88.85** |

3.1× sharper and six times as many stars — the simulated optics respond to focuser position the way
real ones do, so the whole autofocus path is exercisable without hardware.

Incidentally this also exercises the G7 quality-score fix at the opposite end of its range: 88.85 for
a sharp frame against ~32 for a soft one, from the same formula. The score discriminates.

## G14 — a failed autofocus leaves its progress panel showing "Measuring point 1/9" forever *(P2)*

Reproduced with fault injection (`SKOTIQ_SIM_FAULTS='focuser.move=after(3):error'`), which lets
the focuser move three times and then refuse — the shape of a focuser that dies partway through a
sweep.

What the app does correctly:

- It aborts the sweep rather than continuing with a stuck focuser.
- It **tries to put the focuser back** where it found it, which is the right instinct.
- When that restore is also refused it says so at ERROR with the whole causal chain:
  `Autofocus could not restore original position 25000: return move to 25000 was rejected: Focuser
  move failed: Operation failed: …`
- The Manual Focus readout honestly shows the focuser's real position afterwards — **24800**,
  displaced 200 steps and unrecoverable.

What it does not do is stop showing progress. Forty seconds after the run died — with no further log
activity, against ~5s per sample — the panel still reads:

```
Point 1/9    HFR 5.10    Best 5.10    Stars 38
Measuring point 1/9
```

with the spinner still turning on the focuser position. The only failure signal is a toast reading
**"AF: Failed: Operation …"**, truncated before it names a cause and dismissable.

For someone checking a rig remotely on an unattended night this is the wrong story in the worst
place: an autofocus that appears to be still working, when in fact it died and left the optics 200
steps off focus. Every subsequent frame would be soft, and the panel would keep saying "Measuring".

Narrowed since (code read only, NOT verified live): `AutofocusOverlayNotifier.onAutofocusFailed`
already exists and already sets `isRunning: false, hasError: true, isMinimized: true`, and
`autofocus_controls.dart` does call it on the catch path — which is where the "AF: Failed" toast
came from. So the stuck "Measuring point 1/9" is very unlikely to be that overlay; it is more
likely the sequencer's node-progress panel, fed by `ProgressDetail::Autofocus { step, total_steps,
current_hfr }`, which keeps its last frame because no terminal Autofocus progress event is emitted
on the abort path. Whoever picks this up should confirm which of the two widgets is on screen
before changing either.

Two things would fix it: clear the progress panel to a terminal state on abort, and let the toast
name the cause — "Autofocus failed: focuser move rejected; focus left at 24800" fits and is
actionable, where "Operation …" is not. Not fixed here; it is a UI-state change on the same path as
the toast, and it wants a widget test rather than another unverified attempt at this depth.

**Bearing on the open product question.** The owner still has to choose whether a failed autofocus
trigger pauses an unattended run or lets it continue. This finding sharpens the choice: whichever is
picked, the failure must also be *visible*, because today a failed autofocus is quiet on screen and
leaves the focuser displaced. Continuing without surfacing that means a night of soft frames with the
UI still claiming to be measuring.

## V10 — polar alignment runs the real pipeline and fails correctly (validation)

Started Three-Point Polar Alignment from Equipment → Polar Alignment. The screen itself is careful:
four numbered prerequisites, a hemisphere toggle, an exposure slider, and a bullseye with 30″/60″/120″
error rings whose Azimuth / Altitude / Total readouts show `--` rather than zeros before anything is
measured.

It drives the genuine pipeline:

```
Starting polar alignment (gen 1): exposure=5s, step=15°, binning=2, north=true, manual=false, east=true
Polar alignment: Capturing point 1/3...       (phase=measuring, point=1)
Polar alignment: Plate solving point 1/3...
Blind plate solving: /tmp/polar_align_point_1_….fits
Running ASTAP: astap_cli -f … -z 2 -d <catalog dir> -wcs
```

— a real capture, a real blind solve, and a correctly-formed ASTAP invocation with downsampling, the
catalogue directory and WCS output requested.

The solve then failed, for the environment reason established in V8: the default simulator profile's
0.414° field is below what the D05 catalogue can solve. What matters is the handling, and it is
right:

```
ERROR Polar alignment failed: Plate solve timed out after 30.0 seconds for point 1
INFO  Polar alignment: Error: Plate solve timed out after 30.0 seconds for point 1 (phase=error, point=0)
```

The wait is **bounded** (30s, no indefinite hang), the run moves to an explicit `phase=error`, and
the screen shows **"Error Occurred"** with the full reason — "Plate solve timed out after 30.0
seconds for point 1" — in the UI, not only in the log.

**This sharpens G14.** Polar alignment and autofocus fail in the same family of ways, but only one of
them tells the operator. Polar alignment reaches a terminal error state and names the cause on
screen; autofocus leaves "Measuring point 1/9" on display indefinitely with a truncated toast. So the
app already contains the pattern G14 needs — the autofocus panel is inconsistent with its sibling
wizard rather than missing a capability that has to be invented.

## V11 — the Flat Wizard converges on exposure and hits its ADU target (validation)

Ran the wizard end to end from Equipment → Flat Wizard.

**It checks the flats against the lights before capturing anything.** The panel warned, in its own
words: *"These flats will not match your light frames (offset 10 vs 50). Flats are taken at the same
gain, offset and binning."* That is a specific, correct calibration check — flats shot at a different
offset from the lights are useless — and it names the exact mismatch rather than warning in general.

**It refuses to capture without a destination.** "Save Location Required — Choose where to save your
flat frames", with "Create date subfolder automatically" and "Create filter subfolders" both offered.
Both were honoured exactly:

```
/tmp/ns-audit/flats/2026-08-10/R/Flat_R_20260810_045923_1.fits
/tmp/ns-audit/flats/2026-08-10/R/Flat_R_20260810_045931_2.fits
```

**And the exposure solve is real.** Target ~32768 ADU on a 16-bit sensor, tolerance ±10%. Measuring
the written pixel data directly:

| | value |
|---|---|
| solved exposure | **7.8633 s** |
| mean ADU achieved | **32584** |
| error against target | **0.56% low** — well inside ±10% |

The exposure is a computed, non-round number, and the resulting level lands within a percent of the
requested one, so the wizard genuinely converges rather than shooting a fixed guess.

Together with V8–V10 this closes the imaging-support features that can be exercised without hardware:
plate solving, autofocus, polar alignment and flat capture all run their real pipelines against the
simulators, and three of the four fail correctly when broken on purpose. The exception remains G14.

## V12 — the daylight gate refuses on-sky frames, correctly and with a precise message (validation)

Building a sequence with a Dither node and running it at 05:04 local produced an immediate, honest
refusal rather than a night of useless frames:

```
ERROR Exposure failed: Daylight gate: refusing light-frame exposure — Sun altitude -7.7° is above
the maximum -12.0° for on-sky light imaging. Daytime flats/darks/bias and a parked rig are
unaffected; this blocks only on-sky science captures.
```

The number is right. Computing the sun's altitude independently for 42.35 / -71.06 at 09:04:56Z
gives **-7.7°** — an exact match to the precision reported. Astronomical dawn at that site was 03:57
(V3), so by 05:04 the sky is in nautical twilight and light frames would be worthless.

The message is unusually good for a refusal: it gives the measured value, the threshold it violated,
and — the part that matters — the precise *scope* of the block. "Daytime flats/darks/bias and a
parked rig are unaffected" tells an operator immediately that their calibration workflow still works
and nothing is wedged.

Two useful facts fell out of the same run. The sequencer pushes its trigger configuration at start,
and the meridian-flip block reads:

```
method=MinutesPastMeridian, minutes_past=5.0, auto_center=true, refocus=false,
pause_guiding=true, resume_guiding=true, max_retries=3, failure_action=PauseAndAlert
```

So **the meridian flip has an explicit `failure_action`** — `PauseAndAlert`. That is exactly the
setting autofocus does not have, which is the open product question, and it shows the concept already
exists in the sequencer's vocabulary.

**Honest limit on dither, live stacking and meridian-flip execution.** All three need a running
on-sky sequence, and the app is now correctly refusing on-sky captures at this site and time. They
are blocked by the daylight gate doing its job, not by anything untested about them — exercising
them means moving the simulated site into darkness, which is a legitimate technique and simply where
this session ran out of room.

## V13 / G15 — dither runs, fails precisely without a guider, and takes the whole run down with it

Relocated the simulated observing site to longitude -135° so the sun sat 32° below the horizon —
the daylight gate of V12 correctly refuses on-sky frames otherwise — and ran a two-node sequence:
Take Exposures ×10, then Dither.

**Dither itself behaves well.** It executes, reports its parameters, and names the exact reason it
cannot proceed:

```
Executing child 2/2: 'Dither'
Dithering 2 pixels (random)
Dithering 2 pixels (settle: <1.5px in 30s)
ERROR Dither failed: Dither failed: No active guider configured
Child 'Dither' completed with status: Failure
```

"No active guider configured" is the right message — dithering is a guider operation, and the guider
was disconnected throughout.

**What is questionable is the run's verdict.** The stored record:

```
status            failed
framesCaptured    10
ditherCount       0
errorMessages     ["Dither: Dither failed: No active guider configured"]
```

Every requested light frame was captured — 10 of 10, on disk — and the run is reported as `failed`
because an ancillary step afterwards could not run. An operator reading a morning summary that says
"failed" will reasonably conclude the night did not produce data. It did.

Dithering reduces fixed-pattern noise; it is not what acquires the science. A dither that cannot run
is a reason to warn, and arguably to stop dithering, but treating it as a run-level failure
overstates what happened. Same family as L52 — the status is technically derived but tells the
operator the wrong story.

**Deliberately not claimed:** this sequence had Dither as its *last* node, so nothing was lost. Whether
a failed dither in the middle of an `[Exposures, Dither, Exposures, …]` sequence also aborts the
blocks after it is **untested** and is the thing to check next — that is where this would cost a
night rather than mislabel one.

### G15 escalation — a mid-sequence dither failure abandons the rest of the night

The open question from G15 was whether a failed Dither in the middle of
`[Exposures, Dither, Exposures, …]` also kills the blocks after it. It does.
`execute_children_sequential` short-circuits, and says so in its own contract:

```rust
/// Returns Cancelled / Skipped / Failure on the first child that produces
/// one (short-circuiting); returns Success only when every child finished
/// Success or Skipped.
…
if result == NodeStatus::Failure || result == NodeStatus::Cancelled {
    return result;
}
```

A Dither node returns `Failure` when no guider is configured — observed directly, not assumed —
so on a sequence with dithering between exposure blocks, the **first** dither failure ends the run
and every later block is abandoned.

That changes the severity. As observed it merely mislabelled a complete run; with dithering placed
where it normally goes — between blocks, which is the whole point of it — a guider that drops at
01:00 ends the night at 01:00, having captured only the first block. The frames already taken are
safe on disk, but the remaining hours are lost, and the run reports `failed` without making clear
that the *cause* was an ancillary step rather than the imaging.

**Status of this claim, stated precisely.** The mechanism is the function's documented and
implemented contract, and it is consistent with what was observed end to end: the Dither returned
`Failure`, and the two-node run terminated and was recorded `failed` immediately. What was **not**
reproduced is the multi-block case itself — a `[Exposures, Dither, Exposures]` run showing the third
node skipped. That reproduction is the remaining step, and it is cheap: build those three nodes with
no guider connected and check whether the second exposure block produces frames.

**Why it matters for the product, not just the label.** Dithering is a noise-reduction convenience.
Losing the rest of a night because it could not run inverts the priority — the sensible behaviour is
to warn, skip dithering, and keep imaging. That is a policy decision of the same shape as the
autofocus one already on the owner's list, and the two should probably be answered together.

### G15 CONFIRMED — the mid-sequence case, reproduced end to end

The remaining step is done. Built `[Take Exposures ×10, Dither, Take Exposures ×10]` — 3 nodes,
20 frames planned — with no guider connected, at a site relocated into darkness, and ran it:

```
Executing child 1/3: 'Take Exposures'    → 10 frames captured
Executing child 2/3: 'Dither'            → ERROR Dither failed: No active guider configured
Executing child 3/3                      → NEVER APPEARS  (grep count: 0)
```

| | expected if it continued | actual |
|---|---|---|
| frames on disk | 48 → 68 | 48 → **58** |
| run record | — | `status=failed, framesCaptured=10, ditherCount=0` |

**Exactly half the planned night, and the second exposure block never started.** This is no longer
inferred from `execute_children_sequential`'s short-circuit contract — it is the observed behaviour
of the running app.

So on a normal dithered sequence, a guider that drops at any point ends the night there. The frames
already taken are safe on disk and correctly registered, but every remaining block is abandoned, and
the only account of why is one line in `errorMessages`.

Severity is now clear: this costs a night, it does not merely mislabel one. Dithering is a
noise-reduction convenience; the correct response to a dither that cannot run is to warn, skip it,
and keep imaging. That is the same policy question as the failed-autofocus one, and the two want a
single answer — an unattended run should not be ended by an ancillary step failing.

## V14 — live stacking runs and tears down cleanly (validation)

Ran `[Take Exposures ×10, Live Stacking]` in darkness with the simulators:

```
Executing child 2/2: 'Live Stacking'
Child 'Live Stacking' completed with status: Success
Live stacker stopped and resources released
```

Run record: `status=completed, framesCaptured=10`; frames on disk 58 → 68.

Two things worth noting. The node **succeeds** and the run is recorded `completed` — the direct
contrast with G15, where an ancillary node's failure took the whole run down. And the stacker
explicitly reports releasing its resources, which is the behaviour you want from something holding
image buffers across a long night.

With this, the only feature left unexercised is **meridian-flip execution**. Its configuration is
already verified (V12: `minutes_past=5.0`, `auto_center=true`, `max_retries=3`,
`failure_action=PauseAndAlert`); firing one requires carrying a target across the meridian, i.e.
simulating hours of sidereal motion, which is the same site-relocation technique used throughout
this section applied to time rather than longitude.

## Meridian-flip execution — not tested, but the method is worked out (correcting an earlier claim)

I previously wrote that firing a meridian flip needs "hours of sidereal motion the harness cannot
compress". **That is wrong**, and the correction is the useful part of this entry.

The flip trigger is `MinutesPastMeridian = 5.0`. Nothing has to move through the meridian — the
target only has to *already be* past it. So pick a target RA slightly west of the current local
sidereal time and the trigger condition is satisfied on the next evaluation:

```
LST at the darkness site (lon -135)      = 21.9449 h
target RA for 15 minutes past meridian   = LST - 0.25 h = 21.6949 h  (21h41m)
Dec +40                                  (comfortably up at latitude 42)
```

The recipe, in full:

1. Set `observer_longitude` so the site is in darkness (V12's daylight gate refuses on-sky frames
   otherwise); recompute for the hour.
2. Compute LST for that longitude, subtract ~15 minutes, use the result as the target RA.
3. Build `[Target(RA, Dec +40), Take Exposures]` and run it.
4. Watch for the flip in the log — the trigger config is pushed at run start and is already verified
   (V12: `auto_center=true`, `pause_guiding=true`, `resume_guiding=true`, `max_retries=3`,
   `failure_action=PauseAndAlert`).

What to check when it fires: that guiding pauses before and resumes after, that the post-flip
plate-solve recenter runs, that `meridianFlips` increments in the run stats, and — given G14 and
G15 — that a *failed* flip does what `PauseAndAlert` claims rather than ending the run silently.

This was set up and left unrun only because the session ran out of room; it is a handful of steps,
not a blocked capability, and stating it as blocked earlier was a mistake.

---

## G16 — every plate solve is reported as a failure, because the `.wcs` parser assumes newlines *(P0, fixed)*

Found while setting up the meridian-flip execution test (2026-08-10). It is the most serious
defect this campaign has produced, and it had been sitting behind a green test suite.

**What the app did.** The wizard-built sequence ran `Slew to Target` → `Plate Solve & Center`.
The Center node made five attempts and failed all five:

```
12:55:24  INFO  Centering on RA: 339.1650°, Dec: 40.0000° (accuracy: 5.0")
12:55:24  INFO  Center attempt 1/5
          Solved in 0.3 sec. Δ was 0.4".  Mount Δα=-0.4",  Δδ=-0.2".
12:55:30  WARN  Plate solve failed on attempt 1
          ... attempts 2-5, Δ = 0.9", 0.9", 1.1", 1.3" ...
12:55:56  ERROR Center Target failed: Failed to center within 5.0" after 5 attempts
12:55:56  INFO  Child 'Plate Solve & Center' completed with status: Failure
12:55:56  INFO  Child 'Sequence' completed with status: Failure
```

ASTAP solved **every** attempt, and every residual (0.4"–1.3") was far inside the 5.0" tolerance
the node was asked for. The app called each one a failure and then ended the run.

**Why.** The error the app logged names the cause exactly:

```
ERROR ASTAP reported success but .wcs parse failed:
      WCS file `/tmp/..._0.wcs` did not contain required keyword `CRVAL1`
```

`CRVAL1` is in that file. `parse_wcs_file_inner` walked it with `content.lines()`, but a `.wcs`
file is a raw FITS header — fixed 80-character cards packed end to end with **no line
terminators**. Verified directly on a solve run by hand:

```
$ astap_cli -f frame.fits -ra 0 -spd 90 -r 5 -z 2 -d <catalogs> -wcs
Solution found: 00: 00  00.1 +00d 00  01
$ python3 -c "d=open('/tmp/wcstest.wcs','rb').read(); print(len(d), d.count(b'\n'))"
5760 0
```

5760 bytes, **zero newlines** — 72 cards. `lines()` yields one 5760-character "line", so the
parser read card 0 (`SIMPLE`) and nothing else. `CRVAL1` sits at card 41, pushed there by the
instrument metadata ASTAP copies from the source frame, i.e. past the first 2880-byte block.

**Blast radius.** Anything that centres, which on the unattended path is most things:

- `Plate Solve & Center` — fails the node, and the sequential parent short-circuits, so the run
  ends before a single light frame (exactly what happened above).
- the post-meridian-flip recenter — the flip config the app pushes at run start is
  `auto_center=true`, so a flip that mechanically succeeded would still report failure.
- framing, and any other caller of the same solver.

The unit tests did not catch it because every `.wcs` fixture in the suite is built by a helper
that appends `'\n'` to each card — the tests encode a file format ASTAP does not produce.

**Fix.** `fits_header_cards()` splits on newlines first (fixtures and any solver that writes
them keep working) and then splits any segment longer than one card into 80-character cards.
Regression test `parse_wcs_file_reads_a_newline_free_card_stream` builds a genuine newline-free
card stream with the WCS keywords past card 36, and asserts the fixture contains no `'\n'` so it
cannot silently decay back into the format that hid this.

**Note for tonight.** This is in `Plate Solve & Center` on the shipped path. Any sequence built
by the Quick-Start wizard contains that node.

---

## G17 — the plate solver is never told the field scale, so it has to guess it *(P1, fixed)*

Found immediately after G16, on the same runs. Two separate observations, both from the app's
own log.

**1. The temp FITS handed to ASTAP carries no optics.** `SequencerDeviceOps::plate_solve`
(`bridge/src/sequencer_ops.rs`) builds a header with `EXPTIME`, `GAIN`, `OFFSET`, `CCD-TEMP`,
`RA`, `DEC` — and nothing about the telescope or the sensor. Captured directly off disk during a
run (the file is deleted the moment the solve returns, so it was copied by a watcher loop):

```
SIMPLE/BITPIX/NAXIS/NAXIS1=1920/NAXIS2=1080/BZERO/BSCALE
EXPTIME = 5.0        DATE-OBS = '2026-08-10T13:42:47.572Z'   IMAGETYP = 'Light'
OBJECT  = 'Plate Solve'   GAIN = 100   OFFSET = 10   CCD-TEMP = 20.0
XBINNING= 1   YBINNING = 1
RA      = 349.05     OBJCTRA  = '23 16 12.00'
DEC     = 40.0       OBJCTDEC = '+40 00 00.00'
END
```

No `FOCALLEN`, no `XPIXSZ`/`PIXSIZE`. The Center instruction also passes `hint_scale: None`
(`sequencer/src/instructions.rs`), so the command line carries no `-fov` either.

**2. ASTAP therefore sweeps for the scale, and the sweep is a coin flip.** Every attempt walks
the field of view down from 9.5°:

```
Image height: 9.50 / 6.33 / 4.22 / 2.81 / 1.88 / 1.25 / 0.83 / 0.56 / 0.37 degrees
```

The real field is 0.37°, i.e. the *last* rung. On the 12:55 run it reached it and solved in
0.3 s — and even then complained `Warning scale was inaccurate! Set FOV=0.23d, scale=0.8"`. On
the 13:27, 13:35 and 13:49 runs the same target at a different RA never converged and ASTAP
exited non-zero on all five attempts. Same code, same catalogs, same simulated sensor: the only
variable is whether the blind sweep happens to land.

**Consequence.** Centering is unreliable for a reason that has nothing to do with the sky, and
each failed attempt still costs a 5-second exposure plus the sweep, so five attempts burn ~35 s
before the node gives up and (per the sequential-parent rule) takes the run with it.

**What was changed.** `plate_solve` now writes `FOCALLEN` from the active equipment profile and
`XPIXSZ`/`YPIXSZ`/`PIXSIZE1`/`PIXSIZE2`/`XBINNING`/`YBINNING` from the camera's reported sensor
geometry, and logs which of the two it actually had.

**Root cause of my first wrong fix.** There are two `plate_solve` implementations. I patched
`sequencer_ops.rs`; the one that actually runs is `unified_device_ops.rs`, which builds a
`FitsWriteHeader` with `focal_length: None, pixel_size_x: None, pixel_size_y: None` hard-coded.
The log settled it: `Saved temp FITS for plate solving` (sequencer_ops) appears **0** times,
`Saving FITS file to: /tmp/skotiq_platesolve_temp` (the unified path, via
`api_save_fits_file`) appears **25** times. Both implementations are now fixed, since either can
be the live one.

**Verified live, end to end.** Same sequence, same target, same catalogs, after the fix:

```
14:13:17.229 INFO Plate solve scale hint: focal length 1000.0 mm, pixel pitch 3.76 um
                  (0.78"/px unbinned)
14:13:17.268 INFO Child 'Plate Solve & Center' completed with status: Success
```

One attempt, **0.04 s**, no `Image height: 9.50 / 6.33 / ...` ladder at all — and note the values
were there the whole time (1000 mm from the profile, 3.76 µm from the camera); they simply were
never written into the file handed to the solver. Before the two fixes the same node made five
attempts over ~35 s and failed every one against solves ASTAP had already produced, then took
the run down with it.

`imaging/src/platesolve.rs` also has an ASTAP `-fov` path gated on a caller-supplied scale hint
plus a pixel size ("Plate-solve scale hint provided without pixel size; skipping ASTAP -fov
hint"). Feeding that too would let the solver skip even the first FOV guess; the header cards
were sufficient here, so it is left as a further improvement rather than a fix.

---

## MERIDIAN FLIP — executed end to end and completed successfully *(the last untested feature)*

2026-08-10 14:54 UTC. Sandbox site at longitude +123.75 (early night, ~4 h of darkness in hand),
target `Flip Test` at RA 20.34 h / Dec +40, slewed to while still ~2.5 minutes **east** of the
meridian so the mount took the pre-flip (West) pier side, 30 s L frames, trigger left at its
default `MinutesPastMeridian = 5.0`.

The pre-frame gate fired first, and said exactly the right thing:

```
14:53:20  Waiting for the meridian flip before the next 30s exposure: the flip fires in ~40s
          (hour angle +0.07h, threshold 5 min past meridian) and would interrupt the frame
```

Then the flip itself, all eight steps:

```
14:54:00  Trigger fired: Meridian Flip (meridian_flip)
14:54:00  [MERIDIAN] Pre-flip altitude check: target 'Flip Test' altitude = 87.5° (min = 10.0°)
14:54:00  [MERIDIAN] FLIP TRIGGER ACTIVATED
14:54:00  [MERIDIAN]   Hour Angle: 0.08h (5.0 minutes past meridian)
14:54:00  [MERIDIAN]   Current Pier Side: West
14:54:00  [MERIDIAN] Step 1/8: Pausing guider...      (no guider configured — nothing to pause)
14:54:00  [MERIDIAN] Step 2/8: Stopping tracking...
14:54:00  [MERIDIAN] Step 3/8: Slewing to target (flip): RA=20.3400h, Dec=40.0000°   (2.0s)
14:54:02  [MERIDIAN] Step 4/8: Verifying pier side... New pier side: East
14:54:02  [MERIDIAN] Step 5/8: Resuming tracking...
14:54:02  [MERIDIAN] Step 6/8: Plate solving and centering...
14:54:08  [MERIDIAN] Plate solve result: offset=0.5" (RA=0.4", Dec=0.3") — within tolerance
14:54:08  [MERIDIAN] Step 7/8: Resuming guider...
14:54:08  [MERIDIAN] Step 8/8: Settling... (10s)
14:54:18  [MERIDIAN] FLIP COMPLETED SUCCESSFULLY  — total 18.3s, new pier side East
14:54:20  Capturing frame 1/1 (30.0s)
```

Checked against three independent sources, not just the log:

- **Pier side really changed**, West → East, and step 4 verified it rather than assuming it.
- **The post-flip recenter ran and succeeded** — 0.5″ residual. This is the step G16 and G17 would
  each have broken; the flip config carries `auto_center: true`, so before today's two fixes a
  mechanically perfect flip would still have reported failure here.
- **`meridianFlips: 1`** in `sequence_runs.stats_json`, alongside `framesCaptured: 13` and
  `integrationSecs: 390.0` — 390 ÷ 13 = exactly 30.0 s per frame, so the counters agree with the
  exposure length actually in use.
- **Capture resumed 2 s after the flip completed.**

The one thing still not exercised is a *failed* flip (`failure_action: PauseAndAlert`); every step
succeeded here.

---

## G19 — "no ASTAP star database found" on a rig that is solving fine *(P2, fixed)*

Surfaced by the run above: `sequence_runs.stats_json` carried

```
"errorMessages":["Plate-solve setup: no ASTAP star database found. ASTAP needs a star catalog
                  installed separately from astap.exe ... target centering in this sequence
                  will fail"]
```

while ASTAP was solving to 0.5″ against its D05 catalogs in the very same run.

Cause: the sequencer pre-flight called `detect_astap_catalog(None, None)`, which only searches
the *default* install locations. Every other entry point in that module consults the global
`ACTIVE_SOLVER_PREF` — the file even says so ("without any caller needing to pass the config
explicitly") — but this one did not, so on any rig whose ASTAP lives somewhere else the check
reported a missing catalog on every run. `detect_astap_catalog` now falls back to the configured
paths when the caller passes none.

Second, smaller cause: the catalog-name table knew `V17/V50/D80/G18/H18/H17/W08` but not `D05`,
so a directory of working D05 files identified as "catalog present, version unrecognized". `D05`
is now recognised, with **no** magnitude limit asserted — the published table does not give one,
and a fabricated number would feed the exposure planner.

Verified: 0 occurrences of the warning on the next run, centering still `Success`.

---

## G18 — FIXED and verified live: the camera is now claimed, not shared

The frame-25 kill (recorded above) is closed. Reproduced three times before the fix — runs ending
at exactly 25 frames — and the fix took two attempts, because the first one moved the race rather
than closing it.

**Attempt 1 (insufficient).** Made the trigger-fired autofocus wait for the capture loop. The hold
worked:

```
16:00:02  Trigger fired: Autofocus Interval
16:00:02  Holding trigger-fired autofocus for 30.0s: the capture loop is mid-exposure and
          starting now would destroy the frame
16:01:04  Camera free; running trigger-fired autofocus now
16:01:24  ERROR Failed to download image: No exposure is available to download
```

…and the same failure returned 20 s later, from the other end: nothing stopped the *capture loop*
starting a frame while the *autofocus* was running. Two independent "is the other one busy?"
flags cannot be tested and set without a race.

**Attempt 2 (the fix).** One claim on the shared trigger state, taken atomically under a single
write lock by whoever gets there first (`TriggerState::try_claim_camera_for`), released explicitly
when the holder is done. It is a **deadline**, not a boolean, so a holder that dies without
releasing costs one hold rather than wedging every future autofocus for the night. Both users
acquire it: the capture loop before each exposure, the autofocus trigger before its sweep.

Verified live, same sequence, same 25-frame cadence:

```
16:16:05  Trigger fired: Autofocus Interval (autofocus_interval)
16:16:05  Holding trigger-fired autofocus for ~30s: the capture loop is mid-exposure and
          starting now would destroy the frame
16:16:46  Camera free; running trigger-fired autofocus now
16:16:46  Executing autofocus as trigger recovery action
16:16:46  Holding the next 10s exposure for ~620s: a trigger action is using the camera
17:17:59  Low curve fit quality: R²=0.000 (required 0.700); returning to original position
16:18:09  Saved: Flip Test_L_0001_157.fits
16:18:09  Child 'L' completed with status: Success
```

Clean handoff in both directions, and **zero** occurrences of "No exposure is available to
download" across the whole run. Frame count and integration agree exactly (30 frames / 300.0 s at
10 s each), and the 30 files on disk match the counter.

The run then **paused** — correctly, and it says so in the header ("Sequence Paused"). That is the
existing failed-autofocus policy, not a new defect: the simulated focuser models no defocus, so
the V-curve fit is R²=0.000 and can never pass. On real optics the sweep has a real curve to fit.
Whether a failed autofocus *should* pause an unattended night is the open product question
already on the list, and is now the only thing between this sequence and running unattended.

**Second half of G18, also fixed:** interval autofocus could not be switched off. The engine has
always read `every_n_frames == 0` as "never fire", but the Dart seed clamped anything below 1 *up
to 1* — so the one value an operator would pick to disable it produced a refocus after **every
frame**, the most aggressive setting available. Zero now passes through as off.

---

## G15 — FIXED: a failed dither no longer ends the night

Dithering decorrelates fixed-pattern noise between subs. Losing it costs a little stacking
quality; the frames themselves are perfectly good science. `execute_dither` returned
`InstructionResult::failure`, the sequential parent short-circuited, and one failed dither threw
away every remaining exposure — reproduced live as `[Exposures x10, Dither, Exposures x10]`
finishing with **10 frames of 20** and `status=failed`, on a rig whose only problem was that no
guider was connected.

It is now non-fatal and loud: a warning on the node, in the log, and in the run's message list,
with a consecutive-failure count, because a dither failing every time usually means the guider
has gone — worth an operator's attention, not worth the night.

Verified live, same shape (Dither node inside the capture loop, no guider):

```
19:49:09  Child 'Dither' completed with status: Success
19:49:19  WARN Dither failed (2 in a row): No active guider configured. Continuing to image
          without dithering — frames are unaffected, but check the guider: repeated dither
          failures usually mean guiding has stopped.
19:49:19  Child 'Dither' completed with status: Success
19:49:29  WARN Dither failed (3 in a row): ...
19:49:29  Child 'Dither' completed with status: Success
```

The run keeps capturing, and the count escalates the message rather than the consequence. A
successful dither resets the streak, so "3 in a row" means three in a row and not three all night.

---

## G20 — a test hung the whole suite in the NVIDIA driver *(fixed; my first write-up of this was wrong)*

`cargo test -p skotiq_imaging` never finished: the process sat in `futex_wait` with
`/dev/nvidiactl` open, observed at 21 minutes before it was killed, inside
`platesolve::tests::internal_solver_test_helper_estimates_with_hint_and_blind_metadata`. The cause
is `gpu_downsample_max_u16`, which `extract_plate_stars` calls with a CPU fallback on `Err` — and a
hang is not an `Err`, so the fallback never ran.

**Correction to what I first wrote here.** I claimed "the same call sits on the internal-solver
path in shipped code" and that only `CenterTarget`'s 180 s timeout protected it. That is false.
`gpu_downsample_max_u16`, `extract_plate_stars` and `solve_internal` are all `#[cfg(test)]` — a
test-only helper chain that does not ship. I had read the call graph and not the attributes. The
defect is real test debt that blocked the launch gates; it is **not** a product hang, and I should
not have said it was.

**Why a timeout alone did not fix it.** The first attempt ran the GPU call on its own thread with
a 10-second deadline and abandoned it on timeout. The test then passed and the binary *still* hung:
the stranded thread was blocked in `nvkms_open_common` inside the kernel driver, holding the device
open, and the process could not exit. Thread state at that point, which is what settled it:

```
tid 1084605 (main):   futex_wait
tid 1084607 (worker): nvkms_open_common      <- 2 open fds on /dev/nvidia*
```

There is no interruption point that fixes that from the outside. So the escape is to not make the
call: `SKOTIQ_PLATESOLVE_FORCE_CPU` skips the GPU path entirely, and the test sets it, because
the test is about the solver's metadata estimation and never cared about the GPU. The deadline and
the once-per-process latch are kept as a second line of defence for anyone who does exercise that
path.

Result: the test runs to completion in 0.00 s and is no longer `#[ignore]`d.
