import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/providers/autofocus_preview_feeder.dart';
import 'package:skotiq_core/src/models/backend/event_types.dart';
import 'package:skotiq_core/src/models/imaging/imaging_models.dart';
import 'package:skotiq_core/src/models/polar_alignment_config.dart';
import 'package:skotiq_core/src/providers/autofocus_progress_provider.dart';

AutofocusOverlayState _running(int point) =>
    AutofocusOverlayState(isRunning: true, currentPoint: point, totalPoints: 9);

void main() {
  // Owner, live night 2026-10-17: AF frames never appeared in the Imaging
  // preview while autofocus ran.
  test(
    'every new autofocus point fetches the frame it was measured on',
    () async {
      var fetches = 0;
      final feeder = AutofocusPreviewFeeder((_) async => fetches++);

      feeder.onOverlayChanged(null, _running(1));
      await pumpEventQueue();
      feeder.onOverlayChanged(_running(1), _running(1)); // same point, new HFR
      await pumpEventQueue();
      feeder.onOverlayChanged(_running(1), _running(2));
      await pumpEventQueue();

      expect(fetches, 2);
    },
  );

  test('an idle or finished overlay fetches nothing', () async {
    var fetches = 0;
    final feeder = AutofocusPreviewFeeder((_) async => fetches++);

    feeder.onOverlayChanged(null, const AutofocusOverlayState());
    feeder.onOverlayChanged(
      _running(9),
      const AutofocusOverlayState(isRunning: false, currentPoint: 9),
    );
    await pumpEventQueue();

    expect(fetches, 0);
  });

  test(
    'points that arrive during a slow fetch queue one more, not many',
    () async {
      var fetches = 0;
      final gate = Completer<void>();
      final feeder = AutofocusPreviewFeeder((_) async {
        fetches++;
        if (fetches == 1) await gate.future;
      });

      feeder.onOverlayChanged(null, _running(1));
      feeder.onOverlayChanged(_running(1), _running(2));
      feeder.onOverlayChanged(_running(2), _running(3));
      feeder.onOverlayChanged(_running(3), _running(4));
      gate.complete();
      await pumpEventQueue();

      expect(fetches, 2);
    },
  );

  test('a failed fetch does not stop the next point being shown', () async {
    var calls = 0;
    final feeder = AutofocusPreviewFeeder((_) async {
      calls++;
      if (calls == 1) throw StateError('camera busy');
    });

    feeder.onOverlayChanged(null, _running(1));
    await pumpEventQueue();
    feeder.onOverlayChanged(_running(1), _running(2));
    await pumpEventQueue();

    expect(calls, 2);
  });

  group('frames of native runs', () {
    SkotiqEvent event(
      EventCategory category,
      String type, [
      Map<String, dynamic> data = const {},
    ]) => SkotiqEvent(
      timestamp: 0,
      severity: EventSeverity.info,
      category: category,
      eventType: type,
      data: data,
    );

    SkotiqEvent center(int attempt) =>
        event(EventCategory.sequencer, 'InstructionProgressStructured', {
          'instruction': 'Center',
          'detail_kind': 'Center',
          'detail_json': '{"attempt":$attempt,"max_attempts":5}',
        });

    final done = event(EventCategory.imaging, 'ExposureComplete', {
      'success': true,
    });

    void feed(
      AutofocusPreviewFeeder feeder,
      SkotiqEvent e, {
      bool af = false,
      PolarAlignPhase polar = PolarAlignPhase.idle,
      int point = 0,
    }) => feeder.onEvent(
      e,
      autofocusRunning: af,
      polarPhase: polar,
      polarPoint: point,
    );

    // Owner, Heart Nebula night 2026-11-07: plate solve frames never showed
    // in the main image box.
    test('each centering attempt of a sequence shows its frame', () async {
      final shown = <UtilityFrameRequest>[];
      final feeder = AutofocusPreviewFeeder((r) async => shown.add(r));

      feed(feeder, center(1));
      feed(feeder, done);
      await pumpEventQueue();
      feed(feeder, center(2));
      feed(feeder, done);
      await pumpEventQueue();

      expect(shown.map((r) => (r.purpose, r.step, r.steps)), [
        (FramePurpose.centering, 1, 5),
        (FramePurpose.centering, 2, 5),
      ]);
    });

    test('a light after the Center step is left to the run', () async {
      final shown = <UtilityFrameRequest>[];
      final feeder = AutofocusPreviewFeeder((r) async => shown.add(r));

      feed(feeder, center(1));
      feed(feeder, event(EventCategory.sequencer, 'NodeCompleted'));
      feed(feeder, done);
      feed(feeder, center(0));
      feed(feeder, done);
      await pumpEventQueue();

      expect(shown, isEmpty);
    });

    test('a failed exposure or an autofocus exposure is not fetched '
        'here', () async {
      final shown = <UtilityFrameRequest>[];
      final feeder = AutofocusPreviewFeeder((r) async => shown.add(r));

      feed(feeder, center(1));
      feed(
        feeder,
        event(EventCategory.imaging, 'ExposureComplete', {'success': false}),
      );
      feed(feeder, done, af: true);
      await pumpEventQueue();

      expect(shown, isEmpty);
    });

    test('a meridian flip shows its re-centering frames until the run '
        'takes a light again', () async {
      final shown = <UtilityFrameRequest>[];
      final feeder = AutofocusPreviewFeeder((r) async => shown.add(r));

      feed(
        feeder,
        event(EventCategory.sequencer, 'TriggerFired', {
          'action': 'MeridianFlip',
        }),
      );
      // The flip spans the step it interrupted.
      feed(feeder, event(EventCategory.sequencer, 'NodeStarted'));
      feed(feeder, done);
      await pumpEventQueue();
      feed(feeder, event(EventCategory.sequencer, 'FrameAccepted'));
      feed(feeder, done);
      await pumpEventQueue();

      expect(shown.map((r) => (r.purpose, r.step)), [
        (FramePurpose.centering, null),
      ]);
    });

    test('polar alignment frames show with their point', () async {
      final shown = <UtilityFrameRequest>[];
      final feeder = AutofocusPreviewFeeder((r) async => shown.add(r));

      feed(feeder, done, polar: PolarAlignPhase.measuring, point: 2);
      await pumpEventQueue();
      feed(feeder, done, polar: PolarAlignPhase.adjusting);
      await pumpEventQueue();
      feed(feeder, done);
      await pumpEventQueue();

      expect(shown.map((r) => (r.purpose, r.step)), [
        (FramePurpose.polarAlignment, 2),
        (FramePurpose.polarAlignment, null),
      ]);
    });

    test('an autofocus point carries its place in the run', () async {
      final shown = <UtilityFrameRequest>[];
      final feeder = AutofocusPreviewFeeder((r) async => shown.add(r));

      feeder.onOverlayChanged(null, _running(5));
      await pumpEventQueue();

      expect(shown.single.purpose, FramePurpose.autofocus);
      expect((shown.single.step, shown.single.steps), (5, 9));
    });
  });
}
