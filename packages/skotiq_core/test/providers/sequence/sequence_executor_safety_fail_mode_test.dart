// The safety fail mode the executor pushes to Rust.
//
// The Rust safety poll fail-closes when there is no safety-monitor / weather
// device on the rig, and the in-sequencer `WeatherUnsafe` trigger is ALWAYS
// armed. So pushing `fail_closed` on a rig where the operator has weather
// safety switched off parks the mount and aborts the sequence within ~100 ms of
// start, reporting only "Sequence cancelled".
//
// Pushing `settings.safetyFailMode` raw from any call site does exactly that:
// the "Recover Sequence?" -> Resume button then aborts instantly on every rig
// without a safety monitor, which is the default rig.
//
// These tests pin all three call sites to the one shared
// `_effectiveSafetyFailMode` computation.

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart' as bridge_event;

import '../../mocks/mock_backend.dart';

/// A backend whose unstubbed members answer with a completed `Future<void>`,
/// so the deep runtime-config push runs end to end without stubbing 30 calls.
class _PermissiveBackend extends MockBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) {
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
    name: 'fail mode test',
    nodes: {root.id: root},
    rootNodeId: root.id,
  );
}

void main() {
  setUpAll(registerMocktailFallbackValues);

  late _PermissiveBackend backend;
  late StreamController<bridge_event.SkotiqEvent> eventController;
  late SkotiqDatabase db;
  late List<String> pushedModes;
  ProviderContainer? container;

  ProviderContainer buildContainer({
    required bool weatherSafetyEnabled,
    SafetyFailMode configured = SafetyFailMode.failClosed,
  }) {
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
        weatherSettingsProvider.overrideWithValue(
          WeatherSettings.defaultSettings.copyWith(
            weatherSafetyEnabled: weatherSafetyEnabled,
          ),
        ),
        appSettingsProvider.overrideWith(
          () => _FixedSettingsNotifier(
            AppSettingsState(safetyFailMode: configured),
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
    pushedModes = [];
    backend = _PermissiveBackend();
    eventController = StreamController<bridge_event.SkotiqEvent>.broadcast();
    when(() => backend.eventStream).thenAnswer((_) => eventController.stream);
    when(
      () => backend.polarAlignmentEvents,
    ).thenAnswer((_) => const Stream.empty());
    when(() => backend.sequencerSetSafetyFailMode(any())).thenAnswer((
      inv,
    ) async {
      pushedModes.add(inv.positionalArguments.first as String);
    });
    when(() => backend.getCheckpointInfo()).thenAnswer(
      (_) async => CheckpointInfo(
        sequenceName: 'fail mode test',
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

  test(
    'resume pushes fail_open when weather safety is off, like start does',
    () async {
      final c = buildContainer(weatherSafetyEnabled: false);
      c.read(currentSequenceProvider.notifier).loadSequence(_buildSequence());
      final executor = c.read(sequenceExecutorProvider);

      await executor.resumeFromCheckpoint();

      expect(
        pushedModes,
        isNotEmpty,
        reason: 'the resume path must push a fail mode at all',
      );
      expect(
        pushedModes,
        everyElement('fail_open'),
        reason:
            'with weather safety disabled and no safety monitor on the rig, '
            'pushing fail_closed arms the always-on WeatherUnsafe trigger and '
            'parks + aborts the resumed run within ~100 ms',
      );

      await executor.stop();
    },
  );

  test('start pushes fail_open when weather safety is off', () async {
    final c = buildContainer(weatherSafetyEnabled: false);
    c.read(currentSequenceProvider.notifier).loadSequence(_buildSequence());
    final executor = c.read(sequenceExecutorProvider);

    await executor.start();

    expect(pushedModes, isNotEmpty);
    expect(pushedModes, everyElement('fail_open'));

    await executor.stop();
  });

  test(
    'resume honours the configured fail_closed once weather safety is on',
    () async {
      final c = buildContainer(weatherSafetyEnabled: true);
      c.read(currentSequenceProvider.notifier).loadSequence(_buildSequence());
      final executor = c.read(sequenceExecutorProvider);

      await executor.resumeFromCheckpoint();

      expect(
        pushedModes,
        contains('fail_closed'),
        reason:
            'the guard must only relax the mode while the operator has opted '
            'out of weather safety — it is not a blanket downgrade',
      );

      await executor.stop();
    },
  );

  test(
    'start honours the configured fail_closed when weather safety is on',
    () async {
      final c = buildContainer(weatherSafetyEnabled: true);
      c.read(currentSequenceProvider.notifier).loadSequence(_buildSequence());
      final executor = c.read(sequenceExecutorProvider);

      await executor.start();

      expect(pushedModes, contains('fail_closed'));

      await executor.stop();
    },
  );
}
