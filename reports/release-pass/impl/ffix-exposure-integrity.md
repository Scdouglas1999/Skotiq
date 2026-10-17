# F-fix batch `exposure-integrity`

Items: WF-STOP-N1, WF-STOP-N2, WF-STOP-N4, SEQ-18 (fifth look).
Evidence: `reports/release-pass/waveF-result.json`, `gui/waveF-stop-pipeline.md`, and the
run's own log at `/tmp/ns-audit/waveE-stop-pipeline/app.log` — which turned out to
contain the mechanism for three of the four items, to the microsecond.

Constraints honoured: one graphify query first (it surfaced nothing useful and the
neighbourhood was located by targeted grep from there), no GUI harness, no bundle
rebuild, no git writes, no melos, no repo-wide formatters (`dart format` on the eleven
files touched, `cargo fmt -p skotiq_sequencer`), no generated files, no FRB regen —
no wire type was added, only an internal `ProgressUpdate` field.

---

## The one log excerpt that explains three of the four items

```
04:09:10.792627  Starting 15.0s exposure on camera sim_camera_1     <- burst frame 1
04:09:10.793593  Trigger fired: Meridian Flip (meridian_flip)       <- 1 ms later
04:09:11.795844  Starting 5.0s exposure on camera sim_camera_1      <- the flip's solve
04:09:17.133044  Saving FITS … New Target_nofilter_0001.fits (New Target frame 1 (5.0s, …))
...
04:10:05.978189  Child 'Take Exposures' completed with status: Success
04:10:05.978204  [PROGRESS_CB] Emitting NodeStarted: id=9617e5f0…   <- the NEXT node
04:10:05.978257  NodeProgress node=7837c026… instruction=Exposure          progress=100%
04:10:05.978300  NodeProgress node=7837c026… instruction=IntegrationBudget progress=0%
04:10:05.978320  NodeProgress node=9617e5f0… instruction=AdaptiveExposure  progress=0%
```

---

## WF-STOP-N1 — the first light frame exposed 5.0 s, not 15.0 s

**Not** "the first exposure inherits a default/preview duration", which is what the
charter's hypothesis suggested. The 15.0 s exposure really was commanded (`duration=15`
in the DeviceManager line). One millisecond later the meridian-flip trigger fired, and
its plate-solve step restarted the SAME camera with a 5.0 s exposure while the light was
still integrating. The burst then downloaded the solve frame and filed it under the
target as light frame 1 — a third of the requested integration, accepted, while the card
read `Frame 1/4 (15.0s)`.

There is already a claim protocol for exactly this: `claim_camera_for_trigger_action`
serialises a trigger action against the capture loop, and `instructions/expose.rs` takes
the mirror half before every frame. Only autofocus was on the list. The function's own
rustdoc explained why the flip was exempt — it "already runs only after the capture
loop's own pre-frame gate has held the next frame" — and that reasoning is wrong in one
word: the gate holds the NEXT frame. It cannot hold the one already exposing.

Fix: `camera_driving_trigger_action()` (new, `executor/trigger_context.rs`) names every
action that drives the camera — autofocus, meridian flip, and recenter (which
plate-solves, i.e. exposes). `executor/start.rs` takes the claim once above the action
`match`, so every camera-driving action inherits it instead of each arm remembering; the
autofocus arm's own call is replaced by a `debug_assert`. The flip and recenter arms hand
the camera back the moment they finish (mirroring autofocus), including on the paths
where they do not run at all, so the capture loop never waits out the ten-minute expiry.

No deadlock: the burst releases the claim between frames, and its meridian gate waits for
the flip while holding nothing.

Pin: `executor/tests/runtime_tests.rs`
`every_camera_driving_trigger_action_waits_for_the_frame_in_flight` — asserts the list
(including that Pause / ParkAndAbort / Dither must NOT wait, so this cannot turn into a
different defect) and then that a flip actually blocks behind an in-flight frame and
starts as soon as it lands.
Refutation probe: removing the `MeridianFlip` arm ⇒ `left: None, right: Some("meridian flip")`.

## WF-STOP-N2 — 50 s on one surface, 1 m 0 s on three others

The Session Report sums `captured_images.exposure_duration`; the Dashboard "Last night"
card and the Execution History row read `stats_json.integrationSecs`; the Recover
Sequence dialog reads the native checkpoint. The latter three all traced back to the same
root: the executor credited integration, and stamped `ExposureStarted` /
`ExposureCompleted`, from `exposure_node_metadata` — the node's PLANNED duration — so
every consumer downstream computed `frames x plan`. The waveF run of 5 + 15 + 15 + 15
therefore reported 60 s everywhere except the one surface that reads the rows.

The truth already existed and was already bounded: `build_frame_context_for_save` prefers
the camera's own report over the command, one-sidedly (an over-report is a driver fault
and keeps the command; an under-report is physically real and is kept). That rule is now
`recorded_exposure_secs()` in `instructions/frame_context.rs`, used by the FITS path as
before and by the burst loop, which passes the recorded seconds as a third argument to
the per-frame callback. `ProgressUpdate.frame_exposure_secs` carries it to
`executor/start.rs`, which credits integration from it and stamps both exposure events
with it, falling back to the plan when absent.

Every surface now sums the same number the row does — including the checkpoint the
Recover dialog reads, which is why that surface is closed too rather than disclosed.
Note this also fixes adaptive/smart exposure, where plan and actual legitimately differ
on a healthy rig, so the divergence was not only a symptom of N1.

Pins: `instructions/tests/frame_metadata.rs`
`the_frame_callback_reports_recorded_seconds_not_planned_ones` (commanded 15 s, camera
reports 5 s — the waveF frame exactly; asserts the row AND the callback both say 5.0) and
`recorded_exposure_secs_keeps_the_command_when_the_report_is_impossible` (the bound).
Refutation probe: reverting the callback to `config.duration_secs` ⇒ `left: [15.0], right: [5.0]`.

Callback signature changed from `Fn(u32, u32)` to `Fn(u32, u32, f64)`; the flat wizard and
the eleven test call sites were updated.

## WF-STOP-N4 — a run stalled in a retrying flip says Running 50 %, ETA already passed

Two halves, both closed.

*Surfacing.* `MeridianFlipEvent::RetryScheduled` was already emitted — onto
`event_tx`, the flip DIALOG's mpsc channel, which a trigger-fired flip never has (only
the node-driven flip sets it). So the retry ladder was invisible to every run surface.
`MeridianFlipExecutor::emit_event` now also forwards the mid-ladder notice onto the run's
`ExecutorEvent` broadcast as a `NodeProgress` under a stable synthetic node id
(`trigger:meridian_flip`, mirroring the autofocus trigger's shape), reading
`attempt 2/4 failed, retrying in 60s`. Only the mid-ladder notice: `MeridianFlipOutcome`
already carries the verdict and announcing a finished flip twice would double it in the
feed. No new wire type.

*The ETA.* The estimate is fed by completed frames, so a run that stops capturing keeps
its last one forever and it decays into a promise the run is not working toward. The
progress bar now measures how long the run has gone without moving and, past a threshold
derived from the run's OWN cadence (`2 x average planned frame + 60 s` of slack for
download/dither/AF), replaces `~1m 8s · done ~00:12:13` with `no progress for 2m 30s` in
warning colour. Deliberately cadence-derived, not a constant: a fixed window would cry
wolf on every 10-minute sub. A run with no planned integration returns `null` — nothing
is claimed either way rather than a guess presented as a fact.

Two implementation notes worth keeping: the stall is computed inside the pulse
`AnimatedBuilder`, not in `build`, because `build` only reruns when a provider changes and
a stalled run by definition changes nothing; and the elapsed clock is a `Ticker`, not
`DateTime.now()`, so it is the same clock the frames are painted on and a widget test can
advance it.

Pins: `sequence_progress_bar_stall_test.dart` — the waveF run (8 x 15 s, 4 done, ETA 68 s)
loses its finish time after 150 s of silence; a 6 x 600 s run is NOT accused of stalling
after 9 minutes; and the threshold table.
Refutation probe: disabling the comparison ⇒ the finish time is still on screen.
Rust pin: `a_scheduled_retry_reaches_the_runs_event_stream`, which also asserts a
completed flip does NOT go onto the run stream.

## SEQ-18 — fifth look: where the count was dropped

Four previous fixes all aimed at the READER — the node's status, a 20 s retention window,
a second string wording, a structured-detail fallback. None of them could work, and the
log says why in 43 microseconds:

```
04:10:05.978257  NodeProgress node=7837c026… instruction=Exposure          progress=100%
04:10:05.978300  NodeProgress node=7837c026… instruction=IntegrationBudget progress=0%
```

`emit_budget_progress` (native `node/instructions/expose.rs`) fires once per successful
burst against the SAME node id. The bridge publishes it as BOTH
`InstructionProgressStructured` and `InstructionProgress`, and Dart's handler writes both
into `SequenceProgress.nodeProgressDetail[nodeId]` and
`nodeProgressStructuredDetail[nodeId]` — a single slot per node, shared by every
instruction. So the exposure count was overwritten by an `IntegrationBudget` payload no
exposure parser can read, one millisecond after the frames landed, and the card fell back
to frame 0. The next node opened with an `AdaptiveExposure` payload at 0 %, which reads
back as exactly the same `0 / 4 frames` — which is why the card could not tell "captured
everything" from "captured nothing". The number was gone from the provider before any
reader ran.

Fix: `providers/sequence/node_exposure_tally.dart` — a per-node captured-frame tally in
its own slot, which only exposure-shaped progress can write. Both live subscribers on a
desktop host feed it through the same function
(`applySequencerEventToNodeExposureTally`): `SequenceExecutor._handleSequencerEvent` and
the DeviceService-driven pump in `sequence_progress.dart`, which is the only writer on a
headless host. Writes are monotonic per node, so both firing for one event is a no-op.
The tally is cleared at run START and on an explicit sequencer reset — deliberately NOT
when a run ends, which is the trap the earlier retention fix fell into. `_NodeItem`
watches it directly and the panel counts from it when present, leaving the string paths
untouched for hosts that emit no per-node exposure progress.

One subtlety the log forced: `NodeStarted` for node 2 is logged **53 µs before** node 1's
final frame progress. Any counter that attributes a frame to "the run's current node"
credits node 2 with node 1's four frames — the join-by-position mistake with the node ids
right there in the other event. So `ExposureCompleted` (which carries no node id) is used
only until a node-ADDRESSED source is seen, after which the id-less fallback is ignored.

Pins: `exposure_card_wave_f_events_test.dart` replays the events verbatim, in the log's
order, through the production write path and the REAL `SequenceTree`:
* the finished node reads `4 / 4 frames` after the IntegrationBudget write — the
  assertion four previous fixes could not make hold;
* two nodes side by side read `4 / 4` and `0 / 4`, so the counter distinguishes what it
  exists to distinguish;
* node 2 is not credited with node 1's frames.

Refutation probe: making the card ignore the tally ⇒ tests 1 and 2 fail with
`Found 1 widget with text "0 / 4 frames"`.

---

## Verification

| suite | result |
|---|---|
| `cargo test -p skotiq_sequencer` | **786 + 5 + 4 + 12 passed, 0 failed** |
| `cargo clippy -p skotiq_sequencer --all-targets` | clean (3 warnings are pre-existing, in `skotiq_imaging`) |
| `cargo build --workspace` | clean |
| `skotiq_core` `test/providers/sequence` | **611 passed** |
| `skotiq_app` `test/screens/sequencer` | **465 passed, 2 failed** |
| `flutter analyze` on every file touched | clean |

The two `skotiq_app` failures are `captures_landscape_test.dart`, the known
Windows-captured-goldens-on-Linux debt: 9.44 % / 7.17 % pixel diff, byte-identical to the
figures the D-fix log recorded for the same two goldens at HEAD.

## Files

Native (`native/skotiq_native/sequencer/src/`):
`executor/trigger_context.rs`, `executor/start.rs`, `executor/tests/runtime_tests.rs`,
`meridian_flip_executor.rs`, `instructions/frame_context.rs`, `instructions/expose.rs`,
`node/instructions/expose.rs`, `node/progress.rs`, `flat_wizard/mod.rs`, and the five
test files whose burst callbacks gained the third argument.

Dart:
`packages/skotiq_core/lib/src/providers/sequence/node_exposure_tally.dart` (new),
`sequence_progress.dart`, `sequence_executor.dart`,
`sequence_executor/event_operations.dart`, `packages/skotiq_core/lib/skotiq_core.dart`,
`packages/skotiq_app/lib/screens/sequencer/widgets/sequence_progress_bar.dart`,
`node_progress_panels.dart`, `node_progress_panels/exposure_progress_panel.dart`,
`sequence_tree/node_item.dart`, plus the two new test files.

## For the G spot-check

Every item here needs a bundle rebuild to be visible: the SEQ-18 tally, the recorded-
seconds credit and the flip's camera claim all live below the UI. The 5 s first frame is
the cheapest to confirm — build a Target at RA on the meridian so the flip trigger fires
during frame 1, then read the first `Saving FITS …` line or
`select exposure_duration from captured_images`. It must say 15.0.
