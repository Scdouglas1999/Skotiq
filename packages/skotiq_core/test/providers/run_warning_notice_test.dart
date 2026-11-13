// One quality problem the run carries on through is announced once.
//
// The engine records it twice: a decision row, from which the notification
// router raises "Problem noticed — the run continues", and a Warning in the
// run's feed, which Tonight's run-warnings banner lists. The error bridge
// toasted that Warning as well ("Sequence Warning"), so one problem read as
// three notices with the same words.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

class _MockFfiBackend extends Mock implements FfiBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

/// A sequencer Warning as the bridge publishes it (`ExecutorEvent::Warning`
/// and `NoticedWarning` in `bridge/src/api/sequencer/event_bridge.rs`). A host
/// from before the notice field sends none.
SkotiqEvent _sequencerWarning(String message, {SequencerNotice? notice}) =>
    SkotiqEvent(
      timestamp: DateTime.now().millisecondsSinceEpoch,
      severity: EventSeverity.warning,
      category: EventCategory.sequencer,
      eventType: 'Error',
      data: {
        'message': message,
        'kind': 'advisory',
        if (notice != null) kSequencerNoticeKey: notice.wireName,
      },
    );

/// `quality_problem_continuation` in the native executor, word for word.
const _continuedProblem =
    'Start guiding: Calibration axes look broken: RA angle 10.2°, Dec angle '
    '79.9° — off-perpendicular by 20.3° (limit 20.0°). The guider may have '
    'miscalibrated; recalibrate before continuing. The run continues. To have '
    'problems like this stop the run instead, turn on Stop the run for '
    'quality problems in Settings > Sequencer.';

Future<(ProviderContainer, StreamController<SkotiqEvent>)> _bridge() async {
  final backend = _MockFfiBackend();
  final controller = StreamController<SkotiqEvent>.broadcast();
  when(() => backend.eventStream).thenAnswer((_) => controller.stream);
  final container = ProviderContainer(
    overrides: [
      backendProvider.overrideWith(
        (ref) => _FixedBackendNotifier(ref, backend),
      ),
    ],
  );
  container.read(errorNotificationBridgeProvider);
  return (container, controller);
}

void main() {
  test('a continued quality problem is not toasted a second time', () async {
    final (container, controller) = await _bridge();
    addTearDown(container.dispose);
    addTearDown(controller.close);

    controller.add(_sequencerWarning(_continuedProblem));
    await pumpEventQueue();

    expect(
      container.read(uiNotificationProvider),
      isEmpty,
      reason:
          'the router announces it from the decision row and the run '
          'warnings banner lists it',
    );
  });

  for (final (name, message) in [
    (
      'an autofocus that did not converge',
      "Autofocus trigger 'Refocus every 30 min' did not converge (no V-curve "
          'minimum). The focuser was returned to position 25000 and imaging '
          'continues on the last-good focus.',
    ),
    (
      'an autofocus that could not return the focuser',
      'Post-flip autofocus did not converge (too few stars) and the focuser '
          'could NOT be returned to its pre-autofocus position — it is at '
          'position 24800. Imaging continues, but check focus before trusting '
          'these frames.',
    ),
    (
      'a streak of rejected frames',
      'Image grading: 3 frames in a row rejected (notify limit 3), most '
          'recently frame 12/40 at alt 45.2°, az 120.0°: HFR 4.10 over 3.50. '
          'The run continues and every frame is kept; rejects are in the '
          'Reject folder. Accepted so far: 9, rejected: 3.',
    ),
  ]) {
    test('$name is not toasted a second time', () async {
      final (container, controller) = await _bridge();
      addTearDown(container.dispose);
      addTearDown(controller.close);

      controller.add(_sequencerWarning(message));
      await pumpEventQueue();

      expect(
        container.read(uiNotificationProvider),
        isEmpty,
        reason: 'the router announces it from the decision row',
      );
    });
  }

  const notices = [
    SequencerNotice.autofocusContinued(),
    SequencerNotice.rejectStreak(consecutiveRejects: 3, reason: 'trailed'),
    SequencerNotice.problemNoticed(source: 'Center', problem: 'no solve'),
  ];
  for (final notice in notices) {
    test('a Warning marked ${notice.wireName} is not toasted, whatever its '
        'words', () async {
      final (container, controller) = await _bridge();
      addTearDown(container.dispose);
      addTearDown(controller.close);

      controller.add(
        _sequencerWarning(
          'Worded by a newer host in a way no older build wrote.',
          notice: notice,
        ),
      );
      await pumpEventQueue();

      expect(container.read(uiNotificationProvider), isEmpty);
    });
  }

  test('another run warning still reaches the operator', () async {
    final (container, controller) = await _bridge();
    addTearDown(container.dispose);
    addTearDown(controller.close);

    controller.add(
      _sequencerWarning(
        'The mount stopped at its tracking limit; the run waits for the flip.',
      ),
    );
    await pumpEventQueue();

    expect(container.read(uiNotificationProvider), hasLength(1));
  });
}
