// What reaches an operator when the mapper has no case for a sequencer event.
//
// The fallback once handed over `sequencerEvent.toString()`, so the run-watch
// feed printed Dart source text (the constructor call and its arguments) on
// the operator's phone. These pin the replacement: the event is NAMED by its
// union variant, and the only prose beside it is a sentence written for a
// person. Every real variant is mapped, so a stand-in whose runtime type name
// mimics a generated variant reaches the fallback.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/skotiq_core.dart';

// ignore: camel_case_types
class SequencerEvent_SkyGlowChanged {
  const SequencerEvent_SkyGlowChanged();

  @override
  String toString() => 'SequencerEvent.skyGlowChanged(nodeId: exp_r)';
}

void main() {
  late FfiBackend backend;

  setUp(() => backend = FfiBackend());
  tearDown(() => backend.dispose());

  test('an unmapped sequencer event carries its variant, not its toString', () {
    final (eventType, data) = backend.sequencerEventInfoForTesting(
      const SequencerEvent_SkyGlowChanged() as dynamic,
    );

    expect(eventType, 'UnknownSequencerEvent');
    expect(data['variant'], 'SkyGlowChanged');
    expect(data['message'], isA<String>());
    expect(
      data['message'],
      contains('SkyGlowChanged'),
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

  test('an adaptive exposure change is read, not reported as unknown', () {
    final (eventType, data) = backend.sequencerEventInfoForTesting(
      const bridge.SequencerEvent.exposureAdjusted(
        nodeId: 'exp_r',
        adaptedSecs: 2.0,
        nominalSecs: 3.0,
        filter: 'R',
        reason: 'sky brighter',
      ),
    );

    expect(eventType, 'ExposureAdjusted');
    expect(data['adapted_secs'], 2.0);
    expect(data['nominal_secs'], 3.0);
    expect(data['reason'], 'sky brighter');
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
