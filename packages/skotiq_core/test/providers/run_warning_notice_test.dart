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
/// and `NoticedWarning` in `bridge/src/api/sequencer/event_bridge.rs`).
SkotiqEvent _sequencerWarning(String message, {SequencerNotice? notice}) {
  final (type, data) = encodeEventPayload(
    EventPayload.sequencer(
      SequencerEvent.error(
        message: message,
        kind: SequencerErrorKind.advisory,
        notice: notice,
      ),
    ),
  );
  return SkotiqEvent(
    timestamp: DateTime.now().millisecondsSinceEpoch,
    severity: EventSeverity.warning,
    category: EventCategory.sequencer,
    eventType: type,
    data: Map<String, dynamic>.from(data),
  );
}

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
          'Worded in a way no other notice is.',
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
