// The tally against the WIRE shape, not a convenient one.
//
// `detail_json` crosses as a JSON String, never as a Dart `Map`: the native
// side stringifies the payload —
//
//   node/instructions/expose.rs        ProgressDetail::Exposure { frame, total, .. }
//   api/sequencer/event_translation.rs `payload.to_string()`  -> a JSON String
//   event/sequencer.rs:118             `detail_json: String`
//   ffi_backend/event_mapping.dart:534 'detail_json': sequencerEvent.detailJson
//
// — so every consumer must decode it first (sequencer_run_event.dart's
// `decodeStructuredProgressJson`). A consumer that reads it as a Map sees `{}`
// and counts nothing.
//
// The second half of this file pins the id-less boundary: `ExposureCompleted`
// carries no node id on the wire (event_mapping.dart's ExposureCompleted case
// has frame/total/duration only), and `NodeStarted` for the next node can be
// emitted BEFORE the previous node's last frame. Attributing an id-less event
// to "the run's current node" therefore credits the wrong node — a join by
// position, with the node id available in the structured event.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

SkotiqEvent _seq(String type, Map<String, dynamic> data) => SkotiqEvent(
  timestamp: DateTime.now().microsecondsSinceEpoch,
  severity: EventSeverity.info,
  category: EventCategory.sequencer,
  eventType: type,
  data: data,
);

/// `SequencerEvent::InstructionProgressStructured` exactly as the bridge
/// delivers it: `detail_json` is a JSON **String**.
SkotiqEvent _exposureProgress(String nodeId, int frame, int total) =>
    _seq('InstructionProgressStructured', {
      'node_id': nodeId,
      'instruction': 'Exposure',
      'progress_percent': frame / total * 100.0,
      'detail_kind': 'Exposure',
      'detail_json': jsonEncode({
        'frame': frame,
        'total': total,
        'duration_secs': 15.0,
      }),
    });

void main() {
  const node1 = '7837c026-node-one';
  const node2 = '9617e5f0-node-two';

  test('the wire shape — detail_json as a JSON String — reaches the tally', () {
    final tally = NodeExposureTallyNotifier();
    applySequencerEventToNodeExposureTally(
      tally,
      _seq('NodeStarted', {'node_id': node1}),
    );
    for (var frame = 1; frame <= 4; frame++) {
      applySequencerEventToNodeExposureTally(
        tally,
        _exposureProgress(node1, frame, 4),
      );
    }

    expect(
      tally.state[node1],
      const NodeExposureTally(captured: 4, planned: 4),
      reason: 'the node-addressed source must reach the tally on the real path',
    );
  });

  test('an already-decoded Map payload is still accepted', () {
    final tally = NodeExposureTallyNotifier();
    applySequencerEventToNodeExposureTally(
      tally,
      _seq('InstructionProgressStructured', {
        'node_id': node1,
        'detail_kind': 'Exposure',
        'detail_json': {'frame': 4, 'total': 4},
      }),
    );

    expect(tally.state[node1]?.captured, 4);
  });

  test('a malformed detail_json payload is ignored, not counted', () {
    final tally = NodeExposureTallyNotifier();
    applySequencerEventToNodeExposureTally(
      tally,
      _seq('InstructionProgressStructured', {
        'node_id': node1,
        'detail_kind': 'Exposure',
        'detail_json': 'not json at all',
      }),
    );

    expect(tally.state, isEmpty);
  });

  test('the node boundary cannot credit node 2 with node 1 frames', () {
    final tally = NodeExposureTallyNotifier();
    applySequencerEventToNodeExposureTally(
      tally,
      _seq('NodeStarted', {'node_id': node1}),
    );
    for (var frame = 1; frame <= 3; frame++) {
      applySequencerEventToNodeExposureTally(
        tally,
        _exposureProgress(node1, frame, 4),
      );
      applySequencerEventToNodeExposureTally(
        tally,
        _seq('ExposureCompleted', {
          'frame': frame,
          'total': 4,
          'duration_secs': 15.0,
        }),
      );
    }

    // The waveF ordering: NodeStarted for node 2 is emitted 53 us BEFORE
    // node 1's final frame, so the run's "current node" has already advanced.
    applySequencerEventToNodeExposureTally(
      tally,
      _seq('NodeStarted', {'node_id': node2}),
    );
    applySequencerEventToNodeExposureTally(
      tally,
      _exposureProgress(node1, 4, 4),
    );
    applySequencerEventToNodeExposureTally(
      tally,
      _seq('ExposureCompleted', {
        'frame': 4,
        'total': 4,
        'duration_secs': 15.0,
      }),
    );

    expect(
      tally.state[node1],
      const NodeExposureTally(captured: 4, planned: 4),
      reason: 'the finished node captured four frames and must read 4 / 4',
    );
    expect(
      tally.state[node2],
      isNull,
      reason: 'node 2 has captured nothing; crediting it is join-by-position',
    );
  });

  test('structured progress with no node id is not attributed to anyone', () {
    final tally = NodeExposureTallyNotifier();
    applySequencerEventToNodeExposureTally(
      tally,
      _seq('NodeStarted', {'node_id': node1}),
    );
    applySequencerEventToNodeExposureTally(
      tally,
      _seq('InstructionProgressStructured', {
        'instruction': 'Exposure',
        'detail_kind': 'Exposure',
        'detail_json': jsonEncode({'frame': 2, 'total': 4}),
      }),
    );

    expect(tally.state, isEmpty);
  });

  test('a fresh pass over a node clears the previous pass frames', () {
    final tally = NodeExposureTallyNotifier();
    for (var frame = 1; frame <= 4; frame++) {
      applySequencerEventToNodeExposureTally(
        tally,
        _exposureProgress(node1, frame, 4),
      );
    }
    applySequencerEventToNodeExposureTally(
      tally,
      _seq('NodeStarted', {'node_id': node1}),
    );

    expect(tally.state[node1], isNull);
  });
}
