// What reaches an operator when the mapper has no case for a sequencer event.
//
// `exposureAdjusted` is an ORDINARY event of an adaptive-exposure night, not an
// error path, and no arm of `_extractSequencerEventInfo` reads it. The fallback
// handed over `sequencerEvent.toString()`, so the run-watch feed printed
//   UnknownSequencerEvent
//   SequencerEvent.exposureAdjusted(nodeId: exp_r, adaptedSecs: 2.0, …)
// on the operator's phone during routine imaging — Dart source text, complete
// with the constructor call, on the wire to every remote client.
//
// These pin the replacement: the event is NAMED by its union variant, and the
// only prose beside it is a sentence written for a person.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  late FfiBackend backend;

  setUp(() => backend = FfiBackend());
  tearDown(() => backend.dispose());

  test('an unmapped sequencer event carries its variant, not its toString', () {
    final (eventType, data) = backend.sequencerEventInfoForTesting(
      const bridge.SequencerEvent.exposureAdjusted(
        nodeId: 'exp_r',
        adaptedSecs: 2.0,
        nominalSecs: 2.0,
        skyBrightnessMag: null,
        filter: 'R',
        reason: 'disabled',
      ),
    );

    expect(eventType, 'UnknownSequencerEvent');
    expect(data['variant'], 'ExposureAdjusted');
    expect(data['message'], isA<String>());
    expect(
      data['message'],
      contains('ExposureAdjusted'),
      reason: 'the sentence must name the event it is about',
    );

    for (final value in data.values) {
      final text = value.toString();
      expect(
        text,
        isNot(contains('SequencerEvent.')),
        reason: 'source text reached an operator-facing field: $text',
      );
      expect(
        text,
        isNot(contains('nodeId:')),
        reason: 'a stringified object reached an operator-facing field: $text',
      );
    }
  });

  test('a mapped sequencer event is unaffected by the fallback', () {
    final (eventType, data) = backend.sequencerEventInfoForTesting(
      const bridge.SequencerEvent.targetChanged(targetName: 'M31'),
    );

    expect(eventType, 'TargetChanged');
    expect(data['target_name'], 'M31');
    expect(data.containsKey('variant'), isFalse);
  });
}
