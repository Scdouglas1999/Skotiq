// A flat run or a meridian flip already owns the camera and the mount.
// Start and a manual capture must refuse before either commands an exposure.
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/settings.dart';

import '../../mocks/mock_backend.dart';

class _PermissiveBackend extends MockBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation) ?? Future<void>.value();
  }
}

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

class _FixedSettings extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => const AppSettingsState();
}

SequenceValidatorService _passing(Ref ref) => SequenceValidatorService(
  ref: ref,
  syncRules: const [],
  refAwareRules: const [],
  asyncRules: const [],
);

Sequence _sequence() {
  const root = 'root';
  const exposure = 'exposure';
  return Sequence.create(
    name: 'Busy gate',
    rootNodeId: root,
    nodes: {
      root: InstructionSetNode(id: root, childIds: const [exposure]),
      exposure: ExposureNode(id: exposure, parentId: root, durationSecs: 10),
    },
  );
}

void main() {
  setUpAll(registerMocktailFallbackValues);

  test('a flat run or a flip refuses capture and sequence start', () async {
    final backend = _PermissiveBackend();
    when(() => backend.eventStream).thenAnswer((_) => const Stream.empty());
    when(
      () => backend.polarAlignmentEvents,
    ).thenAnswer((_) => const Stream.empty());
    when(() => backend.sequencerStart()).thenAnswer((_) async {});
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
        appSettingsProvider.overrideWith(() => _FixedSettings()),
        sequenceValidatorProvider.overrideWith(_passing),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(db.close);
    container.read(currentSequenceProvider.notifier).loadSequence(_sequence());
    final imaging = container.read(imagingServiceProvider);

    expect(
      container.read(flatWizardProvider.notifier).reserveStartPrompt(),
      isTrue,
    );
    await expectLater(
      imaging.captureImage(
        settings: const ExposureSettings(exposureTime: 1, gain: 0, offset: 0),
      ),
      throwsA(
        isA<DeviceBusyException>().having(
          (error) => error.currentOperation,
          'currentOperation',
          'flat capture',
        ),
      ),
    );
    await expectLater(
      container.read(sequenceExecutorProvider).start(),
      throwsA(isA<StateError>()),
    );
    verifyNever(() => backend.sequencerStart());
    verifyNever(
      () => backend.cameraStartExposure(
        deviceId: any(named: 'deviceId'),
        exposureTime: any(named: 'exposureTime'),
        frameType: any(named: 'frameType'),
      ),
    );
    container.read(flatWizardProvider.notifier).releaseStartPrompt();

    container.read(flipExecutionStateProvider.notifier).state =
        FlipExecutionState.executing;
    await expectLater(
      container.read(sequenceExecutorProvider).start(),
      throwsA(isA<StateError>()),
    );
    verifyNever(() => backend.sequencerStart());
    container.read(flipExecutionStateProvider.notifier).state =
        FlipExecutionState.idle;

    await container.read(sequenceExecutorProvider).start();
    verify(() => backend.sequencerStart()).called(1);
  });
}
