// The operator's "Camera retries" and "Filter wheel retries" reach the native
// executor.
//
// The executor retries a failed exposure or filter-wheel move up to its own
// default (3) unless told otherwise. Every launch path (editor start,
// checkpoint resume, headless start) goes through the same launch push, and a
// value changed mid-run is pushed again.

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart' as bridge_event;

import '../../mocks/mock_backend.dart';

/// Records every device-retries push; everything else answers with a
/// completed `Future<void>` so the launch push runs end to end.
class _RecordingBackend extends MockBackend {
  final List<Map<Symbol, dynamic>> retryPushes = [];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #sequencerSetDeviceRetries) {
      retryPushes.add(invocation.namedArguments);
      return Future<void>.value();
    }
    final result = super.noSuchMethod(invocation);
    return result ?? Future<void>.value();
  }
}

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

class _FixedSettingsNotifier extends AppSettingsNotifier {
  _FixedSettingsNotifier(this._state);
  final AppSettingsState _state;

  @override
  Future<AppSettingsState> build() async => _state;

  void replace(AppSettingsState next) => state = AsyncData(next);
}

SequenceValidatorService _passingValidator(Ref ref) => SequenceValidatorService(
  ref: ref,
  syncRules: const [],
  refAwareRules: const [],
  asyncRules: const [],
);

Sequence _buildSequence() {
  final root = InstructionSetNode(id: 'root', name: 'Sequence');
  return Sequence.create(
    name: 'device retries test',
    nodes: {root.id: root},
    rootNodeId: root.id,
  );
}

void main() {
  setUpAll(registerMocktailFallbackValues);

  late _RecordingBackend backend;
  late StreamController<bridge_event.SkotiqEvent> eventController;
  late SkotiqDatabase db;
  ProviderContainer? container;

  ProviderContainer buildContainer(AppSettingsState settings) {
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
        appSettingsProvider.overrideWith(
          () => _FixedSettingsNotifier(settings),
        ),
        sequenceValidatorProvider.overrideWith(_passingValidator),
      ],
    );
    container = c;
    return c;
  }

  setUp(() {
    container = null;
    backend = _RecordingBackend();
    eventController = StreamController<bridge_event.SkotiqEvent>.broadcast();
    when(() => backend.eventStream).thenAnswer((_) => eventController.stream);
    when(
      () => backend.polarAlignmentEvents,
    ).thenAnswer((_) => const Stream.empty());
    when(() => backend.getCheckpointInfo()).thenAnswer(
      (_) async => CheckpointInfo(
        sequenceName: 'device retries test',
        timestamp: DateTime.now(),
        completedExposures: 3,
        completedIntegrationSecs: 6.0,
        canResume: true,
        ageSeconds: 12,
      ),
    );
    when(() => backend.resumeFromCheckpoint()).thenAnswer((_) async {});
    when(() => backend.sequencerStart()).thenAnswer((_) async {});
    when(() => backend.sequencerStop()).thenAnswer((_) async {
      scheduleMicrotask(() {
        if (!eventController.isClosed) {
          eventController.add(
            bridge_event.SkotiqEvent(
              timestamp: DateTime.now().millisecondsSinceEpoch,
              severity: bridge_event.EventSeverity.info,
              category: bridge_event.EventCategory.sequencer,
              eventType: 'Stopped',
              data: const {},
            ),
          );
        }
      });
    });
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    container?.dispose();
    if (!eventController.isClosed) {
      await eventController.close();
    }
    await db.close();
  });

  Map<Symbol, dynamic> retries(int camera, int wheel) => {
    #cameraRetries: camera,
    #filterWheelRetries: wheel,
  };

  test('start tells the executor the operator\'s retry counts', () async {
    final c = buildContainer(
      const AppSettingsState(cameraRetries: 5, filterWheelRetries: 0),
    );
    c.read(currentSequenceProvider.notifier).loadSequence(_buildSequence());
    final executor = c.read(sequenceExecutorProvider);

    await executor.start();

    expect(backend.retryPushes, contains(equals(retries(5, 0))));
    await executor.stop();
  });

  test('resume tells the executor too', () async {
    final c = buildContainer(
      const AppSettingsState(cameraRetries: 1, filterWheelRetries: 2),
    );
    c.read(currentSequenceProvider.notifier).loadSequence(_buildSequence());
    final executor = c.read(sequenceExecutorProvider);

    await executor.resumeFromCheckpoint();

    expect(backend.retryPushes, contains(equals(retries(1, 2))));
    await executor.stop();
  });

  test('the shipped default is 3 for each', () async {
    final c = buildContainer(const AppSettingsState());
    c.read(currentSequenceProvider.notifier).loadSequence(_buildSequence());
    final executor = c.read(sequenceExecutorProvider);

    await executor.start();

    expect(backend.retryPushes, contains(equals(retries(3, 3))));
    await executor.stop();
  });

  test('a retry count changed during the run is pushed again', () async {
    final c = buildContainer(const AppSettingsState());
    c.read(currentSequenceProvider.notifier).loadSequence(_buildSequence());
    final executor = c.read(sequenceExecutorProvider);
    await executor.start();
    backend.retryPushes.clear();

    (c.read(appSettingsProvider.notifier) as _FixedSettingsNotifier).replace(
      const AppSettingsState(cameraRetries: 0),
    );
    await Future<void>.delayed(Duration.zero);
    expect(backend.retryPushes, contains(equals(retries(0, 3))));

    await executor.stop();
  });
}
