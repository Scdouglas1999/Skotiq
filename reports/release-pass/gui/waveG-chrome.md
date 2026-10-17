# Wave G spot-check — chrome / sky half

Driver: `tools/ui_audit/drive_linux.py`, display `:91`, profile `waveG-chrome`,
started `--fresh`. Bundle driven:
`apps/desktop/build/linux/x64/release/bundle/lib/libapp.so` and
`libskotiq_bridge.so`, **both Aug 14 01:44** — the F-fix build; the app was
launched at 01:45. Window 1600x900 unless a step names another size.
**Nothing was fixed in this pass.**

Setup: onboarding skipped; observing site 40.05 / -75.1 (LST went `--:--` →
`22:17`, so the site took); image output `/tmp/ns-audit/waveG-chrome/captures`;
Simulated Camera / Mount / Focuser / Filter Wheel connected from Discovery.
Two real sequencer runs were driven (1 s × 3, then 1 s × 6) so that "most recent
night" has something to be wrong about.

Orientation: one `graphify query "toast device disconnect naming, SkotiqButton
disabled semantics, projection cycler tooltip"`.

Evidence shots: `reports/release-pass/gui/shots/waveG-*.png`.

**Score: 9 verified, 3 not.**

---

## 1. Equipment toasts

### WD-EQ-2a — VERIFIED
Equipment → Discovery → **Connect** on *Built-in Multi-Star Guider* (which
refuses, then reports the guider disconnected). Third toast card
(`waveG-01`, 3× crop `waveG-03`):

```
Equipment disconnected
Built-in Multi-Star Guider disconnected.
```

The raw id Wave F saw — `Guider native:builtin_guider:multi_star disconnected.`
— is gone, the device type is not prefixed, and the name matches the one
Discovery and the status bar use for the same device.

### WD-EQ-3 — **FAILED** (still broken, unchanged)
Same single click still raises **two** `Guider Error` toasts that differ only by
a trailing full stop, with **no `(x2)` count** (`waveG-02`, 3× crop):

```
Guider Error
Failed to connect built-in guider: Operation failed:
Built-in guider requires an active profile with a guide focal length      <- no full stop
Guider Error
Failed to connect built-in guider: Operation failed:
Built-in guider requires an active profile with a guide focal length.     <- full stop
```

Reproduced twice, ~14 minutes apart (attempts 1 and 3). Attempt 2 showed only
one card because the screenshot was taken 3 s after the click and the second
producer had not fired yet — a 5 s wait shows both, so a short-wait check will
report this fixed when it is not.

The normalized-key dedupe the F-fix landed at the notification router
(`trim` → collapse whitespace → strip trailing `[\s.,;:!…]` → lowercase) is
exactly the recipe this pair needs, and it is still not collapsing them on the
one case it was written for. Whatever the router now does, these two refusals
do not reach the toast overlay as one notification.

---

## 2. Chrome

### CON-56 — VERIFIED
Plan Tonight → Planetarium, `tree --all`: `button: Now` and `button: Tonight`
(was `NOW` / `TONIGHT`).

### CON-62 — VERIFIED (both halves + search)
Settings → Help & Tutorials (`waveG-09`):
* **One case.** Every ROW title is sentence case — *First night walkthrough,
  Capture your first light, Re-run equipment setup, Re-run onboarding tour,
  Generate diagnostic dump, Equipment setup, Target planning, Automated imaging,
  Calibration frames, Advanced features*. Section HEADERS stay Title Case
  (*Guided Flows, Tutorial Tours, Reset Progress, Settings*), which is the
  app-wide register.
* **One button treatment.** All ten run-verb buttons render outline
  (`waveG-10`, the button column cropped across both sections). The five
  filled-primary `Start`s Wave F saw directly beneath five outline ones are gone.
* **Search still finds the renamed rows.** Typing `Capture your first light`
  into Settings search returns `Help & Tutorials ▸ Capture your first light`;
  `Advanced features` returns `Help & Tutorials ▸ Advanced features` (plus
  Science). The generated index is not stale.

### WE-EQ-N5 — VERIFIED (charter item), with a disclosed residual
`resize 1000 800`, four devices connected (`waveG-04`, 8× crop of the cut
`waveG-05`). At the cut the strip now draws an explicit `…`, immediately before
the `>` scroll chevron, and the camera pill truncates inside itself
(`Simulated Ca…`). Wave F's defect — `Si` sliced mid-word, no ellipsis, dissolved
by the fade — is gone.

**Residual, disclosed:** the F-fix's own framing is still half true. The strip
does not *fit* 1000 px, it scrolls, and the item at the cut is a device name
reduced to a single letter plus the mark (`S…`). The mark tells the operator
something is hidden; it does not tell them what.

### WF-EQ-N1 — **FAILED** (partial fix)
`resize 1000 800` → Sequencer.
* **Sequences (fixed):** `Sequence Library` renders in full and the search box
  is full width (`Search sequences…`) — Wave F had `Sequenc…` and `Search s…`
  (`waveG-08`).
* **Templates (still broken):** `Sequence T…` / `Start with a temp…`
  (`waveG-07`). The title is *still* cut, and at the same rendered font size as
  the Sequences title beside it — the "shrink to a 16 px floor before you
  ellipsise" behaviour is not reaching this caller.
* **Both subtitles still cut:** `Start with a temp…` and
  `Browse and load your s…`. CON-52's one-sentence self-description is still
  destroyed at a supported desktop width.

Mitigation that IS live: the accessibility names carry the full text —
`panel: Sequence Templates\nStart with a template or save your sequences for
reuse.` — so a screen reader gets what the screen does not.

### WF-EQ-N2 — VERIFIED
Equipment with the Equipment Tour nudge up, three notification toasts raised by
the guider refusal (`waveG-01`): the toast stack occupies image y 340–545 and
the nudge occupies y 583–670 — title, body and the *Maybe Later / Start Tour*
row all clear. The notification overlay (not just the SnackBar path) now honours
the inset.

### WF-EQ-N3 — VERIFIED
Plan Tonight → Recommendation, autopilot standby banner:

> "The autopilot runs targets from the scheduler queue, which is empty. The
> Night Outlook **on this tab** is your object catalog — add targets to the
> scheduler queue (with integration goals) for the autopilot to run them. It is
> a different list from the builder's Target Queue."

No physical-direction copy. A grep of the planner a11y dump for
`below|above|on the left|on the right` returns only
`7.0 hours above minimum altitude` — the astronomy sense the guard exempts.

### WE-SP-5 — **NOT VERIFIABLE as specified** (fix not exercised; residual found)
The charter's condition cannot be assembled on this build: **the Moon card and
the Smart Night prompt never coexist.**

* Standby briefing with the Moon card (`waveG-14`, 0 devices connected):
  `tree | grep -ci moonrise` = 1, `grep -ci "build smart night"` = **0**.
* With devices connected the prompt appears — `panel: Plan tonight
  automatically`, `button: Skip this step`, `button: Build Smart Night` — and
  the dashboard has switched to the connected layout:
  `grep -ci moonrise` = **0**, `grep -ci "build smart night"` = 2. Checked at
  1600x900 and again 20 s later; the counts do not move.

The prompt's own gate explains it: `smart_night_prompt_card.dart` requires
`equipmentReady && readyGraceElapsed && profile != null && location != null`,
and the briefing that owns the Moon card is the no-equipment branch. So the
`kFloatingPromptReservedHeight` reserve the F-fix added to `CockpitStandby`
could not be exercised on the surface the finding named, and I cannot say
whether it works.

**Residual of the same class, observed (`waveG-13`):** connected dashboard at
`resize 1000 800`, scrolled to the hard bottom (75 wheel notches; the last 25
moved nothing — two captures are pixel-identical apart from the clock). The
prompt card occupies x 372–851 / y 573–709 and paints over the RECENT EVENTS
rows at y 588 and y 641, cutting `Equipment Conne…` mid-word. Floating prompts
are still drawn over docked content; only the surface has changed.

---

## 3. Planetarium — D-2 / WF-SS-N3 — VERIFIED

Plan Tonight → Planetarium, freshly mounted. The projection cycler is the globe
icon at root (697, 264) — confirmed by hovering it and reading the tooltip
(`waveG-11`, *"Projection: Stereographic"*).

`tree --all | grep -c "Projection: Stereographic"`, same session:

| moment | count | what the node is |
| --- | --- | --- |
| never hovered | **1** | `button: Projection: Stereographic` |
| hovering, +3 s | **1** | the same button |
| pointer parked at (1300,1000), +8 s | **1** | the same button |

The one occurrence is the **control's accessible name**, not a tooltip: no
Material tooltip node is ever created (the F-fix sets the message to an empty
string, so Flutter returns the child untouched), and the button is no longer
anonymous. Wave F's signature — 0 before the first hover, 1 forever after — is
gone in both directions.

Also in the same dump, every command-bar control is named:
`Search the sky (Ctrl+K)`, `Reset view (zenith, FOV 60)`,
`Equatorial view — switch to Alt/Az`, `Projection: Stereographic`, `Layers`,
`Tools`, `Plan / object panel`. Time transport likewise: `Pause time`,
`Slower`, `Faster`, `Back 1 hour`, `Forward 1 hour`, `Now`, `Tonight`.

**Same class, different surface, not in scope (do not double-file):** Analytics
▸ History ▸ session card, the icon-row tooltips *Review & Integrate* and
*Session Report* stay in the a11y tree after the pointer has moved on and
accumulate as the pointer sweeps the row.

---

## 4. Disabled `SkotiqButton` — WF-SN-N4 / WF-SCI-N3 — VERIFIED
### with a harness correction the charter's wording depends on

**The literal charter test cannot pass on this bridge.** `drive_linux.py tree`
prints `[DISABLED]` only when a node is interactive **and** carries neither
`enabled` nor `sensitive`. A Flutter disabled button publishes
`['sensitive','showing','visible']` — `sensitive` is present — so the tree can
never print `[DISABLED]` for one. This is the harness fact Wave F recorded; the
discriminator is a direct AT-SPI probe for `enabled`/`focusable` **and for the
advertised actions**, which is what the F-fix actually changed. Probe left at
`/tmp/ns-audit/probe_actions.py` (takes a name substring and the app pid).

Pre-flight **with an error present** (empty sequence → *Cannot Start Sequence*,
`waveG-06`):

```
role='button'
  name='Start Sequence — unavailable: fix the 1 pre-flight error above first'
  states=['sensitive', 'showing', 'visible']
  actions=[]
```

The **Pause** button under the built-in guider (Guiding, guider not running):

```
role='button'
  name='Pause — Pause is a PHD2 feature. The built-in guider has no pause — use Stop to suspend guiding.'
  states=['sensitive', 'showing', 'visible']
  actions=[]
```

Control experiments in the same dialogs, so the signature is discriminating and
not just "this bridge reports nothing":

```
role='button' name='Re-check\nRe-check'   states=['enabled','focusable','sensitive','showing','visible'] actions=['Tap','Focus']
role='button' name='Start Anyway'         states=['enabled','focusable','sensitive','showing','visible'] actions=['Tap','Focus']
```

So: a disabled `SkotiqButton` no longer advertises `SemanticsAction.tap`,
no longer carries `enabled`/`focusable`, and states its reason in its name.
The same node with warnings instead of errors round-trips to the enabled
signature — the same button, both directions.

---

## 5. Science surfaces after a run

Two runs were driven so "most recent" has a wrong answer available:

```
sqlite> select id,name,status,start_time,total_exposures from imaging_sessions;
1|New Sequence|completed|1786687314|3
2|New Sequence|completed|1786687633|6
```

### WF-SCI-N1 — VERIFIED
Immediately after run 2, with run 1 still in the database:
* Analytics ▸ **Session**: `button: New Sequence · Aug 14, 2026 02:07 · 6 frames`
* Analytics ▸ **Science**: `Analysing New Sequence · Aug 14, 2026 02:07 · 6 frames`
  / `6 frames on record`

Both name the 02:07 / 6-frame night, not the 02:01 / 3-frame one. The provider
recomputed on the session-row write the finishing run made.

### WF-SCI-N2 — VERIFIED, both mechanisms
**Refresh forces a recompute.** Session 1's Session Review read *"Not graded —
only 3 light frames were captured; the night needs at least 4 to be judged."*
Clicking **Refresh** wrote a **new** `night_reports` row:

```
before: 1|1|-1|Not graded — only 3 light frames were capture|1786687484
after:  1|1|-1|…|1786687484
        2|1|-1|…|1786687531      <- new row, 47 s later
```

Wave F's decisive negative was that Refresh left `night_reports` at one row.

**And the verdict tracks its own session.** Session 2 (6 subs) reads
**70 / 100 · "Rough night: every sub was graded poor." · Fair · 1 finding**
(`waveG-12`) while session 1 still reads *Not graded*:

```
3|2|70|Rough night: every sub was graded poor.|1786687818
```

Two nights, two content-appropriate verdicts, neither pinned to the other.

**Not exercised, disclosed:** the "a stored report that predates a sub it claims
to judge is recomputed on sight" arm — adding subs to an already-reported
session is not reachable from the GUI (a re-run opens a new session).

### WF-SCI-N4 — VERIFIED
Dashboard standby ▸ Last night card ▸ **Open last run** → the run's own review
screen, `New Sequence · 2026-08-14 02:07`, *6 accepted · 0 rejected*
(`waveG-12`) — the 02:07 run, on the first click, not the empty Sequence
Builder Wave F landed in.

---

## Harness notes worth propagating

* **Probe actions, not just states.** `/tmp/ns-audit/probe_actions.py <substring>
  [pid]` prints role, name, states **and** the AT-SPI action list. The action
  list is what separates a disabled Flutter button (`actions=[]`) from an
  enabled one (`['Tap','Focus']`); states alone cannot, because `sensitive` is
  present on both and `[DISABLED]` therefore never prints.
* **Wait 5 s before judging a toast stack.** WD-EQ-3's second producer lands
  between 3 s and 5 s after the click; a 3 s screenshot shows one card and reads
  as fixed.
* **Two dashboards, one name.** The standby dashboard has two content branches —
  the briefing (Moon / Tonight's targets / Last night, no equipment connected)
  and the connected-idle one (Mount / Safety / Recent events). A finding written
  against "the dashboard, scrolled to the bottom" has to say which.
* The scratch profile survives `stop` + `start` without `--fresh`, which is how
  the standby dashboard (and its Last-night card) is recovered after a run has
  put the cockpit on screen.
