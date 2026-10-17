import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  group('ScienceProcessingStatusTracker', () {
    late ScienceProcessingStatusTracker tracker;

    setUp(() {
      tracker = ScienceProcessingStatusTracker();
    });

    tearDown(() async {
      await tracker.dispose();
    });

    test('starts idle with zero queue and no inflight work', () {
      expect(tracker.queueDepth, 0);
      expect(tracker.inflight, isNull);
      expect(tracker.lastCompleted, isNull);
      expect(tracker.snapshot(), isEmpty);
      expect(tracker.lastFailure, isNull);
    });

    test('enqueue + beginFrame produces an inflight record', () {
      tracker.enqueue();
      expect(tracker.queueDepth, 1);

      tracker.beginFrame(
        imagePath: '/tmp/img1.fits',
        capturedImageId: 42,
        sessionId: 1,
      );

      expect(
        tracker.queueDepth,
        0,
        reason: 'queue depth drops when work starts',
      );
      expect(tracker.inflight, isNotNull);
      expect(tracker.inflight!.imagePath, '/tmp/img1.fits');
      expect(tracker.inflight!.capturedImageId, 42);
      expect(tracker.inflight!.isComplete, isFalse);
    });

    test('emits stage events through the broadcast stream', () async {
      tracker.beginFrame(imagePath: '/tmp/img2.fits');
      final events = <ScienceProcessingEvent>[];
      final sub = tracker.events.listen(events.add);

      final sw = tracker.beginStage(ScienceStage.frameQuality);
      tracker.endStage(
        ScienceStage.frameQuality,
        ScienceStageOutcome.ok,
        stopwatch: sw,
        note: 'fast lane',
      );

      await Future<void>.delayed(const Duration(milliseconds: 5));
      await sub.cancel();

      expect(events.length, greaterThanOrEqualTo(2));
      expect(events.first.stageResult.outcome, ScienceStageOutcome.running);
      expect(events.last.stageResult.outcome, ScienceStageOutcome.ok);
      expect(events.last.stageResult.note, 'fast lane');
    });

    test(
      'endFrame moves inflight into history and synthesises summary event',
      () async {
        tracker.beginFrame(imagePath: '/tmp/img3.fits');
        tracker.skipStage(ScienceStage.frameQuality, note: 'feature disabled');
        tracker.endFrame();

        expect(tracker.inflight, isNull);
        expect(tracker.lastCompleted, isNotNull);
        expect(tracker.lastCompleted!.imagePath, '/tmp/img3.fits');
        expect(tracker.lastCompleted!.isComplete, isTrue);
        expect(tracker.lastCompleted!.hasFailure, isFalse);
      },
    );

    test('lastFailure surfaces the most recent failed stage', () {
      tracker.beginFrame(imagePath: '/tmp/img4.fits');
      tracker.beginStage(ScienceStage.plateSolve);
      tracker.endStage(
        ScienceStage.plateSolve,
        ScienceStageOutcome.failed,
        note: 'no WCS available',
      );
      tracker.endFrame();

      expect(tracker.lastFailure, isNotNull);
      expect(tracker.lastFailure!.stage, ScienceStage.plateSolve);
      expect(tracker.lastFailure!.note, 'no WCS available');
      expect(tracker.lastCompleted!.hasFailure, isTrue);
    });

    test('history is capped to prevent unbounded growth', () {
      for (var i = 0; i < 50; i++) {
        tracker.beginFrame(imagePath: '/tmp/img_$i.fits');
        tracker.endFrame();
      }

      // _historyCap is 32 internally. Allowed to be less if the impl tweaks
      // that constant; just guard against unbounded growth.
      expect(tracker.snapshot().length, lessThanOrEqualTo(35));
    });
  });
}
