import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/backend.dart' show typedEventFromWire;
import 'package:skotiq_core/src/providers/autofocus_preview_feeder.dart';
import 'package:skotiq_core/src/models/backend/event_types.dart';
import 'package:skotiq_core/src/models/imaging/imaging_models.dart';
import 'package:skotiq_core/src/models/polar_alignment_config.dart';
import 'package:skotiq_core/src/providers/autofocus_progress_provider.dart';

import '../harness/event_wire.dart';
import '../harness/sequencer_wire.dart';

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
    SkotiqEvent seq(bridge.SequencerEvent e) =>
        ffiWireEvent(bridge.EventPayload.sequencer(e));

    SkotiqEvent center(int attempt) => seq(
      bridge.SequencerEvent.instructionProgress(
        nodeId: 'center-1',
        instruction: 'Center',
        progressPercent: 0,
        detail: 'Centering attempt $attempt',
        detailKind: 'Center',
        detailJson: '{"attempt":$attempt,"max_attempts":5}',
      ),
    );

    final done = ffiWireEvent(
      const bridge.EventPayload.imaging(
        bridge.ImagingEvent.exposureComplete(success: true),
      ),
    );
    final failedExposure = ffiWireEvent(
      const bridge.EventPayload.imaging(
        bridge.ImagingEvent.exposureComplete(success: false),
      ),
    );
    final nodeStarted = seq(
      const bridge.SequencerEvent.nodeStarted(
        nodeId: 'n1',
        nodeType: 'TakeExposure',
      ),
    );
    final nodeCompleted = seq(
      const bridge.SequencerEvent.nodeCompleted(
        nodeId: 'center-1',
        status: 'success',
      ),
    );
    final flipFired = seq(
      const bridge.SequencerEvent.triggerFired(
        triggerId: 'flip',
        triggerName: 'Meridian flip',
        action: bridge.SequencerTriggerAction.meridianFlip,
      ),
    );
    final lightAccepted = frameVerdictEvent(accepted: true, nodeId: 'n1');

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
      feed(feeder, nodeCompleted);
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
      feed(feeder, failedExposure);
      feed(feeder, done, af: true);
      await pumpEventQueue();

      expect(shown, isEmpty);
    });

    test('a meridian flip shows its re-centering frames until the run '
        'takes a light again', () async {
      final shown = <UtilityFrameRequest>[];
      final feeder = AutofocusPreviewFeeder((r) async => shown.add(r));

      feed(feeder, flipFired);
      // The flip spans the step it interrupted.
      feed(feeder, nodeStarted);
      feed(feeder, done);
      await pumpEventQueue();
      feed(feeder, lightAccepted);
      feed(feeder, done);
      await pumpEventQueue();

      expect(shown.map((r) => (r.purpose, r.step)), [
        (FramePurpose.centering, null),
      ]);
    });

    // What the next frame is shown as after each run event, from a fresh
    // feeder, mid-centering and mid-flip, over both transports. Pinned on
    // the feeder that compared event names.
    test('the run events that say what the next exposure is for', () async {
      final rows = <String, bridge.EventPayload>{
        'center attempt 2': bridge.EventPayload.sequencer(
          (center(2).let(typedSequencer)),
        ),
        'center attempt 0': bridge.EventPayload.sequencer(
          center(0).let(typedSequencer),
        ),
        'flip step progress': const bridge.EventPayload.sequencer(
          bridge.SequencerEvent.instructionProgress(
            nodeId: 'flip',
            instruction: 'MeridianFlip',
            progressPercent: 10,
            detail: 'Slewing',
            detailKind: 'MeridianFlip',
            detailJson: '{}',
          ),
        ),
        'exposure step progress': const bridge.EventPayload.sequencer(
          bridge.SequencerEvent.instructionProgress(
            nodeId: 'n1',
            instruction: 'TakeExposure',
            progressPercent: 10,
            detail: '',
            detailKind: '',
            detailJson: '',
          ),
        ),
        'flip trigger': bridge.EventPayload.sequencer(
          flipFired.let(typedSequencer),
        ),
        'autofocus trigger': const bridge.EventPayload.sequencer(
          bridge.SequencerEvent.triggerFired(
            triggerId: 'af',
            triggerName: 'Autofocus',
            action: bridge.SequencerTriggerAction.autofocus,
          ),
        ),
        'node started': bridge.EventPayload.sequencer(
          nodeStarted.let(typedSequencer),
        ),
        'node completed': bridge.EventPayload.sequencer(
          nodeCompleted.let(typedSequencer),
        ),
        'frame accepted': bridge.EventPayload.sequencer(
          lightAccepted.let(typedSequencer),
        ),
        'frame rejected': bridge.EventPayload.sequencer(
          frameVerdictEvent(accepted: false, nodeId: 'n1').let(typedSequencer),
        ),
        'run exposure completed': const bridge.EventPayload.sequencer(
          bridge.SequencerEvent.exposureCompleted(
            frame: 1,
            total: 4,
            durationSecs: 30,
          ),
        ),
        'stopped': const bridge.EventPayload.sequencer(
          bridge.SequencerEvent.stopped(),
        ),
        'completed': const bridge.EventPayload.sequencer(
          bridge.SequencerEvent.completed(),
        ),
        'failed': const bridge.EventPayload.sequencer(
          bridge.SequencerEvent.failed(error: 'mount lost'),
        ),
        'imaging exposure completed': const bridge.EventPayload.imaging(
          bridge.ImagingEvent.exposureCompleted(hfr: 2, starsDetected: 30),
        ),
      };

      Future<String> nextFrame(List<SkotiqEvent> before, SkotiqEvent e) async {
        final shown = <UtilityFrameRequest>[];
        final feeder = AutofocusPreviewFeeder((r) async => shown.add(r));
        for (final b in before) {
          feed(feeder, b);
        }
        feed(feeder, e);
        feed(feeder, done);
        await pumpEventQueue();
        return shown.isEmpty
            ? '-'
            : '${shown.single.purpose.name}:${shown.single.step}';
      }

      final table = <String, String>{};
      for (final row in rows.entries) {
        final cells = <String>[];
        for (final path in EventPath.values) {
          final e = wireEventOver(path, row.value);
          cells.add(
            'fresh=${await nextFrame(const [], e)} '
            'centering=${await nextFrame([center(1)], e)} '
            'flip=${await nextFrame([flipFired], e)}',
          );
        }
        expect(cells.last, cells.first, reason: '${row.key}: transports');
        table[row.key] = cells.first;
      }
      table['wire sequenceFailed'] = await nextFrame([
        center(1),
      ], unsentWireEvent(EventCategory.sequencer, 'sequenceFailed'));
      expect(table, <String, String>{
        'center attempt 2':
            'fresh=centering:2 centering=centering:2 flip=centering:2',
        'center attempt 0': 'fresh=- centering=- flip=-',
        'flip step progress':
            'fresh=centering:null centering=centering:null flip=centering:null',
        'exposure step progress': 'fresh=- centering=- flip=-',
        'flip trigger':
            'fresh=centering:null centering=centering:1 flip=centering:null',
        'autofocus trigger':
            'fresh=- centering=centering:1 flip=centering:null',
        'node started': 'fresh=- centering=- flip=centering:null',
        'node completed': 'fresh=- centering=- flip=centering:null',
        'frame accepted': 'fresh=- centering=- flip=-',
        'frame rejected': 'fresh=- centering=- flip=-',
        'run exposure completed': 'fresh=- centering=- flip=-',
        'stopped': 'fresh=- centering=- flip=-',
        'completed': 'fresh=- centering=- flip=-',
        'failed': 'fresh=- centering=- flip=-',
        'imaging exposure completed':
            'fresh=- centering=centering:1 flip=centering:null',
        'wire sequenceFailed': '-',
      });
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

bridge.SequencerEvent typedSequencer(SkotiqEvent e) =>
    switch (typedEventFromWire(e)?.payload) {
      bridge.EventPayload_Sequencer(:final field0) => field0,
      _ => throw StateError('not a sequencer event: ${e.eventType}'),
    };

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
