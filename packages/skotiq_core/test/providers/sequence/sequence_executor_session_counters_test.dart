// A sequenced run advances the counters on its own `imaging_sessions` row.
//
// `SessionStateNotifier.recordExposureComplete` is the only thing that feeds
// SessionService, which is the only thing that writes those columns. Called
// exclusively from the ad-hoc capture surfaces (imaging screen, dashboard quick
// actions), it leaves the sequencer's frame-registration path stamping
// `session_id` onto every row it writes while the aggregate never moves:
// `/api/sessions` then reports a session with totalExposures: 0,
// successfulExposures: 0, totalIntegrationSecs: 0.0 while its own
// captured_images rows point back at it.

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart' as bridge_event;

import '../../mocks/mock_backend.dart';

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

const _exposureNodeId = 'exposure-node-1';
const _exposureSecs = 30.0;

/// A loaded sequence whose ExposureNode id matches the `node_id` the pumped
/// events carry, so frame attribution resolves a real exposure length (the
/// integration budget is derived from it, not from the event).
Sequence _sequence() {
  final target = TargetHeaderNode(
    id: 'target-1',
    name: 'D5 Target',
    targetName: 'D5 Target',
    raHours: 3,
    decDegrees: 45,
  );
  final exposure = ExposureNode(
    id: _exposureNodeId,
    name: 'Lights',
    parentId: target.id,
    durationSecs: _exposureSecs,
    count: 4,
  );
  return Sequence.create(
    name: 'D5 Session Counters',
    nodes: {
      target.id: target.copyWith(childIds: [exposure.id]),
      exposure.id: exposure,
    },
    rootNodeId: target.id,
  );
}

bridge_event.SkotiqEvent _frameEvent({required bool accepted, double? hfr}) {
  return bridge_event.SkotiqEvent(
    timestamp: DateTime.now().millisecondsSinceEpoch,
    severity: bridge_event.EventSeverity.info,
    category: bridge_event.EventCategory.sequencer,
    eventType: accepted ? 'FrameAccepted' : 'FrameRejected',
    data: {
      'node_id': _exposureNodeId,
      'hfr': hfr,
      if (accepted)
        'save_path': '/captures/d5/frame.fits'
      else
        'reject_path': '/captures/d5/reject.fits',
      if (!accepted) 'reason': 'hfr',
    },
  );
}

void main() {
  setUpAll(registerMocktailFallbackValues);

  late MockBackend backend;
  late StreamController<bridge_event.SkotiqEvent> eventController;
  late SkotiqDatabase db;

  ProviderContainer buildContainer() {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  setUp(() {
    backend = MockBackend();
    eventController = StreamController<bridge_event.SkotiqEvent>.broadcast();
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

  /// Give the fire-and-forget frame registration + checkpoint writes time to
  /// settle.
  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test(
    'sequenced frames advance the session row counters they are stamped with',
    () async {
      final container = buildContainer();
      final executor = container.read(sequenceExecutorProvider);
      container
          .read(currentSequenceProvider.notifier)
          .loadSequence(_sequence(), discardUnsaved: true);

      final sessionNotifier = container.read(sessionStateProvider.notifier);
      await sessionNotifier.startSession(targetName: 'D5 Target');
      final sessionId = container.read(sessionStateProvider).dbSessionId;
      expect(sessionId, isNotNull);

      // Three accepted frames and one rejected.
      executor.handleSequencerEventForTest(
        _frameEvent(accepted: true, hfr: 2.0),
      );
      executor.handleSequencerEventForTest(
        _frameEvent(accepted: true, hfr: 2.2),
      );
      executor.handleSequencerEventForTest(
        _frameEvent(accepted: true, hfr: 2.4),
      );
      executor.handleSequencerEventForTest(_frameEvent(accepted: false));
      await settle();

      // Finalize so the aggregate is flushed onto the row (this is the same
      // call the executor's run finalization makes).
      await sessionNotifier.endSession(status: 'completed');
      await settle();

      final row = await db.sessionsDao.getSessionById(sessionId!);
      expect(row, isNotNull);

      // Every frame completed a capture — including the rejected one, whose
      // shutter did open.
      expect(row!.totalExposures, 4);
      expect(row.successfulExposures, 4);
      // Only accepted frames buy integration time.
      expect(row.totalIntegrationSecs, closeTo(3 * _exposureSecs, 0.001));
      // HFR is averaged over accepted frames only.
      expect(row.avgHfr, closeTo(2.2, 0.001));

      // And the frames really are attributed to this same session — the pair
      // of facts that contradicted each other in the live observation.
      final images = await db.imagesDao.getImagesForSession(sessionId);
      expect(images, hasLength(4));
      for (final image in images) {
        expect(image.sessionId, sessionId);
      }
    },
  );

  test('frames captured with no open session do not throw', () async {
    final container = buildContainer();
    final executor = container.read(sequenceExecutorProvider);
    container
        .read(currentSequenceProvider.notifier)
        .loadSequence(_sequence(), discardUnsaved: true);

    // No startSession() — a bare start-without-session must stay a no-op
    // rather than blowing up the frame handler.
    executor.handleSequencerEventForTest(_frameEvent(accepted: true, hfr: 2.0));
    await settle();

    expect(container.read(sessionStateProvider).dbSessionId, isNull);
    final sessions = await db.sessionsDao.getAllSessions();
    expect(sessions, isEmpty);
  });
}
