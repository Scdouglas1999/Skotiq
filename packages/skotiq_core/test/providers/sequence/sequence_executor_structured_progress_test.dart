import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart' as backend_events;

import '../../mocks/mock_backend.dart';

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

    final progress = container.read(sequenceProgressProvider);
    expect(progress.nodeProgressPercent['exposure-1'], 42);
    expect(
      progress.nodeProgressStructuredDetail['exposure-1'],
      isA<ExposureInstructionProgressDetail>(),
    );
    expect(progress.message, 'TakeExposure: Exposure');
  });
}
