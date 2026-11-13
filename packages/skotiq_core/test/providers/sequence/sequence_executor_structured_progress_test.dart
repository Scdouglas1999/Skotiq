import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import '../../mocks/mock_backend.dart';
import 'package:skotiq_core/src/models/backend/backend_types.dart' as backend_events;

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

void main() {
  late MockBackend backend;
  late StreamController<backend_events.SkotiqEvent> eventController;
  late SkotiqDatabase db;

  setUp(() {
    backend = MockBackend();
    eventController = StreamController<backend_events.SkotiqEvent>.broadcast();
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

  test('stores structured instruction progress from backend events', () {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);

    final executor = container.read(sequenceExecutorProvider);
    executor.handleSequencerEventForTest(
      backend_events.SkotiqEvent(
        timestamp: DateTime.now().millisecondsSinceEpoch,
        severity: backend_events.EventSeverity.info,
        category: backend_events.EventCategory.sequencer,
        eventType: 'InstructionProgressStructured',
        data: const {
          'node_id': 'exposure-1',
          'instruction': 'TakeExposure',
          'progress_percent': 42.0,
          'detail_kind': 'Exposure',
          'detail_json': {'frame': 4, 'total': 10, 'duration_secs': 180},
        },
      ),
    );
    executor.handleSequencerEventForTest(
      backend_events.SkotiqEvent(
        timestamp: DateTime.now().millisecondsSinceEpoch,
        severity: backend_events.EventSeverity.info,
        category: backend_events.EventCategory.sequencer,
        eventType: 'InstructionProgress',
        data: const {
          'node_id': 'exposure-1',
          'instruction': 'TakeExposure',
          'progress_percent': 42.0,
          'detail': 'Frame 4/10 (180.0s)',
        },
      ),
    );

    final progress = container.read(sequenceProgressProvider);
    expect(progress.nodeProgressPercent['exposure-1'], 42);
    expect(
      progress.nodeProgressStructuredDetail['exposure-1'],
      isA<ExposureInstructionProgressDetail>(),
    );
    expect(progress.message, 'TakeExposure: Frame 4/10 (180.0s)');
  });

  test('a step reporting in words keeps its line and its last reading', () {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);

    final executor = container.read(sequenceExecutorProvider);
    void send(String type, Map<String, Object?> data) {
      executor.handleSequencerEventForTest(
        backend_events.SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: backend_events.EventSeverity.info,
          category: backend_events.EventCategory.sequencer,
          eventType: type,
          data: data,
        ),
      );
    }

    send('InstructionProgress', {
      'node_id': 'guide-1',
      'instruction': 'Start Guiding',
      'progress_percent': 20.0,
      'detail': 'Connecting to guider',
    });
    send('InstructionProgressStructured', {
      'node_id': 'guide-1',
      'instruction': 'Start Guiding',
      'progress_percent': 60.0,
      'detail_kind': 'Generic',
      'detail_json': 'Waiting for guiding to stabilize',
    });

    final progress = container.read(sequenceProgressProvider);
    expect(progress.message, 'Start Guiding: Connecting to guider');
    expect(progress.nodeProgressPercent['guide-1'], 60);
  });
}
