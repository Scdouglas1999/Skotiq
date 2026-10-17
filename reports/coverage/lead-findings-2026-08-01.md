# Lead findings — 2026-08-01

Found by me while building and validating the audit harness, i.e. outside any agent's scope. Each
was observed in a running release build on a scratch profile, not read from source.

---

## L-1 — DOWNGRADED to P3 after further measurement — the app repaints while idle, but the headline number was a software-rasteriser artifact

**Read the correction at the end of this section before acting on it.** The original write-up
follows unchanged, because the measurements in it are accurate; the *interpretation* was wrong and I
am not going to quietly rewrite it.


**Measured** on the release bundle, scratch profile, window focused, no input, per-screen:

| screen    | idle CPU |
|-----------|----------|
| Settings  | 90.3%    |
| Sequencer | 71.8%    |
| Equipment | 68.5%    |
| Dashboard | 62.3%    |

Thread split on the idle Settings screen: `skotiq_desk` (platform/UI) **33.0%**,
`io.flutter.rast` (raster) **30.2%**.

**Why the UI-thread half is the real signal.** These numbers were taken under `softpipe`, a pure
software rasteriser, which inflates raster cost — so the 30% raster figure is not representative of
a real GPU. The **33% on the UI thread is not a rasteriser artifact**: that is Dart rebuilding the
widget tree, and it means frames are being *scheduled* continuously. A genuinely idle Flutter app
schedules no frames and both threads sit near zero.

**Why it matters beyond tidiness.** The headline use case for this app is an unattended rig running
all night, frequently on a laptop or SBC on battery at a dark site. An app that pins a core while
displaying a static screen costs run time directly. It also degrades the app itself — the
accessibility bridge timed out repeatedly during this session purely because the UI thread was
saturated.

**Not yet root-caused.** Two candidates were checked and cleared:
* `status_bar/sequence_indicator.dart:36-48` already gates its pulse on `isRunning` — and its own
  comment says repeating unconditionally was "a large chunk of the app's idle CPU", so this exact
  class of bug has been found and fixed here before.
* No `Timer.periodic` shorter than 1 second exists in the app or the UI package.

There are **16** `AnimationController.repeat()` call sites in `skotiq_app` + `skotiq_ui`,
and a purpose-built `on_screen_animation_gate.dart` utility. **Repro recipe** for whoever takes
this: start any screen, leave it alone, then sample `utime+stime` from `/proc/<pid>/task/*/stat`
over a few seconds — `ps pcpu` is a lifetime average and will hide the problem entirely (it read a
flat "78%" across a change that mattered).

---

### CORRECTION (2026-08-02) — I was wrong about the important part

The claim above that "the 33% on the UI thread is not a rasteriser artifact" **does not survive its
own follow-up experiment.** I resized the window and re-measured, on the reasoning that raster cost
scales with pixel area while widget-rebuilding does not:

| thread | 1600x900 | 640x480 | drop |
|---|---|---|---|
| `io.flutter.rast` | 30.2% | 6.0% | 5.0x |
| `skotiq_desk` (UI/platform) | 33.0% | 2.4% | **13.8x** |
| *pixel area* | | | *4.7x* |

Total idle CPU went 37.6% -> 8.8% against a raster-bound prediction of 8.0% and a logic-bound
prediction of 37.6%. The UI/platform thread fell **faster** than pixel area, so its work was
presentation and blitting under `softpipe`, not per-frame widget rebuilding. My stated reason for
treating this as a genuine P1 was simply incorrect.

**What survives.** Idle CPU is non-zero and proportional to window area, which does mean the app is
**painting while nothing is happening** — a genuinely idle Flutter app schedules no frames and would
sit near zero at any window size. So there is a real repaint-at-idle issue.

**What does not survive.** The magnitude. 60-90% of a core is an artifact of a pure software
rasteriser; on any real GPU this is a small fraction of that. And I cannot distinguish, from these
measurements, between "repainting at 60 fps" and "repainting once a second at ~0.3 CPU-seconds per
full-window softpipe frame" — the 1 Hz status-bar clock alone would produce numbers like these. That
distinction is the whole severity question and it is unresolved.

**Revised severity: P3.** Worth fixing — needless repaints cost power on the battery-powered rigs
this app targets — but it is not the ship-blocker I first called it, and nobody should reprioritise
work on the strength of the original number. Settling it needs a frame counter (a profile build with
the VM service, or `SchedulerBinding.addTimingsCallback`), not more `/proc` sampling.

---

### RESOLVED (2026-08-04) — measured with a frame counter, root-caused, fixed

Built `apps/desktop/lib/frame_timing_probe.dart` (armed by `SKOTIQ_FRAME_TIMING=1`, inert
otherwise) and ran the release bundle idle on the Dashboard:

```text
[frame-timing] window=5.0s frames=8 fps=1.6 buildAvgMs=2.7 rasterAvgMs=265.3 buildP95Ms=8.0 rasterP95Ms=543.7
[frame-timing] window=5.0s frames=6 fps=1.2 buildAvgMs=0.1 rasterAvgMs=229.3 buildP95Ms=0.1 rasterP95Ms=232.8
[frame-timing] window=5.0s frames=4 fps=0.8 buildAvgMs=0.1 rasterAvgMs=231.9 buildP95Ms=0.2 rasterP95Ms=233.9
[frame-timing] window=5.0s frames=6 fps=1.2 buildAvgMs=0.1 rasterAvgMs=233.7 buildP95Ms=0.1 rasterP95Ms=243.1
```

**The answer is 1 Hz, not 60 fps.** Frame counts alternate 4/6 per 5 s window — exactly 1.0 fps with
window-boundary jitter, i.e. a single 1 Hz source. `buildAvgMs=0.1` settles the other half: the
widget tree is **not** being rebuilt, so there was no runaway animation to find among those 16
`repeat()` call sites. It is a paint-only invalidation, and `rasterAvgMs≈230` is simply what softpipe
costs for one 1920x1200 frame. 1 fps x 230 ms accounts for the whole original 60-90% reading with
none of it being real work; on a GPU that frame is ~1-2 ms.

**Root cause:** `_StatusBarState` owned the clock's `Timer.periodic`, so one `setState` per second
rebuilt the entire status bar — every device pill, both action buttons, the enclosing
`LayoutBuilder` — to move one digit, and repainted the parent layer with it.

**Fix:** the tick moved into `_TimeDisplay` (which is the only widget that needs it), behind a
`RepaintBoundary`; the app-lifecycle suspend is preserved unchanged. Pinned by
`status_bar_idle_repaint_test.dart`, which drives Flutter's own rebuild tracer over a one-second
pump, first asserting the tracer captured something (an empty log would satisfy an
`isNot(contains(...))` no matter what the app did) and then that `StatusBar` and `LayoutBuilder` are
absent from it. Revert-checked: restoring a per-second `setState` on `_StatusBarState` fails the test
with its stated reason.

**Post-fix measurement — the fix is smaller than it sounds, and the honest numbers say so.**
Re-measured on a rebuilt release bundle, idle, machine otherwise quiet:

| | frames/5s | fps | buildAvgMs | rasterAvgMs (mean) |
|---|---|---|---|---|
| before | 4/6 alternating | 1.0 | 0.1 | **229.8** |
| after  | 4/6 alternating | 1.0 | 0.1 | **214.2** |

**The frame rate is unchanged, and that is correct** — a clock that shows seconds *must* produce a
frame per second. **The raster cost is not meaningfully changed either:** -6.8% is within the spread
of run-to-run and ambient-load variation, and is not evidence that the `RepaintBoundary` reduced the
rasterised area. The plain reading is that Flutter's Linux GL embedder submits a full-window frame
regardless of damage, so isolating the layer does not cut what softpipe redraws.

So the proven benefit is narrower than "the app repaints less": **the per-second rebuild no longer
touches the rest of the status bar**, which the rebuild-tracer test demonstrates directly. That was
already cheap (`buildAvgMs=0.1`), so treat this as correctness/tidiness rather than a performance
win. Anyone chasing idle cost further should start from the fact that the cost is *rasterising a
full window once a second under a software rasteriser* — on a GPU that frame is ~1-2 ms — and not
from the widget tree.

---

## L-2 — P2 UX — "Skip onboarding" is not honoured: two more tour prompts appear immediately, then one per screen

Clicking **Skip onboarding** on the 13-step setup wizard lands on the Dashboard with **two competing
tour prompts on screen at once**: a modal *"Step 1 of 7 — Welcome to Skotiq"* dialog in the
centre, and a separate *"Dashboard Tour"* card in the bottom-right (visible but dimmed behind the
modal barrier, so it reads as stuck).

Dismissing both does not end it. Navigating to Settings raises a fresh **"Settings Tour"** card.
So a user who has explicitly said "skip the introduction" is asked again on arrival, twice, and then
once more per screen.

*Evidence:* `/tmp/ns-audit/shots/selftest-02.png` (both prompts stacked),
`/tmp/ns-audit/shots/selftest-03-settings.png` (Settings Tour after dismissing Dashboard Tour).

**What it should do.** "Skip onboarding" should suppress the whole first-run tour system, not just
the wizard. If per-screen tours are worth keeping, they belong behind Help, not as an unsolicited
card on every screen. At minimum the two prompts must never be raised simultaneously.

---

## L-3 — P1 — no settings switch is reachable or readable by keyboard or screen reader

On the Settings > General screen, which renders three visible toggles (Start minimized,
Auto-connect equipment, Confirm before closing):

* **Zero** nodes in the accessibility tree report `checkable`/`checked`. The switches expose no
  state at all, so assistive technology cannot say whether any setting is on or off.
* Only **five** focusable nodes exist on the entire screen: one panel, the search field, the
  Language dropdown, and the two tour-card buttons. None of the switches is among them, so keyboard
  focus traversal never reaches them and Space/Enter cannot toggle them.

A keyboard-only user cannot change any setting on this screen, and a screen-reader user cannot
perceive its current value.

**Root cause — one shared widget.** `packages/skotiq_ui/lib/src/components/skotiq_switch.dart:70-75`
builds the switch as a bare `MouseRegion` wrapping a `GestureDetector` with an `onTap`. There is no
`Semantics` wrapper, no `toggled:` state, and no `Focus`/`FocusableActionDetector`, so the framework
has nothing to report and nothing to focus. `SkotiqSwitchRow` (the settings row) composes this
widget, so **every switch in the product inherits the defect** — all 664 settings rows plus the
imaging and session panels that use the same row.

The fix pattern already exists in the same package: `skotiq_chip`, `nav_item`,
`skotiq_stepper`, `adaptive_tab_bar`, `sub_tab_button`, `skotiq_button` and
`hold_to_confirm_button` all wrap themselves in `Semantics`. The switch simply missed it. Wrapping
in `Semantics(toggled: value, enabled: ..., onTap: ...)` inside a focusable action detector fixes
the whole app at one site.

**It is not only the switch.** Of the 30 components in
`packages/skotiq_ui/lib/src/components/`, **9 are interactive but contain no `Semantics` at
all** — and they include both primary form controls:

```
animated_icon_button.dart   histogram_display.dart    skotiq_alert.dart
skotiq_card.dart        skotiq_checkbox.dart  skotiq_switch.dart
skotiq_tooltip.dart     science_info_button.dart  status_pill.dart
```

So checkboxes are in exactly the same state as switches. Since the design system is what the whole
app is built from, this should be fixed at the component level and then guarded — the repo already
runs custom audits under `tools/production/`, and "an interactive component in skotiq_ui with no
Semantics" is a mechanically checkable rule that would stop it recurring.

*Aside:* this is also what defeated a mechanical Tab-traversal sweep of every switch
(`tools/ui_audit/sweep_switches.py`, written for that purpose). The tool is correct and kept; it
will start returning results as soon as the switches are focusable, and its current empty result is
itself the evidence above.

---

## L-4 — P2 — the checkpoint directory ignores the configured data directory

With both `SKOTIQ_DATABASE_DIR` and `SKOTIQ_DATA_DIR` pointed at a scratch profile, the app
logs:

```
INFO Setting checkpoint directory to: /home/scdouglas/.local/share/com.skotiq.desktop
```

Sequence checkpoints — the crash-recovery state that decides whether an interrupted run can be
resumed — are written to the default location regardless. Every other subsystem honoured the
override (the scratch DB was created and used correctly; the real database was untouched).

For a user this means relocating the data directory, to an external disk or a larger volume, leaves
recovery state behind on the system disk, and a restored or moved profile silently loses it.

---

## L-5 — confirms S7 — Switch and Cover Calibrator have no simulator, on every launch

Every one of the 12 app instances launched during this session logged:

```
INFO Discovery complete for Switch: 0 devices, 0 backend errors
INFO Discovery complete for Cover Calibrator: 0 devices, 0 backend errors
```

while every other device type discovered 1. Recorded here because it is now confirmed live and
repeatedly, not only at source. See `simulator-fidelity-backlog.md` S7 for the consequence: the
CalibratorOn/CalibratorOff/OpenCover/CloseCover instructions cannot be exercised at all.

---

## Harness note for later sweeps

`ps pcpu` is a **lifetime average**, not instantaneous. It reported an unchanging "78%" across a
deliberate change and would have hidden L-1 completely. Sample `/proc/<pid>/stat` deltas instead.
