# Wave E — dryness check: sky-planetarium

Bundle: `apps/desktop/build/linux/x64/release/bundle/skotiq_desktop`
(launcher 18:31, `lib/libapp.so` **20:33**). Freshness proved by byte-grep before
launching: the .so contains `switch to Alt/Az` (UTF-16LE, 1 hit — the SKY-16
string), `Choose a date` and `Switch to Custom RA/Dec` (the D-3 / SKY-4 strings),
and **zero** hits for the old `tap for Alt/Az`.

Harness: `tools/ui_audit/drive_linux.py`, display `:85`, profile
`waveE-sky-planetarium`, `--fresh`. Onboarding skipped, then Settings → Location
set to **lat 40, lon −75** so LST is checkable: at wall 20:36:16 EDT the status
strip read `LST 17:06` and an independent GMST computation gives **17:06:15**.
That agreement is the baseline every D-1 measurement below is read against.

Nothing was fixed. Nothing was edited.

---

## Assigned items

### SKY-4 (P2) — "Create region" clickable with no target — **VERIFIED FIXED**

Discover → Your Sky → **Name a region**, `From a target`, empty library.
The sheet no longer offers the dead action at all: the primary button is
`Switch to Custom RA/Dec` and the a11y tree contains **no** `Create region` node
(`shots/waveE-sky-sky4-empty-library.png`; full dump: `button: From a target`,
`button: Custom RA/Dec`, `panel: No targets in your library yet — switch to
Custom to enter a sky position by hand.`, `button: Cancel`, `button: Switch to
Custom RA/Dec`).

Adversarial follow-through, because a relocated dead button would be the obvious
way for this fix to fail:

* the escape hatch works — clicking it switches the sheet to Custom RA/Dec and a
  `Create region` button appears there;
* pressing that `Create region` with the fields empty does **not** silently
  no-op: it renders `Enter RA as 05h 35m 16s or 83.82°, Dec from -90° to +90°,
  and a radius greater than 0° and no more than 180°.` in the error colour;
* the happy path completes — RA `00h 42m 44s`, Dec `+41 16 09`, name
  `Andromeda test` produced a real region card reading `Andromeda test / 0h 43m ·
  +41° 16' / Custom` and `Regions — 1 region · none imaged yet`
  (`shots/waveE-sky-region-created.png`). The live parse echo
  (`Reads as 00:42:44.00 +41:16:09.00 (10.683°, 41.269°)`) is correct.

### SKY-10 (P3) — wheel zoom ignores the pointer — **VERIFIED FIXED**

Measured three ways.

1. **Equatorial, zoom in.** Pointer parked on Vega at root (855,639) — image
   (556,391) — wheel up 10. FOV `60.0° → 12.5°`, centre `17h 6m 24s / +40° 0'` →
   `18h 19m 3s / +38° 37'` (i.e. it walked toward Vega at 18h37m/+38.8°), and
   Vega itself finished at image (566,390): **≈10 px** from the cursor across a
   4.8× zoom. `shots/waveE-sky-sky10-wheel-anchor.png`.
2. **Alt/Az, zoom in.** Reset to zenith, pointer on Arcturus at root (372,359) —
   image (298,287) — wheel up 8. FOV `60.0° → 16.5°` and Arcturus finished at
   image (296,285), **2 px** from the cursor. The anchor therefore survives the
   frame change, which is what the iterative re-centre was supposed to buy.
   `shots/waveE-sky-sky10-altaz-anchor.png`.
3. **Zoom out.** Pointer on M3 at root (887,470) — image (710,376) — wheel down
   6. FOV `16.5° → 39.9°`, centre moved to `13h 32m 18s / +28° 41'`, and M3
   finished at image (709,375): **1 px**. Anchoring is symmetric.

Also probed for collateral: wheeling with the pointer over the time-transport
panel (root 910,762) changed nothing (FOV stayed 39.9°, centre moved 0), so the
new `Listener` did not start swallowing scrolls destined for chrome; and the
search fly-to still works (M31 → `Center RA: 0h 45m 9s / Center Dec: +41° 16'`,
`Selected Alt: 49.4° Az: 69.6°`), so the anchor is correctly dropped on fly-to.

### SKY-16 (P4) — desktop UI says "tap" — **VERIFIED FIXED**

Hovering the coordinate-mode button renders `Equatorial view — switch to Alt/Az`
(`shots/waveE-sky-sky16-tooltip.png`). No touch verb anywhere on the bar.

### D-1 (P3) — simulated LST beside a real clock — **VERIFIED FIXED**

Plan Tonight → Planetarium → step-forward ×5 (`+5 h`). Planetarium clock read
`Aug 14, 2026 01:37:49` while the status strip read `20:37:50 / LST 17:07` —
i.e. the true LST for the real instant, not the `~22:07` the scrubbed clock
would have produced. `shots/waveE-sky-d1-scrub-lst.png`.

Held under a *running* scrubbed clock too: with the transport at `+1m/s` the
planetarium clock ran to `20:43:37` against a wall clock of `20:41:39` and the
strip still showed the true `LST 17:11`.

Adversarial check that the fix did not simply freeze the planetarium's own
astronomy: in Alt/Az, reset-to-zenith then `+3 h` moved the zenith from
`Center RA: 17h 15m 51s` to `20h 23m 21s` — +3h07m of sidereal rotation for
3 h of solar time, and the star field rotated with it. The preview clock still
drives the sky; only the shared LST readout was re-pointed.

### D-2 (P3) — planetarium tooltips never leave the a11y tree — **STILL BROKEN**
*(disclosed as blocked/out-of-scope by the D-fix batch; no code changed, and it
still reproduces exactly as Wave D wrote it.)*

Hovered the five toolbar icons at root y=264, x=621/659/695/744/795 for ~1.8 s
each, parked the pointer at root (1100,900) over the star field, waited 12 s.
`tree --all` still lists `panel: Reset view (zenith, FOV 60)`,
`panel: Projection: Stereographic` and `panel: Layers`, while the screenshot
taken at the same instant shows a completely clean command bar
(`shots/waveE-sky-d2-tt-clean-screen.png`). Owner is
`packages/skotiq_ui/lib/src/components/skotiq_tooltip.dart`.

### D-3 (P3) — transport buttons have no accessible names — **PARTIALLY FIXED**

**Fixed half (the headline):** the five transport controls now carry names and
the play/pause control carries a state. Playing:

```
button: Aug 13, 2026        <- was `panel: Aug 13, 2026 [DISABLED]`
button: Pause [off]
button: Slower
button: Faster
button: Back 1 hour
button: Forward 1 hour
```

and after clicking it, `button: Play [ON]` with `PAUSED` rendered in the strip.
The date chip is a real, enabled button.

**Still broken half:** D-3's own summary also named the search field and the
readout strip, and both still report exactly as Wave D found them, on the same
dump:

```
panel: Search
Ctrl+K [DISABLED]
panel: 20:37:18 / 1× / Center RA: 17h 6m 24s / Center Dec: +40° 0'
       / FOV (short axis): 60.0° / Bortle: 5 (lim 5.9m) [DISABLED]
```

(The harness prints `[DISABLED]` on a `panel` only when the node is
focusable/selectable/checkable *without* `enabled`/`sensitive` — so these two are
publishing themselves as interactive-but-dead, not being mislabelled by the
tool.)

### D-4 (P4) — Layers drawer covers the transport at 900 px — **VERIFIED FIXED**
*(with a new overlap introduced in its place — see E-SKY-1.)*

`resize 900 900`, Planetarium, open Layers. The drawer occupies x 620–900 and the
transport now sits wholly inside x 290–550: the clock renders in full
(`20:40:59`, not `18:46:`) and the fast-forward button is reachable — clicking it
at (487,763) changed the rate chip to `+1m/s` and the clock started running fast.
`shots/waveE-sky-d4-900-drawer.png`.

### Guide-graph `Time:` / `Scale:` selectors must announce as buttons — **VERIFIED FIXED**
*(with information lost in the process — see E-SKY-3.)*

Guiding screen, `tree --all`:

```
panel: Time:
button: Time:
panel: Scale:
button: Scale:
```

Both are `button` role and neither carries `[DISABLED]` — previously they were
`panel: Time: 5m [DISABLED]` / `panel: Scale: ±2" [DISABLED]`. Functionally
intact: clicking `Time:` opens the 1m/5m/15m/30m menu with the current value
highlighted, and picking `15m` updates the trigger pill.

---

## New findings from the adversarial sweep

### E-SKY-1 (P4) — the time transport now collides with the compass and the horizon minimap when a side panel is docked

The D-4 fix insets the bottom chrome by `dockedWidth`, but the compass rose, the
altitude bar and the horizon minimap are inset by the same amount, so at 900 px
they are pushed *into* the transport instead of away from it. In
`shots/waveE-sky-e1-transport-overlap.png` (crop of the 900 px shot with Layers
open) the transport panel spans x 283–555 and covers: the right half of the
compass dial (its `S` label and the `77° / 90°` altitude-bar ticks), and the left
third of the horizon minimap including its `W` label.

Repro: `drive_linux.py resize 900 900` → Plan Tonight → Planetarium → open
Layers. No overlap at the same width with the drawer closed
(`e13`: compass 240–315, transport starts 430), so this is new with the inset.
No overlap at 1600×900 with a drawer open.

Not a blocked control — the transport's own buttons still work — but two readouts
are unreadable in a state the fix itself creates.

### E-SKY-2 (P4) — play/pause announces its action and its state as opposites

`_accessibleControl(label: running ? 'Pause' : 'Play', toggled: !running)` in
`packages/skotiq_planetarium/lib/src/widgets/time_control_panel.dart:341`
swaps *both* the name and the toggle state, so an assistive client reads
"Play, toggle button, **on**" at the moment time is held, and "Pause, toggle
button, **off**" while it is running. Observed live: `button: Pause [off]` with
the clock advancing, `button: Play [ON]` with `PAUSED` in the strip.

The conventional pairings are a stable name plus a state (`Play/pause` +
pressed), or an action name with no state at all. Naming the action *and*
inverting the state is the one combination that reads as a contradiction. P4 —
the fix is a large net improvement over the empty labels it replaced.

### E-SKY-3 (P3) — the guide-graph selectors publish their role but no longer publish their value

`guide_graph_advanced.dart:326` wraps the popup trigger in
`Semantics(button: true, enabled: true, label: label, value: value,
excludeSemantics: true)`. `excludeSemantics: true` drops the child `Text('5m')`,
and the `value:` never reaches AT-SPI, so the selected setting is now **absent
from the accessibility tree entirely**:

* `tree --all` on the Guiding screen returns **0** matches for `5m`; after
  switching the selector to 15m it returns **0** matches for `15m`, and **0**
  for `±2"`. Only `button: Time:` and `button: Scale:` remain.
* Direct AT-SPI probe of both button nodes:
  `interfaces: ['Accessible','Action','Collection','Component']` — no `Value`,
  no `Text`; `get_description()` is `''`.

Before the fix the merged node was at least named `Time: 5m`. A screen-reader
user could previously hear the value and not the role; they can now hear the role
and not the value. Net, the tree carries less information about the guide graph's
X and Y scales than it did at HEAD. Same shape as the "relocating the defect"
pattern this campaign has hit before.

---

## Not defects (checked and cleared)

* The `impl_get_CurrentValue: assertion 'ATK_IS_VALUE (user_data)' failed` /
  `impl_GetText` CRITICALs at 20:44:30 in the app log are **my own** AT-SPI probe
  asking the selector nodes for interfaces they do not implement, not app
  behaviour.
* `Timed out waiting for OpenGL frame of size 900x900` is the harness resize
  under softpipe; the window reflowed correctly both directions.
* Wheeling over chrome does not zoom the sky; fly-to and reset-to-zenith both
  drop the wheel anchor as designed.
* No Dart exception, no error banner and no toast appeared anywhere in the run.

## Coverage note

Everything above was driven on the running release bundle. The one thing this
pass could not measure is whether `wallClockProvider`'s 1 Hz notifier changes
idle repaint cost on screens that watch `localSiderealTimeProvider`; the shell
strip already rebuilt at 1 Hz from the previous provider, so no new class is
suspected, but it was not instrumented.
