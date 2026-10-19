// The safety rules of plan section 4, against the real service wiring
// ([ServiceNightRigOps]) with the services mocked: a failed autofocus never
// parks and never stops the run, and a failed resume leaves the run paused.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/models/command_action_result.dart';
import 'package:skotiq_app/screens/night_control/actions/armed_start_provider.dart';
import 'package:skotiq_app/screens/night_control/actions/night_action_controller.dart';
import 'package:skotiq_app/services/mount_command_service.dart';
import 'package:skotiq_app/services/sequence_action_service.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../../harness/mock_backend.dart';
import '../../../harness/mock_database.dart' show inMemoryDatabaseOverride;
import '../../../harness/pump_app_screen.dart' show TestBackendNotifier;
import 'night_action_test_support.dart';

class _MockSequenceActions extends Mock implements SequenceActionService {}

class _MockDeviceService extends Mock implements DeviceService {}

class _MockMountCommands extends Mock implements MountCommandService {}

/// The executor behind the real [SequenceActionService]: pause and resume
/// move the shared state the way the executor does; resume can be made to
/// throw.
class _RecordingExecutor extends SequenceExecutor {
  _RecordingExecutor(this._ref) : super(_ref);

  final Ref _ref;
  final List<String> calls = [];
  Object? resumeError;

  @override
  Future<void> pause() async {
    calls.add('pause');
    _ref.read(sequenceExecutionStateProvider.notifier).state =
        SequenceExecutionState.paused;
  }

  @override
  Future<void> resume() async {
    calls.add('resume');
    final error = resumeError;
    if (error != null) throw error;
    _ref.read(sequenceExecutionStateProvider.notifier).state =
        SequenceExecutionState.running;
  }

  @override
  Future<void> stop({bool preserveCheckpoint = false, String? origin}) async {
    calls.add('stop');
  }
}

void main() {
  late MockBackend backend;
  late _MockSequenceActions sequence;
  late _MockDeviceService devices;
  late _MockMountCommands mountCommands;
  late ProviderContainer container;

  setUp(() {
    backend = mockBackend();
    sequence = _MockSequenceActions();
    devices = _MockDeviceService();
    mountCommands = _MockMountCommands();
    container = ProviderContainer(overrides: [
      backendProvider.overrideWith((ref) => TestBackendNotifier(ref, backend)),
      backendCanCommandProvider.overrideWithValue(true),
      loggingServiceProvider.overrideWithValue(RecordingLog()),
      cameraStateProvider.overrideWith(TestCameraNotifier.new),
      mountStateProvider.overrideWith(TestMountNotifier.new),
      focuserStateProvider.overrideWith(TestFocuserNotifier.new),
      guiderStateProvider.overrideWith(TestGuiderNotifier.new),
      activeEquipmentProfileProvider.overrideWithValue(null),
      nightCenterTargetProvider.overrideWithValue(null),
      nightCoolerSetpointProvider.overrideWithValue(null),
      nightAstroDarkProvider.overrideWithValue(null),
      sequenceActionServiceProvider.overrideWithValue(sequence),
      deviceServiceProvider.overrideWithValue(devices),
      mountCommandServiceProvider.overrideWithValue(mountCommands),
    ]);
    addTearDown(container.dispose);
    container.listen(nightActionControllerProvider, (_, __) {});

    final run = container.read(sequenceExecutionStateProvider.notifier);
    run.state = SequenceExecutionState.running;
    when(() => sequence.pause()).thenAnswer((_) async {
      run.state = SequenceExecutionState.paused;
      return CommandActionResult.ok;
    });
    when(() => sequence.resume()).thenAnswer((_) async {
      run.state = SequenceExecutionState.running;
      return CommandActionResult.ok;
    });
  });

  void verifyNeverParkedOrStopped() {
    verifyNever(() => devices.parkMount());
    verifyNever(() => mountCommands.park());
    verifyNever(() => mountCommands.togglePark());
    verifyNever(() => backend.mountPark(any()));
    verifyNever(
      () => sequence.stop(preserveCheckpoint: any(named: 'preserveCheckpoint')),
    );
    verifyNever(() => devices.stopSequence());
  }

  void stubAutofocus(Future<AutofocusResult> Function() answer) {
    when(() => devices.runAutofocus(
          exposureTime: any(named: 'exposureTime'),
          stepSize: any(named: 'stepSize'),
          stepsOut: any(named: 'stepsOut'),
          method: any(named: 'method'),
          binning: any(named: 'binning'),
          useSettingsDefaults: any(named: 'useSettingsDefaults'),
        )).thenAnswer((_) => answer());
  }

  test('autofocus throws: the run is resumed and the mount never parks',
      () async {
    stubAutofocus(() async => throw Exception('No stars detected'));

    await container.read(nightActionApiProvider).autofocus();

    verify(() => sequence.pause()).called(1);
    verify(() => sequence.resume()).called(1);
    verifyNeverParkedOrStopped();
    expect(container.read(sequenceExecutionStateProvider),
        SequenceExecutionState.running);
    final state = container.read(nightActionStateProvider);
    expect(state.error?.key, 'nightActErrAutofocus');
    expect(state.error?.params['detail'], 'No stars detected');
    expect(state.runLeftPaused, isFalse);
  });

  test('resume fails: the run stays paused, is never stopped or parked',
      () async {
    stubAutofocus(() async => throw Exception('No stars detected'));
    when(() => sequence.resume()).thenAnswer(
      (_) async => const CommandActionResult.failure('bridge timeout'),
    );

    await container.read(nightActionApiProvider).autofocus();

    verify(() => sequence.resume()).called(1);
    verifyNeverParkedOrStopped();
    expect(container.read(sequenceExecutionStateProvider),
        SequenceExecutionState.paused);
    final state = container.read(nightActionStateProvider);
    expect(state.runLeftPaused, isTrue);
    expect(state.error?.key, 'nightActErrResume');
  });

  group('through the real SequenceActionService', () {
    late _RecordingExecutor executor;
    late ProviderContainer real;

    setUp(() {
      real = ProviderContainer(overrides: [
        inMemoryDatabaseOverride(),
        sequenceExecutorProvider.overrideWith(
          (ref) => executor = _RecordingExecutor(ref),
        ),
        backendProvider
            .overrideWith((ref) => TestBackendNotifier(ref, backend)),
        backendCanCommandProvider.overrideWithValue(true),
        loggingServiceProvider.overrideWithValue(RecordingLog()),
        cameraStateProvider.overrideWith(TestCameraNotifier.new),
        mountStateProvider.overrideWith(TestMountNotifier.new),
        focuserStateProvider.overrideWith(TestFocuserNotifier.new),
        guiderStateProvider.overrideWith(TestGuiderNotifier.new),
        activeEquipmentProfileProvider.overrideWithValue(null),
        nightCenterTargetProvider.overrideWithValue(null),
        nightCoolerSetpointProvider.overrideWithValue(null),
        nightAstroDarkProvider.overrideWithValue(null),
        deviceServiceProvider.overrideWithValue(devices),
        mountCommandServiceProvider.overrideWithValue(mountCommands),
      ]);
      addTearDown(real.dispose);
      real.read(sequenceExecutorProvider);
      real.listen(nightActionControllerProvider, (_, __) {});
      real.read(sequenceExecutionStateProvider.notifier).state =
          SequenceExecutionState.running;
    });

    test('a failed autofocus pauses, then resumes the run', () async {
      stubAutofocus(() async => throw Exception('No stars detected'));

      await real.read(nightActionApiProvider).autofocus();

      expect(executor.calls, ['pause', 'resume']);
      expect(real.read(sequenceExecutionStateProvider),
          SequenceExecutionState.running);
      verifyNever(() => devices.parkMount());
      verifyNever(() => backend.mountPark(any()));
    });

    test('a resume the executor rejects leaves the run paused', () async {
      stubAutofocus(() async => throw Exception('No stars detected'));
      executor.resumeError = StateError('native resume failed');

      await real.read(nightActionApiProvider).autofocus();

      expect(executor.calls, ['pause', 'resume']);
      expect(real.read(sequenceExecutionStateProvider),
          SequenceExecutionState.paused);
      final state = real.read(nightActionStateProvider);
      expect(state.runLeftPaused, isTrue);
      expect(state.error?.params['detail'], contains('native resume failed'));
      verifyNever(() => devices.parkMount());
    });
  });

  test('no file of the action package can park or stop a run', () {
    final files = [
      ...Directory('lib/screens/night_control/actions')
          .listSync()
          .whereType<File>(),
      File('lib/services/manual_capture_controller.dart'),
    ];
    expect(files.length, greaterThan(4));
    final forbidden = RegExp(
      r'parkMount\(|mountPark\(|togglePark\(|\.park\(|stopSequence\(|'
      r'_sequence\.stop\(|\.stop\(\s*preserveCheckpoint',
    );
    for (final file in files) {
      final hits = forbidden
          .allMatches(file.readAsStringSync())
          .map((m) => m.group(0))
          .toList();
      expect(hits, isEmpty, reason: file.path);
    }
  });
}
