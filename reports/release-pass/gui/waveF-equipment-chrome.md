# Wave F dryness check — equipment-chrome

Driver: `tools/ui_audit/drive_linux.py`, display `:84`, profile `waveE-equipment-chrome`,
`start --fresh`. Build under test:
`apps/desktop/build/linux/x64/release/bundle/skotiq_desktop`
(`lib/libapp.so` stamped 2026-08-13 23:56, i.e. AFTER the E-fix batch).

**Freshness proof (the E-fix strings are in this binary):** `strings lib/libapp.so`
finds `Too low` (WD-SEQ-N4's new chip label) and `No projects yet` (CON-58), and no
longer finds `min capture` (CON-59), `Sim Filterwheel` (WD-EQ-2b's old fallback) or
`Add targets and capture images` (CON-58's old copy).

Evidence: `/tmp/ns-audit/shots/waveF-eq/`.
Probe used for AT-SPI states: `/tmp/ns-audit/probe84.py <substring>`.

Assigned: WD-SEQ-N4, WD-EQ-2b, WD-EQ-3, WD-EQ-4, CON-49/51/52/53/55/56/58/59/62,
WE-EQ-N1, WE-EQ-N2, WE-EQ-N3, WE-EQ-N5, WE-EQ-N6, plus the two KNOWN-OPEN handoffs.

**Result: 13 verified fixed, 3 still broken, 3 new findings. The cluster is NOT dry.**

---

## A harness fact that changes how [DISABLED] must be read

The harness prints `[DISABLED]` when a node is interactive **and** carries neither
`enabled` nor `sensitive`. A Flutter *disabled button* on this bridge publishes
`['sensitive','showing','visible']` — `sensitive` is present, so the tree **never**
prints `[DISABLED]` for a disabled button. A live button publishes
`['enabled','focusable','sensitive','showing','visible']`.

This matters because Wave E called WD-EQ-4 "still ENABLED" on the strength of a
`['sensitive','showing','visible']` dump. That dump was already the *disabled*
signature. The reliable discriminator is the presence of `enabled`/`focusable`,
which the probe prints and the tree does not.

---

## VERIFIED_FIXED

### WD-SEQ-N4 (third strike, now closed) — the chip renders the engine's reason
Repro reconstructed to the same class as the counter-input: Settings → Location
lat **-35**, lon **+21**; Plan Tonight → Projects → New Project "WaveF" → Add
Target **M30**; Plan Tonight → Schedule.
**Seen (`37-queue.png`, 4x crop `38-chip-zoom.png`):** the Scheduler queue row reads
`M30 / altitude 20.0° below site minimum 30.0°` with STATUS chip **`Too low`**, and
the Reasoning box beneath the autopilot card reads
`M30: altitude 20.0° below site minimum 30.0°`. Chip and sentence now agree; the
widget-side `contains('altitude')+contains('below') → "Below horizon"` ladder is
gone from the screen, not just from the engine.

### WD-EQ-2 half (b) — friendly names in RECENT EVENTS
Dashboard with 4 sim devices + a failed built-in-guider connect
(`tree-dash-live.txt:83-103`): the feed reads
`Guider · Built-in Multi-Star Guider`, `Filter Wheel · Simulated Filter Wheel`, and
`Guider/Built-in Multi-Star Guider: Failed to connect built-in guider: …`.
**Stronger than a spot check:** `grep -cE 'native:|sim_[a-z]+_[0-9]' ` over the
**entire** dashboard a11y dump = **0**, repeated at the end of the session = **0**.
The `sim_<type>_<n>` arm is proven by the filter-wheel row (`sim_filterwheel_1`) and
the `native:builtin_guider:*` arm by the guider rows. No third spelling appeared:
Discovery, the feed, the error-toast title and the device card all say
"Built-in Multi-Star Guider" / "Simulated Filter Wheel".

### WD-EQ-4 — the refusal now reaches the bridge *and* the pointer
Standby dashboard, 0 devices (`02-after-skip.png`, `03-editdash-click.png`):
* probe → `role='button'`, `name='Edit Dashboard, unavailable. Nothing to arrange yet
  — the briefing has no tiles. Connect a device or load a sequence to arrange the
  session dashboard.'`, `states=['sensitive','showing','visible']`.
  **No newline** (the doubling signature is gone) and **no `enabled`/`focusable`**.
* the same button with 4 devices connected probes
  `name='Edit Dashboard\nEdit Dashboard'`, `states=['enabled','focusable','sensitive',…]`
  — the two states are no longer byte-identical, which was Wave E's decisive test.
* clicking the disabled control raises the toast *"Nothing to arrange — the briefing
  has no tiles. Connect a device or load a sequence to arrange the session dashboard."*
**No regression from the added `Listener`:** clicking the *enabled* Edit Dashboard
still enters edit mode (`59-editmode.png`: Done / Widgets / Reset, grip handles,
"Edit mode: long-press the grip handle to drag and reorder tiles.").

### WE-EQ-N1 / CON-53 — the copy names a surface that exists
Plan Tonight → Schedule (`29-schedule.png`): *"Runs hands-off and re-picks the best
target all night as the sky changes. For a plan you can see and edit before it runs,
build one in the Scheduler queue below."* The **Scheduler queue** panel is rendered
on the same tab with that exact heading. The orphan "Target Queue tab" is gone;
the Recommendation tab's sibling card also avoids it ("It is a different list from
the builder's Target Queue" — no tab named). See WF-EQ-N3 for the residual on the
word *below*.

### CON-49 — the onboarding footer agrees with itself
Step 1 (`01-onb1.png`, full `tree --all`): the footer is **Next** only; `Back`
appears nowhere in the dump. Step 2 after one Next: `button: Back` is present.
Conditional, not deleted.

### CON-51 — history chips and search are disabled with a reason
Sequencer → History, empty (`24-history.png`): all seven chips are dimmed and
publish as `Completed, unavailable. No runs yet — there is nothing to filter.`
(…Failed / Aborted / Stopped / Stopped (resumable) / Interrupted / Running), none of
them live; the search field reads `No runs to search`. Probe: `states=['sensitive',…]`
with no `enabled` — disabled, not merely styled.
*Note (existing class, not a new finding):* the disabled chips publish as `panel`,
so a reader hears the reason but not "button, disabled" — same class as CON-47 /
NEW-C2, which is tracked elsewhere.

### CON-52 — one heading treatment across the Sequencer
Builder `Sequence Builder / Assemble the instructions tonight's run executes.`
(previously **no heading at all**), Templates `Sequence Templates / Start with a
template or save your sequences for reuse.`, Sequences `Sequence Library / Browse and
load your saved imaging sequences.`, History `Execution History / Past sequence runs
with statistics and performance data.` — 24 px title + one sentence ending in a full
stop, on all four. (`22-seq.png`, `23-templates.png`, `24-history.png`, tree dump.)
See WF-EQ-N1 for what this widget does at 1000 px.

### CON-55 — the Framing warning action is a real button
Plan Tonight → Framing: tree `button: Edit Profile`; probe
`role='button' states=['enabled','sensitive','showing','visible']`. Matches the
sibling `button: Open Settings` on the Recommendation tab. Was `panel: Edit Profile`.

### CON-58 — one creation path for a project
Analytics → Projects with no projects (`42-anaproj-empty2.png`): *"No projects yet /
Create a project in Plan Tonight → Projects, then the frames you capture for its
targets accrue here."* + **New Project**, which navigates to Plan Tonight → Projects
(tree after the click shows the planner tab row and `button: WaveF`). Plan Tonight →
Projects says *"No projects yet"* + New Project. Same words, same path.

### CON-59 — the duration column contains durations
Sequencer → Templates (`23-templates.png`): `~1 hr 15 min`, `~3 min`, `~3 hr 30 min`,
`~10 min`, `~16 hr (multi-night)`. The trailing "capture" is gone from both rows;
`strings libapp.so | grep -c "min capture"` = 0.

### WE-EQ-N2 — a snackbar no longer covers the tour nudge
Equipment with the Equipment Tour card up → connect Simulated Mount
(`08-mount-toast.png`, taken 2 s after the click): the snackbar *"Connected to
Simulated Mount"* occupies root-image y 543–580 and the card occupies y 578–670 —
its title (596), body (615–629) **and its Maybe Later / Start Tour row (656)** are
all clear. Wave E's shot had the toast sitting on the action row. See WF-EQ-N2 for
the surface this fix does not cover.

### WE-EQ-N3 — the Dashboard's primary actions are buttons again
Dashboard with 4 devices: tree `button: Image tonight`, `button: Sequencer` (no
`[DISABLED]`); probe `Sequencer` → `role='button'`,
`states=['enabled','sensitive','showing','visible']`. Was `panel: … [DISABLED]`.

### WE-EQ-N6 — the filter-wheel card shows its whole name
Equipment, 1600x900, Discovery collapsed (`12-cards.png`, full-res crop
`13-fwcard-crop.png`): the FILTER WHEEL card title reads **`Simulated Filter Wheel`**
complete, shrunk to fit, with no ellipsis, in the same column width as the camera,
mount and focuser cards.

---

## STILL_BROKEN

### WD-EQ-3 (P3) — the dedupe key misses by one character
**Repro:** Equipment → Discovery → Connect **Built-in Multi-Star Guider**, once.
**Actual (`16-guider-fail.png`, 3x crop `21-toast-zoom.png`):** three stacked toasts,
two of which are the same refusal shown twice with **no `(x2)` count**:

```
Guider Error
Failed to connect built-in guider: Operation failed:
Built-in guider requires an active profile with a guide focal length      <- no full stop
Guider Error
Failed to connect built-in guider: Operation failed:
Built-in guider requires an active profile with a guide focal length.     <- full stop
```

The E-fix collapses notifications identical in `(level, title, body)`. The two
producers emit bodies that differ **only by a trailing `.`**, so the key never
matches and the operator sees the identical sentence twice, exactly as in Wave D and
Wave E. The dedupe is real code that cannot fire on the one case it was written for.
A closer must either normalise the body (trim trailing punctuation/whitespace) before
keying, or fix the producer that appends the stop.

### CON-62 (P4) — partial: one verb, still two treatments and two cases
Settings → Help & Tutorials (`44-help.png`, `45-help2.png`).
* **Fixed:** all five Guided Flows rows now read `Start` (was Start / Start / Re-run /
  Re-run / Open) and all five are outline buttons.
* **Still broken (a), batch-disclosed:** the titles still mix Title Case and sentence
  case in one list — `First Night Walkthrough`, `Capture your first light`,
  `Re-run equipment setup`, `Re-run onboarding tour`, `Generate Diagnostic Dump`.
  The batch recorded this as blocked on regenerating `settings_search_index.g.dart`.
* **Still broken (b), NOT disclosed:** the *treatment* split did not go away, it moved
  down the page. The five Tutorial Tours rows (Equipment Setup, Target Planning,
  Automated Imaging, Calibration Frames, Advanced Features) render **filled blue**
  `Start` buttons directly beneath the five **outline** `Start` buttons of Guided
  Flows. One page, one verb, two treatments for the same action.

### WE-EQ-N5 (P4) — partial: the strip still does not fit 1000 px
`resize 1000 800`, 4 devices connected (`46-narrow.png`, 4x crop `49-sb-zoom.png`).
* **Fixed:** the camera pill now truncates inside itself with a visible ellipsis —
  `Simulated Ca…` followed by its green state dot.
* **Still broken:** the next pill still renders **`Si`** sliced mid-word with no
  ellipsis, fading into the viewport edge, immediately before a `>` scroll chevron.
  The fix's premise — "cap their value at 88 px **so the strip fits a 1000 px bar**"
  — is falsified on screen: the strip does not fit, it scrolls, and the item at the
  cut is still a mangled device name. (The chevron is new and is an improvement.)

---

## KNOWN-OPEN, confirmed still broken (handed off, not relitigated)

* **WD-EQ-2 half (a)** — the disconnect toast still interpolates the raw id:
  *"Equipment disconnected / Guider **native:builtin_guider:multi_star** disconnected."*
  (`21-toast-zoom.png`, third card). Owner: `notification_router.dart` +
  `event_classifier.dart`, which the E-fix batch reverted rather than collide with a
  concurrent batch.
* **CON-56** — Plan Tonight → Planetarium still exposes `button: NOW` and
  `button: TONIGHT`. Owner: `skotiq_planetarium/.../time_control_panel.dart`,
  reassigned to the sky-planetarium batch.

---

## NEW FINDINGS

### WF-EQ-N1 (P3) — the new Sequencer heading truncates its own subtitle at 1000 px
**Repro:** `resize 1000 800` → Sequencer → Templates, then → Sequences.
**Actual:** Templates renders `Sequence Te…` / `Start with a template or sav…`
(`52-templates-narrow.png`); Sequences renders `Sequenc…` / `Browse and load yo…`
(`50-seq-narrow.png`), while the search field beside it collapses to `Search s…`.
The heading is given roughly a third of the row and the toolbar keeps the rest, so
both the title and the one-sentence subtitle CON-52 mandated are unreadable.
**Not universal:** the Builder's copy of the same widget, which owns a full-width row,
renders `Sequence Builder / Assemble the instructions tonight's run executes.`
complete at the same window size (`53-builder-narrow.png`) — so this is the shared
`SequencerTabTitle` competing with a toolbar, not the window size alone.
**Why it matters:** CON-52 existed to make these tabs self-describing; at a supported
desktop width the added sentence is destroyed, and on Sequences the *title* no longer
identifies the tab.

### WF-EQ-N2 (P4) — the tour-nudge inset covers snackbars only, not the notification toasts
**Repro:** Dashboard, 0 devices, Dashboard Tour nudge visible → click the disabled
**Edit Dashboard**.
**Actual (`03-editdash-click.png`):** the refusal is delivered by the
`NotificationToastOverlay` (icon + title + body + × dismiss), which paints across the
nudge card's title and body (toast y 565–641 over card y 578–670). The nudge's
`Maybe Later` / `Start Tour` row at y 656 stays clear, so this is milder than the
WE-EQ-N2 it descends from — but it shows the `TransientBottomInset` the E-fix added
is honoured by the SnackBar path only, while the surface that carries **errors** is
still free to paint over the card.
**Why it matters:** low stakes today; it is the same collision WE-EQ-N2 was raised to
remove, surviving on the other of the app's two toast surfaces.

### WF-EQ-N3 (P4) — "the Scheduler queue below" is beside it, not below it
**Repro:** Plan Tonight → Schedule at 1600x900 (`29-schedule.png`, `37-queue.png`).
**Actual:** the Unattended Autopilot card says *"…build one in the Scheduler queue
**below**."* while the Scheduler queue panel is rendered in the **right-hand column,
beside the card**, from the same y. The E-fix's own note ("rendered directly beneath
the card") is true only at a stacked width.
**Why it matters:** the fix's whole point was to stop sending the operator somewhere
that is not there; the destination is now on screen but the direction word is wrong,
which is the weakest possible version of the same complaint. Naming it without a
direction ("in the Scheduler queue on this tab") would close it.

---

## Notes for the next verifier

* Do not read `[DISABLED]`'s absence as "enabled" on a Flutter button — see the
  harness note at the top. Probe for `enabled`/`focusable` instead.
* Toasts fade in about 4 s: a `shot --region` issued after a full `tree` will miss
  them. Click, then shoot immediately; crop the saved full shot afterwards.
* `resize` moves the window origin, so `click-img` against a pre-resize screenshot
  silently misses. Take a fresh `shot` after every resize (this cost two clicks here).
* The Wave E route "Scheduler queue → Open target catalog" lands on Plan Tonight →
  Projects, not a catalog; a low target is fastest to stage as
  New Project → Add Target → M30 with the site at lat -35 (M30 sits near 20° there).
