# Wave G spot-check — sequencer half

Closing spot-check of the F-fix batches `exposure-integrity`
(`reports/release-pass/impl/ffix-exposure-integrity.md`) and `stop-toasts-scheduler`
(`reports/release-pass/impl/ffix-stop-toasts-scheduler.md`), driven live against the FRESH
release bundle. **Nothing was fixed in this pass.**

Orientation: one `graphify query "meridian flip trigger waits for in-flight exposure;
sequencer stop toast; node progress frames counter"` (returned the web run-watch community
and nothing load-bearing; the neighbourhood was located from the two F-fix logs).

---

## Harness and bundle freshness

* Binary: `apps/desktop/build/linux/x64/release/bundle/skotiq_desktop`, driven by
  `tools/ui_audit/drive_linux.py` (profile passed **after** the subcommand), display `:86`,
  profile `waveG-sequencer`.
* `lib/libapp.so` and `lib/libskotiq_bridge.so` both mtime **Aug 14 01:44**, i.e. after
  the three F-fix commits (`df728a6ce` / `16bbe47c0` / `482f3e247`, all 01:42). String-grep
  of the shipped binaries finds the strings each fix introduced:
  * `Sequence stopped by request at ${time.clock}.` — the WF-STOP-N5 operator-clock body;
  * `no progress for ` — the WF-STOP-N4 stall replacement for the ETA;
  * `trigger:meridian_flip` in `libskotiq_bridge.so` — the WF-STOP-N4 retry-surfacing
    synthetic node id.
  This is the binary the F-fix landed in.
* Profile seeded from `/tmp/ns-audit/waveE-stop-pipeline/data` with `sequence_runs`,
  `captured_images`, `imaging_sessions`, `sequence_checkpoints` and `sequence_decisions`
  emptied, and the observer site moved to **lat +30.0 / lon −85.3** so that the drive ran in
  real astronomical night (Sun −45°, app header `Dark 3h 53m left`) with **LST ≈ 21:36** at
  start — the daylight gate that blocked the Wave F re-run never fired.
* Devices: Simulated Camera / Mount / Focuser connected via Equipment ▸ Discovery; mount
  **Unparked** and **Tracking** before the first run.
* Harness note kept from Wave F: every click is `xdotool mousemove` → `sleep 0.7` → `click`,
  because the first click after a bare pointer move is swallowed.
* Working captures in `/tmp/ns-audit/waveG-sequencer/`; the ones cited here are copied to
  `reports/release-pass/gui/shots/waveG-sequencer/`.

## The four runs

| run | started | sequence | outcome |
|---|---|---|---|
| 15 | 01:52 | Target RA 21.5333h Dec +30 (transit **01:42**), 2 × `Take Exposures` 4 × 15 s | node 1 completed 4 frames, node 2 reached 3, **operator Stop at 01:54:26** |
| 16 | 01:58 | same + `Slew to Target` appended | Completed 8/8 |
| 17 | 02:01 | same, mount now slewed to and tracking the target | Completed 8/8 |
| 18 | 02:08 | counts reduced to 1 + 1, target RA 16.95h | Completed 1/1 (see note at the end) |

---

## Verdicts

| item | verdict |
|---|---|
| WF-STOP-N1 — flip must not stomp the in-flight frame | **NOT VERIFIED (blocked)** — the oracle on `captured_images` passes, but no meridian flip could be made to fire, so the mechanism itself is untested |
| SEQ-18 — completed node reads N/N | **VERIFIED** |
| WF-STOP-N2 — one integration on every surface | **VERIFIED** (with one stated limitation) |
| WF-N4 / WF-STOP-N3 — one Stop, one toast | **FAILED** — one Stop still raises **two** toasts, one of them a red `Sequence Error`, and **three** RECENT EVENTS rows |
| WF-STOP-N5 (first half) — no ISO timestamp in operator copy | **VERIFIED** |
| WF-STOP-N4 — retrying flip must not claim Running with a past ETA | **NOT REACHABLE** — the simulator produced no flip at all, so nothing stalled |

---

## 1. WF-STOP-N1 — NOT VERIFIED (blocked)

**The DB oracle passes.** Across all four runs, 24 light frames:

```
sqlite> select producing_node_id,count(*),min(exposure_duration),max(exposure_duration)
        from captured_images group by producing_node_id;
3d769059-…|11|15.0|15.0
dc922096-…|13|15.0|15.0
```

Every light frame reads **15.0**, including every node's *first* frame. The 5.0 s first
light frame Wave F recorded did not recur once.

**But the second half of the oracle — "and the flip must still run" — fails.** No meridian
flip fired in any of the four runs, so the claim protocol the fix installed was never
exercised. Three separate configurations were tried:

1. *Mount parked at RA 0 h, target 10 min past the meridian* (run 15). The burst now prints,
   before every frame, a warning that did not exist in Wave F:

   > `WARN Not holding the next 15s exposure for a meridian flip: the target is +0.17h past
   > the meridian but the mount reports hour angle -2.30h, so the flip trigger cannot fire.
   > Exposing instead of waiting for a flip that will not happen — check that the mount is
   > tracking the target.`

   This is the pre-frame gate telling the truth, and it also tells us the gate keys on the
   **mount's** hour angle, not the target's. Wave F's flip fired because its mount sat at
   RA 0 h while LST was ≈ 07 h — i.e. the *mount* was 7 h past the meridian, not the target.

2. *Mount slewed to the target and tracking it, 19–24 min past the meridian* (run 17), with
   `enable_meridian_flip=true`, `minutes_past=5.0`, `auto_center=true`, `max_retries=3`.
   The run captured 8/8 frames back-to-back with **no flip, no wait, and no warning after
   frame 1**. The frame-1 warning read `…but the mount has not reported a position, so the
   flip trigger cannot fire`; from frame 2 on the warning stopped and nothing replaced it.
   Session Report for that run: **Meridian flips 0**, Trigger fires 1 (the dither)
   — `shots/waveG-sequencer/g32-ops.png`.

3. An attempt to reproduce Wave F's geometry by slewing the mount 5 h past the meridian was
   defeated by the run-18 skip described at the end of this file.

**What this means for the release.** The recorded-duration half of the F-fix is holding on
every frame this drive produced. The claim/`camera_driving_trigger_action` half is
**unverified on the binary** — it is pinned only by the Rust test
`every_camera_driving_trigger_action_waits_for_the_frame_in_flight`. A run whose mount is
tracking a target well past the meridian, with the flip enabled, silently images straight
through the meridian; on a real GEM that is the mount-into-pier case. Whether that is an app
defect or a simulator that never reports a pier side needing a flip cannot be separated from
outside the process, so it is recorded as an observation, not adjudicated here.

## 2. SEQ-18 — VERIFIED

The fifth-look fix holds on screen, in all three states, and it distinguishes the two things
the counter exists to distinguish.

* **Mid-run, the moment node 1 finished** (`g13-midrun.png`): node 1's card shows four filled
  green boxes; node 2's card, six pixels below, reads **`0 / 4 frames`** with four empty
  boxes. Same screen, same instant.
* **Mid-run, scrolled to the label** (`g14-node1card.png`): node 1 reads **`4 / 4 frames`**
  — the assertion four previous fixes could not make hold — while node 2 reads `1 / 4 frames`
  and the run header reads `Progress 5/8`.
* **After the operator Stop** (`g22-slew.png`): node 1 still reads **`4 / 4 frames`** with
  four filled boxes; node 2 reads `3 / 4 frames`. The tally survives the terminal transition
  rather than being retired with the run.
* **After a fully completed run** (`g30-expand.png`, `g33-sel.png`): both nodes read
  **`4 / 4 frames`**.

Ground truth agrees: 4 rows in `captured_images` against node `dc922096-…` for that run and
3 against `9617e5f0…`/`3d769059-…`.

*Deviation from the charter, stated plainly:* the charter asked for node 2 at `0 / 4` **after**
the Stop. By the time the Stop landed node 2 had captured 3 frames, so the post-stop pair is
`4 / 4` vs `3 / 4`. The `4 / 4` vs `0 / 4` pair is captured **mid-run** instead
(`g13-midrun.png`), which makes the same point — the card can tell "captured everything" from
"captured nothing" — and the post-stop screenshot proves the count is not reset by the stop.

## 3. WF-STOP-N2 — VERIFIED (one limitation)

For the stopped run (run 15, 7 frames):

| surface | integration |
|---|---|
| Session Report ▸ Integration | **1m 45s** |
| Session Report ▸ target row `New Target 7/7 frames \| 1m 45s` | **1m 45s** |
| Execution History row | **1m 45s** (`g42-hist.png`) |
| `sequence_runs.stats_json.integrationSecs` | **105.0** |
| `sum(captured_images.exposure_duration)` | **105.0** |

Checked for all four runs, and every one agrees on all five surfaces:

```
15|paused-stopped|7 frames|105.0     history: 7 · 1m 45s · Stopped (resumable)
16|completed     |8 frames|120.0     history: 8 · 2m 0s  · Completed
17|completed     |8 frames|120.0     history: 8 · 2m 0s  · Completed
18|completed     |1 frame |15.0      history: 1 · 15s    · Completed
```

The Dashboard **Last night** card (visible after a restart, `g41-crop.png`) reads
`New Sequence — Completed · 1 minute ago — 15s integration · 1 frames · 16s duration` for
run 18, matching its Session Report (`Integration 15s`, `Frames accepted 1/1`) and the
Continue-Session dialog (`1/1 frames captured, 15s integration`). The Wave F symptom — 50 s
on one surface and 1 m 0 s on three others — does not reproduce anywhere.

*Limitation, so this is not over-claimed:* in the simulator the camera's reported exposure
always equals the command, so `planned == recorded` for every frame tonight. This drive
proves the surfaces **agree**; it cannot discriminate the old `frames × plan` formula from
the new sum-of-rows one, because the two produce the same number here. That discrimination
remains pinned only by
`the_frame_callback_reports_recorded_seconds_not_planned_ones`.

*Minor, recorded not filed:* run 18's duration reads `16s` on the Last-night card and
`17s` as Session Report wall clock — two clocks, one second apart.

## 4. The Stop story — FAILED on the toast/feed count, VERIFIED on the copy and the reports

One operator Stop, pressed once at **01:54:26** (verified: the only other Stop-shaped click
this session landed on empty chrome and produced no log line).

**FAILED — WF-N4 / WF-STOP-N3.** Two toasts, not one, and the pair is worse than a
duplicate (`g15-toasts.png`, cropped from `g15-stopclick.png` taken ~2 s after the click):

> ⊗ **Sequence Error** — *Sequence cancelled*  (red, error styling)
> ⓘ **Sequence stopped** — *Sequence stopped by request at 01:54.*

The red `Sequence Error / Sequence cancelled` toast is the exact cry-wolf shape the E-fix
removed and Wave F recorded as gone ("no red, no `Critical`, no `failed`, no `aborted`"). It
is back. The router's new per-transport content dedupe evidently collapsed the three
identical **info** notices into one, and a differently-worded **error**-classified producer
now shows through beside it rather than being reclassified.

RECENT EVENTS still triplicates (`g19-events.png`), all at `01:54:26`:

```
ⓘ Sequencer  Sequence stopped                                   01:54:26
ⓘ Sequencer  Decision logged  system_event #15: Sequence cancelled
ⓘ Sequencer  Sequence stopped                                   01:54:26
ⓘ Sequencer  Sequence stopped   Stopped by request              01:54:26
ⓘ Sequencer  Progress ×3  7 / 8                                 01:54:26
```

Three `Sequence stopped` rows for one Stop — the feed count is unchanged from Wave F. All
rows are INFO level, so the feed does not cry wolf; it just says the same thing three times.
The `Decision logged — system_event #15: Sequence cancelled` row is the half of WF-STOP-N5
the F-fix log explicitly declared out of scope, and it is still present exactly as declared.

**VERIFIED — WF-STOP-N5, first half.** The toast body is
`Sequence stopped by request at 01:54.` — 24-hour operator clock, no ISO-8601, no
microseconds, no zone. The Wave F string `…at 2026-08-14T00:13:25.206940.` is gone.

**VERIFIED — the reports and banners tell the stopped story.**

* Session Report (`g16-report.png`, and the scrolled tail `g17-report2.png`): title
  **`New Sequence - Stopped (resumable)`**, `Integration 1m 45s`, `Frames accepted 7/7`,
  `Frames rejected 0`, and **no Errors and no Warnings section at all** — only a Diagnostics
  note (`Cooler Out of Setpoint Band`) and an empty Journal.
* Dashboard header after the stop (`g18-dash.png`): no red banner; it reads
  **`Sequence ready — start tonight's run.`** with a green **Ready** chip, and the thumbnail
  strip shows seven frames each labelled `15s`.
* Execution History row and Dashboard Last-night card both use the same vocabulary,
  `Stopped (resumable)` — no `Paused-stopped` enum anywhere.

## 5. WF-STOP-N4 — NOT REACHABLE

The stall replacement (`no progress for …`) and the retry-surfacing node id
(`trigger:meridian_flip`) are both present in the shipped binaries, but nothing in this
harness could stall a flip: no flip ran at all (see item 1), so no run ever went quiet with a
promised finish time. Skipped as the charter permits, with the binary-level evidence
recorded so a live-rig night can close it.

---

## Observations recorded on the way (not fixed, not adjudicated)

1. **A run that skipped two thirds of its target reports `Completed` with no disclosure.**
   Run 18's target had three children (`Take Exposures` ×1, `Take Exposures` ×1,
   `Slew to Target`). After the first child the executor logged
   `Skipping remaining children in node 092bc477-… due to next-target request` and
   `Child 'Target' completed with status: Skipped`, yet the Session Report title reads
   **`New Sequence - Completed`**, `Frames accepted 1/1`, with nothing anywhere saying two
   instructions were skipped (`g39-stall.png`). This is the class this campaign exists to
   remove — the run's own log knows more than any operator surface says.
2. **The node tally is stale between runs after an edit.** Changing a node's exposure count
   in the builder leaves the previous run's `4 / 4 frames` and filled boxes on the card
   (`g35-n1.png`, `g36-counts.png`) until the next run starts and clears it. Cosmetic, and
   consistent with the F-fix's deliberate "cleared at run START, not at run end" rule, but
   the card is then describing a plan it no longer matches (`1 ×` with `4 / 4 frames`).
3. **New honest-disclosure lines are working.** Three warnings that Wave F did not have all
   fired correctly and read like sentences: the meridian gate warning quoted above, the
   guider one (`Dither requested after frame 3/4 but no guider is configured — skipping
   dithers for the rest of this burst. Frames will be UNDITHERED (walking noise)…`), and the
   safety one (`No safety monitor or weather device configured … treating as safe (FailOpen).
   Do not use FailOpen for unattended runs.`).
4. **Pre-flight is accurate about the mount.** With no slew instruction it warned
   `Mount Is Not Pointing At New Target — the mount is 46° away … the run would expose
   wherever the mount happens to be and file every frame under New Target`; after adding
   `Slew to Target` the warning disappeared. That warning is exactly what the run-15 log then
   confirmed.
