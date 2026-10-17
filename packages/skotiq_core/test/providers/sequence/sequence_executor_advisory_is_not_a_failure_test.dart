import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart'
    as backend_events;
import 'package:skotiq_core/src/services/notification/event_classifier.dart';

import '../../mocks/mock_backend.dart';

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

/// A non-fatal advisory must not be reported as a failed run.
///
/// The executor's preflight advisory — "The meridian-flip trigger is set to
/// re-centre after a flip, but no plate solver (ASTAP or solve-field) was
/// found on this system…" — had no warning channel to travel on, so it was
/// emitted as `ExecutorEvent::Error`. Live, on a three-frame DARKS run that
/// finished `Completed` with `Frames accepted 3/3` and `Frames rejected 0`,
/// that one sentence produced:
///   * a red `Critical - Sequencer` toast,
///   * a `Sequence Error` toast,
///   * a `Sequence failed — Sequence aborted at 20:14.` toast (and the phone
///     push behind it), and
///   * a red **Errors** section in the Session Report.
///
/// The executor now has `ExecutorEvent::Warning`, which the bridge maps to
/// `EventSeverity.warning` on the same payload. Everything below is what that
/// severity has to buy.
const _advisory =
    'The meridian-flip trigger is set to re-centre after a flip, but no plate '
    'solver (ASTAP or solve-field) was found on this system.';

backend_events.SkotiqEvent _sequencerError(
  String message, {
  required backend_events.EventSeverity severity,
}) => backend_events.SkotiqEvent(
  timestamp: DateTime.now().millisecondsSinceEpoch,
  severity: severity,
  category: backend_events.EventCategory.sequencer,
  eventType: 'Error',
  data: {'message': message},
);

void main() {
  late MockBackend backend;
  late StreamController<backend_events.SkotiqEvent> eventController;
  late SkotiqDatabase db;

  setUp(() {
    backend = MockBackend();
    eventController =
        StreamController<backend_events.SkotiqEvent>.broadcast();
    when(() => backend.eventStream).thenAnswer((_) => eventController.stream);
    when(
      () => backend.polarAlignmentEvents,
    ).thenAnswer((_) => const Stream.empty());
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await eventController.close();
    await db.close();
  });

  (ProviderContainer, SequenceExecutor) build() {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(liveSequenceStatsProvider.notifier).state =
        SequenceRunStats();
    container.read(sequenceExecutionStateProvider.notifier).state =
        SequenceExecutionState.running;
    return (container, container.read(sequenceExecutorProvider));
  }

  test('a warning-severity advisory lands in warnings, not errors', () {
    final (container, executor) = build();

    executor.handleSequencerEventForTest(
      _sequencerError(
        _advisory,
        severity: backend_events.EventSeverity.warning,
      ),
    );

    final stats = container.read(liveSequenceStatsProvider)!;
    expect(
      stats.errorMessages,
      isEmpty,
      reason:
          'this is the Session Report list that rendered under a red '
          '"Errors" heading on a run that completed 3/3',
    );
    expect(stats.warningMessages, hasLength(1));
    expect(stats.warningMessages.single, _advisory);
  });

  test('a warning-severity advisory does not push the run into recovering', () {
    final (container, executor) = build();

    executor.handleSequencerEventForTest(
      _sequencerError(
        _advisory,
        severity: backend_events.EventSeverity.warning,
      ),
    );

    expect(
      container.read(sequenceExecutionStateProvider),
      SequenceExecutionState.running,
      reason: 'nothing is being salvaged; the run is proceeding normally',
    );
  });

  test('a real error-severity fault is still an error in every respect', () {
    final (container, executor) = build();

    executor.handleSequencerEventForTest(
      _sequencerError(
        'Camera download failed after 3 attempts',
        severity: backend_events.EventSeverity.error,
      ),
    );

    final stats = container.read(liveSequenceStatsProvider)!;
    expect(stats.errorMessages, hasLength(1));
    expect(stats.warningMessages, isEmpty);
    expect(
      container.read(sequenceExecutionStateProvider),
      SequenceExecutionState.recovering,
    );
  });

  test(
    'a warning-severity advisory raises no "Sequence failed" notification',
    () {
      expect(
        NotificationEventClassifier.classify(
          _sequencerError(
            _advisory,
            severity: backend_events.EventSeverity.warning,
          ),
        ),
        isNull,
        reason:
            'this classifier is what produced the "Sequence failed / '
            'Sequence aborted at 20:14." toast and its phone push',
      );
    },
  );

  test('an error-severity fault still classifies as a failed sequence', () {
    final classified = NotificationEventClassifier.classify(
      _sequencerError(
        'Camera download failed after 3 attempts',
        severity: backend_events.EventSeverity.error,
      ),
    );
    expect(classified?.category, NotificationCategory.sequenceFailed);
  });
}
