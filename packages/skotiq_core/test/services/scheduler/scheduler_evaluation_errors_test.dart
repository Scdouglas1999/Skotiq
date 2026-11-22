// A failed evaluation nobody awaits (a tick, a debounced data change) must
// still surface as an error, not vanish inside the evaluation queue.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/services/scheduler/scheduler_engine.dart';

class _Sink implements SchedulerSequenceSink {
  @override
  Future<void> dispatchSequence(Sequence sequence) async {}
  @override
  Future<void> pauseSequence() async {}
  @override
  Future<void> resumeSequence() async {}
  @override
  Future<void> stopSequence() async {}
  @override
  Future<void> parkForEndOfNight() async {}
  @override
  Future<void> releaseSequenceOwnership() async {}
}

void main() {
  test(
    'un-awaited evaluations that fail reach the zone, queued ones too',
    () async {
      final errors = <Object>[];
      final engine = SchedulerEngine(
        site: const SchedulerSite(
          latitudeDegrees: 40,
          longitudeDegrees: -75,
          localOffset: Duration(hours: -5),
        ),
        sequenceSink: _Sink(),
        candidateLoader: () async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          throw StateError('catalog offline');
        },
        clock: () => DateTime.utc(2026, 5, 11, 4),
      );
      runZonedGuarded(() {
        engine.evaluateNow(reason: 'first');
        engine.evaluateNow(reason: 'second');
      }, (error, _) => errors.add(error));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(errors, hasLength(2));
      expect(errors, everyElement(isA<StateError>()));
    },
  );
}
