// The operator's two park settings reach the native executor.
//
// "Park on unsafe weather" and "Park before dawn" were read only by the Dart
// weather-safety evaluator. The native executor builds its own Weather Unsafe
// and Dawn Approaching triggers, both of which park the mount and close the
// cover and dome, and nothing told it the operator had switched parking off:
// a run with both settings off still parked when the weather verdict went
// unsafe or dawn came near. Every launch path (editor start, checkpoint
// resume, headless start) goes through the same launch push, and a setting
// changed mid-run is pushed again.

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart' as bridge_event;

import '../../mocks/mock_backend.dart';

/// Records every park-policy push; everything else answers with a completed
/// `Future<void>` so the launch push runs end to end.
class _RecordingBackend extends MockBackend {
  final List<Map<Symbol, dynamic>> parkPolicyPushes = [];
  final List<bool> qualityPolicyPushes = [];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #sequencerSetParkPolicy) {
      parkPolicyPushes.add(invocation.namedArguments);
      return Future<void>.value();
    }
    if (invocation.memberName == #sequencerSetStopOnQualityProblems) {
      qualityPolicyPushes.add(invocation.positionalArguments.single as bool);
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

final _weatherSettings = StateProvider<WeatherSettings>(
  (ref) => WeatherSettings.defaultSettings.copyWith(weatherSafetyEnabled: true),
);

SequenceValidatorService _passingValidator(Ref ref) => SequenceValidatorService(
  ref: ref,
  syncRules: const [],
  refAwareRules: const [],
  asyncRules: const [],
);

Sequence _buildSequence() {
  final root = InstructionSetNode(id: 'root', name: 'Sequence');
  return Sequence.create(
    name: 'park policy test',
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

  ProviderContainer buildContainer({
    required bool parkOnUnsafeWeather,
    required bool parkBeforeDawn,
    bool autoParkEnabled = true,
    bool stopRunOnQualityProblems = false,
  }) {
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
        _weatherSettings.overrideWith(
          (ref) => WeatherSettings.defaultSettings.copyWith(
            weatherSafetyEnabled: true,
            autoParkEnabled: autoParkEnabled,
          ),
        ),
        weatherSettingsProvider.overrideWith(
          (ref) => ref.watch(_weatherSettings),
        ),
        appSettingsProvider.overrideWith(
          () => _FixedSettingsNotifier(
            AppSettingsState(
              parkOnUnsafeWeather: parkOnUnsafeWeather,
              parkBeforeDawn: parkBeforeDawn,
              stopRunOnQualityProblems: stopRunOnQualityProblems,
            ),
          ),
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
        sequenceName: 'park policy test',
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

  Map<Symbol, dynamic> policy(bool weather, bool dawn) => {
    #parkOnUnsafeWeather: weather,
    #parkBeforeDawn: dawn,
  };

  test('start tells the executor that parking is switched off', () async {
    final c = buildContainer(parkOnUnsafeWeather: false, parkBeforeDawn: false);
    c.read(currentSequenceProvider.notifier).loadSequence(_buildSequence());
    final executor = c.read(sequenceExecutorProvider);

    await executor.start();

    expect(
      backend.parkPolicyPushes,
      contains(equals(policy(false, false))),
      reason:
          'with both park settings off the native weather and dawn triggers '
          'still parked the mount, because nothing told them',
    );
    await executor.stop();
  });

  test('resume tells the executor too', () async {
    final c = buildContainer(parkOnUnsafeWeather: false, parkBeforeDawn: true);
    c.read(currentSequenceProvider.notifier).loadSequence(_buildSequence());
    final executor = c.read(sequenceExecutorProvider);

    await executor.resumeFromCheckpoint();

    expect(backend.parkPolicyPushes, contains(equals(policy(false, true))));
    await executor.stop();
  });

  test(
    'weather parking is off when Weather Safety auto-park is off, the other half '
    'of the same setting',
    () async {
      final c = buildContainer(
        parkOnUnsafeWeather: true,
        parkBeforeDawn: true,
        autoParkEnabled: false,
      );
      c.read(currentSequenceProvider.notifier).loadSequence(_buildSequence());
      final executor = c.read(sequenceExecutorProvider);

      await executor.start();

      expect(backend.parkPolicyPushes, contains(equals(policy(false, true))));
      await executor.stop();
    },
  );

  test('the shipped defaults keep parking on', () async {
    final c = buildContainer(parkOnUnsafeWeather: true, parkBeforeDawn: true);
    c.read(currentSequenceProvider.notifier).loadSequence(_buildSequence());
    final executor = c.read(sequenceExecutorProvider);

    await executor.start();

    expect(backend.parkPolicyPushes, contains(equals(policy(true, true))));
    await executor.stop();
  });

  test('a park setting changed during the run is pushed again', () async {
    final c = buildContainer(parkOnUnsafeWeather: true, parkBeforeDawn: true);
    c.read(currentSequenceProvider.notifier).loadSequence(_buildSequence());
    final executor = c.read(sequenceExecutorProvider);
    await executor.start();
    backend.parkPolicyPushes.clear();

    (c.read(appSettingsProvider.notifier) as _FixedSettingsNotifier).replace(
      const AppSettingsState(parkBeforeDawn: false),
    );
    await Future<void>.delayed(Duration.zero);
    expect(backend.parkPolicyPushes, contains(equals(policy(true, false))));

    c.read(_weatherSettings.notifier).state = WeatherSettings.defaultSettings
        .copyWith(weatherSafetyEnabled: true, autoParkEnabled: false);
    await Future<void>.delayed(Duration.zero);
    expect(backend.parkPolicyPushes, contains(equals(policy(false, false))));

    await executor.stop();
  });

  // "Stop the run for quality problems" reaches the executor the same way:
  // off by default (owner decision 2026-10-06), and an operator who turned it
  // on must have it before the first frame and when they change it mid-run.
  group('quality policy', () {
    test('start tells the executor that quality problems notify', () async {
      final c = buildContainer(parkOnUnsafeWeather: true, parkBeforeDawn: true);
      c.read(currentSequenceProvider.notifier).loadSequence(_buildSequence());
      final executor = c.read(sequenceExecutorProvider);

      await executor.start();

      expect(backend.qualityPolicyPushes, [false]);
      await executor.stop();
    });

    test('an operator who turned it on gets the stop', () async {
      final c = buildContainer(
        parkOnUnsafeWeather: true,
        parkBeforeDawn: true,
        stopRunOnQualityProblems: true,
      );
      c.read(currentSequenceProvider.notifier).loadSequence(_buildSequence());
      final executor = c.read(sequenceExecutorProvider);

      await executor.start();
      expect(backend.qualityPolicyPushes, [true]);

      (c.read(appSettingsProvider.notifier) as _FixedSettingsNotifier).replace(
        const AppSettingsState(),
      );
      await Future<void>.delayed(Duration.zero);
      expect(backend.qualityPolicyPushes, [true, false]);
      await executor.stop();
    });
  });
}
