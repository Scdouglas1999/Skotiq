# gfix-tally-wire — SEQ-18, sixth and final look

Refutation closed: `waveG-result.json` → refuter entry
`SEQ-18-provider-tally (ffix-exposure-integrity, "fifth look": node_exposure_tally.dart)`.

## What the refuter proved

1. `node_exposure_tally.dart:167-168` read `event.data['detail_json']` as a
   `Map`. Production sends a JSON **String**:
   `node/instructions/expose.rs` → `ProgressDetail::Exposure { frame, total, .. }`
   → `api/sequencer/event_translation.rs:265` `payload.to_string()`
   → `bridge/src/event/sequencer.rs:126` `detail_json: String`
   → `ffi_backend/event_mapping.dart:534` `'detail_json': sequencerEvent.detailJson`.
   The remote/JSON transport carries the same String (`server_lifecycle.dart`
   re-broadcasts the event unfiltered). So the tally read `{}` and counted
   nothing on every host, and the card fell back to the old string parse.
2. Because the tally never saw a "named" source, its `_namedSourceSeen` latch
   never armed and the id-less `ExposureCompleted` fallback ran forever.
   `ExposureCompleted` carries no node id (`event_mapping.dart:481-489` is
   frame/total/duration_secs only), so it was attributed to the run's *current*
   node — and `executor/start.rs:1005` synthesizes it from a `NodeProgress`
   sighting whose `node_id` is right there but is not put on the event. In the
   waveF ordering (`NodeStarted` node2 53 µs BEFORE node1's last frame) that
   credited node 2 with node 1's frame and left node 1 reading 3 / 4.
3. The shipped pin fed a `Map`, a shape production never sends, so it passed.

## Failing test first (adopted from the refuter's throwaway)

`packages/skotiq_core/test/providers/sequence/node_exposure_tally_wire_shape_test.dart`
— the refuter's `/tmp/.../scratchpad/refute_tally_test.dart` adopted into the
repo, with `detail_json` `jsonEncode`d exactly as the bridge sends it. Before
the fix:

```
the wire shape — detail_json as a JSON String — reaches the tally [E]
  Expected: NodeExposureTally:<NodeExposureTally(4/4)>   Actual: <null>
the node boundary cannot credit node 2 with node 1 frames [E]
  Expected: NodeExposureTally:<NodeExposureTally(4/4)>   Actual: <null>
```

## The fix

- New `packages/skotiq_core/lib/src/providers/sequence/structured_progress_json.dart`
  holding one `decodeStructuredProgressJson`. The tally uses it; the duplicate
  private `_decodeStructuredProgressJson` in
  `sequence_executor/event_operations.dart` was deleted and its call site now
  uses the shared function, so there is one decode for `detail_json`.
- The tally now counts ONLY node-addressed `InstructionProgressStructured`
  with `detail_kind == 'Exposure'`. The `ExposureCompleted` case is gone
  entirely, and structured progress with no `node_id` is dropped rather than
  attributed to a current node. Chosen over threading `node_id` onto the wire
  event, which would have required an FRB regen (`SequencerEvent::
  ExposureCompleted` is an FRB-mirrored enum variant): the node-addressed event
  already carries the same frame number, so no information is lost — **no FRB
  regen was needed and none was run**.
- Consequently `applySequencerEventToNodeExposureTally` no longer takes
  `currentNodeId`; both call sites (`sequence_executor/event_operations.dart`,
  `sequence_progress.dart`) and `recordFrames`'s `named:` flag /
  `_namedSourceSeen` latch are gone. Mis-attribution is now structurally
  impossible rather than latch-dependent.

Blast radius checked: `nodeExposureTallyProvider` has exactly one reader
(`sequence_tree/node_item.dart` → `_ExposureProgressPanel`, which is built for
`ExposureNode` only). `ExposureNode`'s native producer always emits
`ProgressDetail::Exposure` per frame, so dropping the id-less fallback cannot
blank a card that used to have a number. Smart Exposure nodes render a
different panel that never consumed the tally.

## Item 3 — the widget test can no longer pass on a fake shape

`packages/skotiq_app/test/screens/sequencer/widgets/exposure_card_wave_f_events_test.dart`
now `jsonEncode`s `detail_json` in `_structured(...)` and drops `currentNodeId`
from `_pump`. Counterfactual run (decode reverted in the tally, everything else
final) — all three fail:

```
the waveF burst leaves the finished node reading 4 / 4, not 0 / 4 [E]
  Actual: Found 0 widgets with text "4 / 4 frames"
a node that captured nothing still reads 0 / 4 beside one that captured everything [E]
node 2's opening progress cannot claim node 1's frames [E]  Expected: <4>  Actual: <null>
```

## Verification

- `skotiq_core`: `flutter test test/providers/sequence` → **617 passed**.
- `skotiq_app`: `flutter test test/screens/sequencer/widgets/exposure_card_wave_f_events_test.dart`
  → 3 passed.
- `skotiq_app`: `flutter test test/screens/sequencer` → 465 passed, 2 failed —
  both `captures_landscape_test.dart` golden pixel diffs (9.44% / 7.17%), the
  known Windows-captured-goldens-on-Linux failures. That file contains no
  sequencer events and no tally reference (`grep -c "tally\|InstructionProgress"`
  = 0), so it cannot be affected by this change.
- `dart analyze lib/src/providers/sequence test/providers/sequence` → clean
  (1 pre-existing `use_super_parameters` info in `autopilot_armed_rule_test.dart`).
- `dart format` run on the seven touched files only.

No GUI harness, no bundle rebuild, no melos, no git writes, no generated files,
no FRB regen.
