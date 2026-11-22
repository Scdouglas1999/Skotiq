// One owner of the camera and the mount at a time: every start asks the live
// state of every other activity (flats, flip, sequence, manual capture) and
// refuses on any. Nothing is claimed or released, so an activity that died
// mid-way holds nothing once its own state says it ended.
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
import 'package:skotiq_core/src/models/rig_activity.dart';
import 'package:skotiq_core/src/providers/rig_activity.dart';
import 'package:skotiq_core/src/providers/sequence/run_record.dart';

import '../mocks/mock_backend.dart';

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
    name: 'Rig owner',
    rootNodeId: root,
    nodes: {
      root: InstructionSetNode(id: root, childIds: const [exposure]),
      exposure: ExposureNode(id: exposure, parentId: root, durationSecs: 10),
    },
  );
}

const _exposure = ExposureSettings(exposureTime: 1, gain: 0, offset: 0);

void main() {
  setUpAll(registerMocktailFallbackValues);

  late _PermissiveBackend backend;
  late ProviderContainer container;

  setUp(() {
    backend = _PermissiveBackend();
    when(() => backend.eventStream).thenAnswer((_) => const Stream.empty());
    when(
      () => backend.polarAlignmentEvents,
    ).thenAnswer((_) => const Stream.empty());
    when(() => backend.sequencerStart()).thenAnswer((_) async {});
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
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
  });

  RigActivity? heldFor(RigActivity starting) =>
      rigHeldBy(container.read, starting: starting);

  void flip(FlipExecutionState state) => container
      .read(flipMonitorProgressProvider.notifier)
      .update((p) => p.copyWith(state: state));

  void run(SequenceExecutionState state) =>
      container.read(runRecordProvider.notifier).setLifecycle(state);

  void manualCapture(bool on) =>
      container.read(sessionStateProvider.notifier).setCapturing(on);

  group('who holds the rig, for each start', () {
    final holders = <String, (void Function(), void Function())>{};
    setUp(() {
      holders
        ..clear()
        ..['flats'] = (
          () =>
              container.read(flatWizardProvider.notifier).reserveStartPrompt(),
          () =>
              container.read(flatWizardProvider.notifier).releaseStartPrompt(),
        )
        ..['flip'] = (
          () => flip(FlipExecutionState.executing),
          () => flip(FlipExecutionState.idle),
        )
        ..['running sequence'] = (
          () => run(SequenceExecutionState.running),
          () => run(SequenceExecutionState.idle),
        )
        ..['paused sequence'] = (
          () => run(SequenceExecutionState.paused),
          () => run(SequenceExecutionState.idle),
        )
        ..['manual capture'] = (
          () => manualCapture(true),
          () => manualCapture(false),
        );
    });

    // holder -> the activity each start sees holding the rig.
    const table = <String, Map<RigActivity, RigActivity?>>{
      'flats': {
        RigActivity.flats: null,
        RigActivity.flip: RigActivity.flats,
        RigActivity.sequence: RigActivity.flats,
        RigActivity.manualCapture: RigActivity.flats,
      },
      'flip': {
        RigActivity.flats: RigActivity.flip,
        RigActivity.flip: null,
        RigActivity.sequence: RigActivity.flip,
        RigActivity.manualCapture: RigActivity.flip,
      },
      'running sequence': {
        RigActivity.flats: RigActivity.sequence,
        RigActivity.flip: RigActivity.sequence,
        RigActivity.sequence: null,
        RigActivity.manualCapture: RigActivity.sequence,
      },
      // Tonight takes its solve and centering frames while it holds the run
      // paused.
      'paused sequence': {
        RigActivity.flats: RigActivity.sequence,
        RigActivity.flip: RigActivity.sequence,
        RigActivity.sequence: null,
        RigActivity.manualCapture: null,
      },
      'manual capture': {
        RigActivity.flats: RigActivity.manualCapture,
        RigActivity.flip: RigActivity.manualCapture,
        RigActivity.sequence: RigActivity.manualCapture,
        RigActivity.manualCapture: null,
      },
    };

    for (final MapEntry(key: holder, value: expected) in table.entries) {
      test(holder, () {
        final (take, end) = holders[holder]!;
        for (final starting in RigActivity.values) {
          expect(heldFor(starting), isNull, reason: 'free before $holder');
        }
        take();
        expect({
          for (final starting in RigActivity.values)
            starting: heldFor(starting),
        }, expected);
        end();
        for (final starting in RigActivity.values) {
          expect(heldFor(starting), isNull, reason: '$holder ended');
        }
      });
    }
  });

  group('each start refuses the activities it did not before', () {
    test('a flat run refuses a manual flip', () async {
      container.read(flatWizardProvider.notifier).reserveStartPrompt();
      final flipped = await container
          .read(meridianFlipStandaloneMonitorProvider.notifier)
          .executeNow();
      expect(flipped, isFalse);
      expect(container.read(flipLastErrorProvider), RigActivity.flats.busy);
    });

    test('a flip refuses a flat run', () {
      flip(FlipExecutionState.executing);
      expect(
        container.read(flatWizardProvider.notifier).startBlockReason,
        RigActivity.flip.busy,
      );
    });

    test('a manual capture refuses a sequence start', () async {
      manualCapture(true);
      await expectLater(
        container.read(sequenceExecutorProvider).start(),
        throwsA(isA<StateError>()),
      );
      verifyNever(() => backend.sequencerStart());
    });

    test('a flip refuses a manual capture', () async {
      flip(FlipExecutionState.executing);
      await expectLater(
        container
            .read(imagingServiceProvider)
            .captureImage(settings: _exposure),
        throwsA(
          isA<DeviceBusyException>().having(
            (error) => error.currentOperation,
            'currentOperation',
            'meridian flip',
          ),
        ),
      );
    });
  });

  group('an activity that died mid-way never blocks the next start', () {
    test('a failed flip', () async {
      flip(FlipExecutionState.executing);
      flip(FlipExecutionState.failed);
      expect(
        container.read(flatWizardProvider.notifier).startBlockReason,
        isNull,
      );
      await container.read(sequenceExecutorProvider).start();
      verify(() => backend.sequencerStart()).called(1);
    });

    test('a manual capture whose exposure threw', () async {
      // No camera is connected: the capture fails inside the pipeline.
      await expectLater(
        container
            .read(imagingServiceProvider)
            .captureImage(settings: _exposure),
        throwsA(isA<ConnectionException>()),
      );
      expect(heldFor(RigActivity.sequence), isNull);
      await container.read(sequenceExecutorProvider).start();
      verify(() => backend.sequencerStart()).called(1);
    });

    test('a run that failed', () {
      run(SequenceExecutionState.running);
      run(SequenceExecutionState.failed);
      for (final starting in RigActivity.values) {
        expect(heldFor(starting), isNull);
      }
    });
  });
}
