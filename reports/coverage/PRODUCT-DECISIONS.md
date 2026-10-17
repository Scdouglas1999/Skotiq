# Product decisions the audit will not make for you

These are the items the end-to-end campaign classified as product judgement rather than defect.
Each one is real and reproducible, each one has a recommendation with its reasoning, and none of
them has been changed in the code. They are listed here because acting on them would decide what
the app IS, which is the owner's call — the campaign fixed the 78 items that had an objectively
right answer and stopped at these.

A recommendation that says 'leave it' is a real answer, not a dodge: several of these argue the
current behaviour is correct and say what it would cost to change it anyway.

## 1. Instrument the five equipment metrics that genuinely are not tracked, or drop the cards

**Options** — (a) Instrument them: new columns plus write paths through mount ops (slew count, tracking
seconds), focuser ops (total steps) and the PHD2 bridge (guide seconds, star-lost events) - real
work in native + Dart, and it changes what every night records from here on. (b) Drop the dead
rows and rename the tab to what it actually measures (camera, focus and guiding quality). (c)
Leave them as honest 'Not tracked' placeholders.

**Recommendation** — (a) for slews, tracking time and star-lost events - they are the numbers an operator uses to
argue with a mount vendor or to spot a guide star the app kept losing, and they are cheap to
count where the app already issues the command. Failing that, (b): a bordered card whose every
row says 'Not tracked' is worse than no card. I would not ship (c) unchanged.

## 2. 'Recover Sequence?' modal has no way out except Discard (destructive) or Resume (acts)

**Options** — (a) Keep it: the dialog already prints the sequence name, when it was saved, and how many frames
/ how much integration it holds, which is the information a decision needs; an undecided
checkpoint is also a trap, since starting a new run overwrites it. (b) Add 'Decide later': the
operator can inspect the sequence first, at the cost of carrying an undecided checkpoint into
the night and of the two startup dialogs no longer agreeing about how firm a decision is.

**Recommendation** — (a). The dialog states everything needed to decide, the alternative silently risks overwriting
the checkpoint the user wanted to inspect, and the deliberate design plus its test would both
have to be unwound. If the owner disagrees, (b) is a five-line change in
buildCheckpointRecoveryDialog plus updating that test's first case.

## 3. MPC export only offers the legacy 80-column format while the app's own transient panel documents ADES PSV

**Options** — (a) Add a format selector to the MPC Report Export card that reuses the existing ADES writer,
defaulting to ADES when an observatory code is set and falling back to 80-column when it is not.
(b) Replace the 80-column writer outright. (c) Leave it: the 80-column format is still accepted
for many programmes and needs no observatory code, so it is the format that works for a user who
has not registered one.

**Recommendation** — (a). It removes the contradiction between the two panels, reuses code that already exists rather
than writing a second one, and does not lock out a user with no obs code. I would not do (b) -
that makes an unregistered observer unable to export at all.

## 4. Quick-Start Wizard shows both a per-filter Count and a Loop Iterations field and never states the resulting frame total

**Options** — (A) Make Count real as frames-per-filter-per-loop-pass: exposure count := filterConfig.count,
total = count x iterations. Both controls then mean something and the displayed numbers become
true, but today's defaults (count 10, iterations 10) would build 100 frames per filter where
they build 10 - a 10x change for anyone who has used the wizard. (B) Delete the per-filter Count
column and keep Loop Iterations as the single knob, relabelled 'frames per filter'. Zero change
to any built sequence or duration estimate, the review step becomes true by construction, and it
is the finding's own suggestion; the cost is that presets can no longer weight filters
differently, intent the code currently writes down and then throws away.

**Recommendation** — B, plus a 'N frames, H h M m integration' line on step 2 and step 5. It is the only option that
cannot silently change what an existing user's wizard produces tonight, and it makes the wizard
consistent with the two things that already agree (the builder and the estimator). If the owner
wants the preset weighting to be real, that is option A and it should ship with a visible total
and a note that frame counts have changed.

## 5. Building the standard night by hand takes ~21 actions before configuring anything, and the empty Builder points at none of the faster paths

**Options** — (A) Turn the empty canvas into a three-way chooser - 'Start from a wizard / Start from a starter
/ Build manually' - keeping the drop zone underneath. Fastest path to a working night for a
first-timer; risks reading as a nag to the operator who opened the Builder precisely because
they intend to build, and it puts a decision in front of every New Sequence. (B) Leave the
canvas as a canvas and add one quiet line under the hint - 'or start from the Quick-Start Wizard
/ a Starter' as inline links. Discoverable without changing what the screen is for; less of a
lift for a beginner than (A).

**Recommendation** — B. It closes the gap the finding actually measured (the faster paths are invisible from where
you start) at a fraction of the risk and does not commit the product to being wizard-led. Worth
pairing with the finding's second ask - an insert-after-selected keyboard entry - which is
additive and cuts the 21-action count under either option.

## 6. The one layer that makes imaging-scale fields usable - DSS survey imagery - is off by default and buried in a panel

**Options** — (a) Default the layer ON (it already self-limits to FOV < 8 deg) with a 'uses network' note:
matches NINA's framing assistant and Telescopius and makes the planetarium instantly usable for
framing, but the app makes network requests nobody asked for, which costs data on a tethered
field rig and fails silently offline. (b) Leave it OFF but offer it once, in place, the first
time the user zooms past the catalog's depth ('This field is beyond the bundled catalog - load
DSS imagery?'), remembering the answer: no silent network, and the layer becomes discoverable
exactly when it matters, at the cost of one more prompt. (c) Leave as-is and only sharpen the
label.

**Recommendation** — (b). It closes the real defect — discoverability at framing scale — without overriding the
owner's stated offline-first reasoning, and it puts the offer at the only moment the operator
can judge it: when the chart in front of them has run out of stars.

## 7. Should the Submit-discovery dialog pre-select TNS -- the live, irreversible, public submission -- at all?

**Options** — (a) Keep TNS pre-selected: for a transient discovery TNS is the correct destination — AAVSO is
variable-star photometry and MPC is minor-planet astrometry, so defaulting elsewhere pre-selects
the WRONG network for the task, and the live submission is already behind a typed confirmation.
(b) Pre-select the reversible local export (AAVSO, else MPC) and make TNS an explicit opt-in: a
first-time user reaching this dialog has by definition never submitted anything, and a mis-
classified residual reported to TNS cannot be taken back.

**Recommendation** — (a), keep TNS. The dialog is titled 'Submit discovery' and is reached from a confirmed transient
candidate; defaulting to a network that cannot even accept that object type trades a real
everyday papercut for a hazard the confirmation dialog already covers. If the owner wants (b) it
is a two-line change to the preference list in _resolveFormat.

## 8. The stack result can only leave the app as 8-bit PNG/JPEG -- there is no linear FITS or 16-bit TIFF export

**Options** — (a) Leave Stack & Share as the share loop it is named for and point serious integration at
Session Review, which already emits FITS. Zero risk and zero storage cost, but the user who just
stacked 40 subs here has to redo the integration in the other surface. (b) Add 'Save FITS'
limited to the in-memory buffer: cheap (the native save already exists and the service's save
functions are injectable) but only enabled right after the run, and mono-only — an OSC stack is
an interleaved RGB16 buffer and the existing writer emits one plane, so colour needs native
3-axis support or it would write a scrambled mosaic. (c) Persist the linear integration per
stacked result (width*height*2 bytes, tens of MB per stack) so the export always works, plus the
native OSC work — the only version that matches what NINA/SGP/ASIAIR users expect, but it is a
storage-policy change.

**Recommendation** — (c) if Stack & Share is meant to be a real integration path, otherwise (a). I would NOT ship (b)
alone: an export button that works for ten minutes after a run and is greyed out forever after
is exactly the half-capability this campaign has been removing. The decision is genuinely 'what
is Stack & Share for', which is why I did not pick it — and (c) carries native work (multi-plane
FITS for OSC) plus a per-stack disk cost the owner should agree to.

## 9. Location has no place search: no city lookup, no map picker, no 'read site from the connected mount'

**Options** — B: bundle an offline city/place picker (a 5-10k place table is a few hundred KB; GeoNames
cities1000 is ~10 MB) -- works with no network on an observatory LAN and is the ASIAIR/SkySafari
behaviour, but adds a licensed dataset to every install plus name-collision UX. C: read the site
from a connected mount -- zero data cost and NINA offers it, but a mount that has never been
synced reports 0/0 or a factory site, so a one-tap read can silently replace a good site with a
wrong one. D: online place search -- no install cost, full coverage, but a second outbound
service on a machine that is often deliberately offline and needing the same consent treatment
Detect Location already got. E: leave as is (Detect Location plus the DMS entry now shipped).

**Recommendation** — B, plus C behind a confirmation that shows the values read before they overwrite anything. B is
the only option that works on the disconnected observatory network this app is built for, and
the dataset is small beside the star catalogs already shipped. D is cheapest to build but puts
outbound traffic on the one screen where an isolated network is normal.

## 10. The Deep-Star Tier card tells an astrophotographer to build and host their own tileset with a repo tool

**Options** — (a) Publish an official tileset - the project already ships catalogs via a GitHub release
('catalogs-v1'), so the machinery exists - and reduce the card to one toggle with the URL field
demoted to an override: the only version where the deep-star tier is a real feature for a real
customer, at the cost of building, hosting and versioning a large Gaia/Tycho-2 artifact. (b)
Keep self-hosting as the only path, but move the card behind an 'Advanced' disclosure and link
tools/catalog_prep/README.md (it exists, and would be a URL rather than a source path a reader
cannot open): zero infrastructure, ships today, but the tier stays developer-only while
occupying space in a consumer settings page. (c) Hide the tier from release builds until a
tileset exists.

**Recommendation** — (a) if the deep-star tier is meant to be a selling point - the bundled HYG floor is visible at
imaging fields of view, which is exactly where this tier matters - otherwise (b) as the honest
interim, since it ships immediately and stops the page reading like a developer's TODO. Not (c):
the code is built and works, and hiding it removes what advanced users can already use.

## 11. Framing sidebar only scrolls when the wheel is over certain sub-regions, and resets to the top on every navigation

**Options** — (a) Leave it: scroll-to-top on navigation is the platform default and every section is
reachable. (b) Persist the sidebar offset in a provider keyed to the framing tab, so returning
from a slew lands you back at Utilities - small, contained, no visual change. (c) Restructure:
collapse Guided Framing to a compact stepper and/or make the sections collapsible so Utilities
is not three screens down.

**Recommendation** — (b). It is the part that costs an operator something real at 2am - you scroll to Utilities, act,
come back and hunt again - and it changes nothing about the screen's identity. (c) is a genuine
redesign of the app's most information-dense sidebar and should be the owner's call, not a side
effect of a scroll complaint; I would not do it on this evidence.

## 12. Default snapshot exposure is 55.0 s

**Options** — (a) Keep seeding the Smart Night sub length: the screen is a live-imaging surface and the number
you see is the one the night will actually use. (b) Default the manual screen to a short test
exposure (~2 s) and persist the user's last manual value per profile, leaving the recommendation
to the sequencer where it is set per instruction - this is what NINA does and it costs a minute
less on every arrival. (c) Keep the seed but offer the recommendation as a one-tap chip next to
a short default.

**Recommendation** — (b), with last-used persistence. The first action on this screen is nearly always a framing or
focus check, and a 55 s wait before any feedback is a real cost outdoors; the sequencer already
owns per-instruction sub length, so nothing is lost. But it changes the screen's advertised
purpose, so it is the owner's call - and note (b) largely retires the Smart Night seed on this
surface, which was built on purpose.

## 13. Should the capture-folder step prefill a default folder?

**Options** — A) Prefill <Documents>/Skotiq/Captures (the path shape the app already uses for exports,
plugins and science reports) and create it on accept, so onboarding finishes in one click. B)
Offer it as a labelled one-tap suggestion chip beside Browse — the path is visible and nothing
is created until tapped. C) Leave as-is: the operator always states where frames go, which on a
rig with a dedicated capture SSD is the answer they would give anyway.

**Recommendation** — B. It removes the blocking dead end for a first-time user without the app quietly deciding that
a night of 16-bit subs belongs in Documents — on a laptop with a small system drive that is a
real problem, and this app writes GB per night. It is also a one-line change to A later if the
owner prefers.

## 14. Sky Flats has no twilight timing, no sky-brightness gate and no anti-solar pointing - the three things sky flats are actually about

**Options** — (a) Bind the tab to the existing twilight service only - show 'Dusk flats: civil twilight 20:31,
usable window 20:35-20:58' with a countdown and an 'arm at' option. Cheap, no new hardware
commands, and it fixes the 'when do I press Start' problem, which is the one that actually costs
you the window. (b) Add (a) plus an auto-start when the measured sky ADU enters the target band
- closes the loop but means the wizard starts exposing on its own. (c) Full NINA parity: (b)
plus a 'slew to flat spot' action (anti-solar azimuth, ~75 deg altitude) - best flats, but a
calibration screen that slews the mount is a new safety surface (park state, horizon limits,
meridian side) and needs its own confirmation and abort story.

**Recommendation** — (a) now, (b) next. The twilight window is the part a user cannot compute in their head at dusk
and the part that makes the difference between 6 usable filters and 2; it is pure disclosure of
data the app already has, with no new device commands. The anti-solar slew (c) should be a
separate, explicitly-confirmed action rather than folded into Start, because the operator may
have the scope where it is for a reason.

## 15. All-Sky: withholding the acceptance verdict until the drift baseline is long enough

**Options** — (a) Gate on elapsed drift baseline (e.g. suppress the verdict below 60-120s). Simple and
legible, but the right number depends on mount, focal length and solve accuracy. (b) Gate on
measurement stability - require N consecutive samples whose total error agrees within the
threshold before showing a verdict. Self-calibrating and needs no invented constant, but 'Within
acceptance' then appears later than the number does, which needs a caption explaining the wait.
(c) Leave it and rely on the new baseline readout to inform the user.

**Recommendation** — (b). It is the only option with no magic number: the wizard already holds
AUTO_COMPLETE_HOLD_SECS of consecutive below-threshold samples before it auto-completes
(all_sky_polar/mod.rs:312), so applying the SAME consecutive-agreement rule to the on-screen
verdict makes the caption and the auto-complete tell one story instead of two. Owner should
confirm they want the verdict to lag the number.

## 16. The Night Outlook ranks by geometry alone: a mag-13.2, 1.9-arcmin galaxy outranks M31 and M27

**Options** — (a) Raise the existing framing-fit weight from 0.08 to something decisive (~0.25-0.35) and add a
mild surface-brightness/magnitude term, so a 30-arcsec planetary at 1.29 arcsec/px cannot top
the list — costs nothing new, but it re-ranks every user's Plan Tonight overnight and makes the
outlook depend on having an equipment profile. (b) Leave the score as pure observability and
instead default the Size filter to the FOV-fitting range whenever a profile exists — reversible
with one click, visible to the user, and leaves the score meaning 'how well-placed', which is
what its factor names promise. (c) Leave both and add a 'Fits your rig' sort mode.

**Recommendation** — (b), plus a modest bump of the framing weight to ~0.15. Ranking by observability is defensible
and the badge's own breakdown chips claim exactly that; silently folding 'is it worth imaging'
into the same number makes the badge unexplainable. A defaulted-but-visible Size filter fixes
what the operator actually complains about — unimageable specks at the top — without inventing
an opinion inside a number labelled altitude/moon/transit.

## 17. Two different score scales for "how good is this target tonight" on the same screen

**Options** — (a) Normalise the engine score to 0-100 for display (divide by the sum of the configured
weights, which is exact and already available on the decision). Both surfaces then read 0-100 —
but they would look directly comparable while still being different metrics, which risks
INVERTING the confusion into a false equivalence. (b) Leave the number and label the column
'Weight' with the per-factor contributions available on the row (the engine already ships them;
rejected-candidate rows render exactly that breakdown today). Honest and cheap, but it is
disclosure rather than a cure.

**Recommendation** — (b), with the breakdown promoted from a tooltip into the row's expanded state — the same
treatment 'Other candidates considered' already gives rejected rows — and the column header
renamed to 'Weight'. Two 0-100 numbers that disagree about the same object on adjacent tabs
would be worse at 2am than one number that is openly a different, explainable thing.

## 18. "Run unattended all night" arms all-night automation on one click with no confirmation or readiness summary

**Options** — (a) Add a confirmation sheet gated on a readiness checklist (weather safety, guider, park-at-
dawn, disk space, first target) with a 'Start anyway' for amber rows. Safer, matches NINA/SGP,
and reuses the checklist onboarding already links to — but it puts a modal in front of the
feature the product is sold on, every night, including the nights everything is fine. (b) Keep
one click and render the same readiness rows INLINE in the panel above the button, so the state
is visible before the click without gating it. (c) Confirm only when a row is amber or red, so
nothing warns on a healthy rig.

**Recommendation** — (c). It preserves the one-click promise on a rig that is actually ready and interposes exactly
when the click would have been a mistake, which is the only case the confirmation was ever for.
If the owner wants a single unconditional rule instead, (b) is the honest one: show the state,
do not nag.

## 19. "Alt now" is the wrong axis for a tonight planner

**Options** — (a) Repoint the existing chip at peakAltitude and rename it 'Min peak altitude tonight',
dropping the right-now filter. One chip, matches the whole-night framing of the rest of the tab
— but it silently redefines a filter existing users may have set, and removes the at-the-
eyepiece use. (b) Add a SECOND chip ('Peak altitude tonight') beside it and leave 'Alt now'
alone. Nothing breaks and both questions are answerable, at the cost of another control in an
already busy filter row and two similar-sounding chips to tell apart.

**Recommendation** — (b), with the new peak-altitude chip placed first so it reads as the default question a tonight
planner answers. The filter row already carries 7 controls and wraps cleanly, and an operator
who set 'Alt now' deliberately should not have it redefined under them.

## 20. The whole screens/suggestions/ UI ships but is unreachable from any screen

**Options** — (a) Delete the whole directory and retire suggestion_filters_remote_test.dart — the honest end
state if the planner's own controls are the answer, and it removes 2.5k lines of UI no reviewer
can reach. (b) Delete the filter and breakdown widgets but mount TransientAlertsPanel on Plan
Tonight > Recommendation, which is where an observer would expect 'a nova went off tonight' to
appear and where it can still change what they image. (c) Keep everything as a staging area for
a future Suggestions screen — the status quo, i.e. dead code shipping in every build.

**Recommendation** — (b). ScoreBreakdown and SuggestionFilters duplicate shipped controls and should go; the
transient panel is the one piece with a real user story, and Analytics > Science is the wrong
home for something only actionable before the night starts. If the owner does not want
transients on the planner, then (a) — (c) is the only option that is definitely wrong.

## 21. The scheduler still has no per-target minimum-altitude, maximum-airmass or meridian-side constraint

**Options** — (a) Add altitudeMin (degrees) and airmassMax as first-class kinds — cheap and symmetric with
moonSeparationMin (payload_json, no migration; the engine already computes altitude for the
site-wide gate), and it makes the per-target editor match what a NINA or SGP user arrives
expecting. (b) Add only altitudeMin, on the grounds that airmass is a monotone function of
altitude and two knobs for one axis is how schedulers get confusing. (c) Add nothing and
document customHorizon as the per-target altitude mechanism — no new surface, but the wizard
then has to explain a horizon profile to someone who wanted one number, and meridian side stays
unsayable.

**Recommendation** — (a) for altitudeMin with (b)'s reasoning for airmass: ship altitudeMin and let the field offer
airmass as an alternate UNIT on the same constraint rather than a separate kind, so there is one
axis with two spellings. Meridian side I would hold back for its own decision — it interacts
with the flip logic and the scheduled-window bypass, so it is not the drop-in an altitude floor
is.

## 22. The narrator detail sheet shows a 'PINNED' badge for a flag no operator can set or clear

**Options** — (a) Leave the badge: it does explain why a discovery sits at the top of the feed, and costs
nothing to ship. (b) Retitle it to something purely descriptive — 'HIGHLIGHT' or 'TOP MOMENT' —
so it reads as the narrator's own emphasis rather than a state the operator set and can undo; a
one-string copy change, no schema or DAO work. (c) Make pinning real: add an updatePinned write
to narrator_events_dao.dart, a toggle in the detail sheet, a headless PATCH, and a 'Pinned only'
chip on the NIGHT STORY timeline.

**Recommendation** — (b) now, with (c) treated as a separate feature the owner decides on its own merits. (b) removes
the false affordance for the cost of one string while keeping the useful signal that the
narrator considered this event a headline. (a) leaves the app implying a control it does not
have — the same cry-wolf shape this campaign has been closing elsewhere. (c) is genuinely useful
over an eight-hour night, but it is a new feature with a new write path and hub-sync
implications, and should not be smuggled in under a P3 widget finding.

## 23. There is no keyboard shortcut that reorders a node (the finding proposed Alt+Arrow)

**Options** — (a) Bind Alt+Up / Alt+Down to reorder the selected node - the editor convention (VS Code, most
tree editors), free of any binding currently in kSequenceTreeShortcuts or the top-level
sequencer_screen.dart map, and it makes the fastest path for a 30-instruction sequence a
keyboard one. (b) Leave it: the tree's keymap is deliberately small and obvious (the file says
so in its own header), Alt is the menu-mnemonic modifier on Windows/Linux and can collide with
window-manager bindings, and NINA/SGP ship no such binding either, so nobody arrives expecting
it.

**Recommendation** — (a). Reordering is the one structural edit an operator repeats dozens of times while building a
sequence, and it is the only one with no direct key. But it changes the app's keyboard contract
- it belongs in the shortcut help sheet and the docs - so it is the owner's call, not mine.


## 24. Flat Wizard Equipment shortcut hidden when camera is session-connected but not profile-assigned

**Evidence** — Live 2026-08-05 (`verify-product` / `cont/`): Connecting a Simulated Camera from Discovery without Assign leaves profile `cameraId` empty; Equipment rail `_FlatWizardShortcut` shrinks away. After Assign → My Equipment, the shortcut appears. Imaging → Camera → Flat Wizard still opens the wizard without profile assignment. Session-only / Assign messaging already exists on cards, Connect tooltip, and Ready-to-image.

**Options** — (a) Keep current: Equipment shortcut requires an assigned profile camera; Imaging → Camera → Flat Wizard remains the path for session-connected-only setups. (b) Show the Equipment shortcut whenever any camera is connected (session or profile). (c) Show a disabled / prompt card on Equipment (“Assign a camera to open Flat Wizard”) instead of hiding the entry.

**Recommendation** — (a), with a slight lean toward (c) only if discoverability complaints continue. The wizard is not unreachable — Imaging → Camera → Flat Wizard works without Assign — and the Equipment cards already tell the operator to Assign. Promoting session-connected gear into the profile-gated rail (b) blurs the session-vs-profile boundary the rest of Equipment is teaching. (c) is the softer discoverability fix if (a) feels too quiet, without changing who can actually run flats.


## 25. Loop and Conditional are no-ops the moment you drag them out of the palette

A `Loop` arrives set to count-mode with 1 iteration and a `Conditional` arrives set to
`always` — so both nodes, freshly added, do exactly nothing to the sequence they wrap. The
product-critique wave "fixed" this by adding `NoOpLogicNodeRule`
(`logic_node_rules.dart:412-461`), which raises an INFO issue for each case. An adversarial
verifier confirmed the rule is correct, wired (`sequence_validation.dart:323` →
`live_validation_provider.dart:169`), quiet against every bundled template, and pinned by a test
that goes red when the registration is severed — and then classified the fix **disclosure-only**,
because the complaint was about the default and the default did not change.

It is weaker than it sounds, too: `node_summary.dart:502-523` already rendered the loop row as an
inline-editable `× 1` and the conditional row as `if always`. The state was on the row, and the
count was editable in place. The new badge adds emphasis, not information.

**Options** — (a) Pick shipping defaults: a Loop that arrives at some count > 1, and a
`ConditionalType` that arrives at a real predicate. (b) Add an explicit "unset" member to
`ConditionalType` and make an unconfigured Conditional a validation WARNING rather than INFO, so a
sequence cannot be run with a placeholder branch in it. (c) Keep the INFO badge and change nothing
else. (d) Make adding either node open its properties panel focused on the field that matters, so
the default is never what ships in a saved sequence.

**Recommendation** — (d), then (b). Nobody can say whether a Loop means 2 or 10 — the verifier
declined to guess for exactly that reason, and inventing a number here imposes taste on every
sequence built from the palette. But "the node you just added does nothing" is a UX problem with a
non-taste answer: put the cursor in the count field. (b) is worth pairing with it because
`ConditionalType` currently has no unset member (`simple_logic_nodes.dart:168` — every other
member needs a threshold), so `always` is doing double duty as both a real choice and a
placeholder, and no rule can tell those apart. (a) is the tempting one to avoid.
