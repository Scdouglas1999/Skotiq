// Shared fakes for the night-control action tests.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_app/models/command_action_result.dart';
import 'package:skotiq_app/screens/night_control/actions/armed_start_provider.dart';
import 'package:skotiq_app/screens/night_control/actions/night_action_controller.dart';
import 'package:skotiq_app/screens/night_control/actions/night_rig_ops.dart';
import 'package:skotiq_app/screens/night_control/actions/solve_and_sync.dart';
import 'package:skotiq_core/skotiq_core.dart';

const connected = DeviceConnectionState.connected;

class TestCameraNotifier extends CameraStateNotifier {
  TestCameraNotifier(super.ref) {
    state = const CameraStateSnapshot(
      connectionState: connected,
      deviceId: 'camera-1',
    );
  }

  void put(CameraStateSnapshot snapshot) => state = snapshot;
}

class TestMountNotifier extends MountStateNotifier {
  TestMountNotifier(super.ref) {
    state = const MountState(
      connectionState: connected,
      deviceId: 'mount-1',
      isTracking: true,
      isParked: false,
      ra: 1.5,
      dec: 30,
    );
  }

  void put(MountState snapshot) => state = snapshot;
}

class TestFocuserNotifier extends FocuserStateNotifier {
  TestFocuserNotifier(super.ref) {
    state = const FocuserState(connectionState: connected, deviceId: 'foc-1');
  }
}

class TestGuiderNotifier extends GuiderStateNotifier {
  TestGuiderNotifier(super.ref) {
    state = const GuiderState(
      connectionState: connected,
      deviceId: 'phd2',
      isGuiding: true,
    );
  }

  void put(GuiderState snapshot) => state = snapshot;
}

/// Records log lines instead of writing them.
class RecordingLog extends LoggingService {
  final List<String> lines = [];

  @override
  void debug(String message, {String? source, Map<String, Object?>? fields}) {}
  @override
  void info(String message, {String? source, Map<String, Object?>? fields}) =>
      lines.add('I $message');
  @override
  void warning(String message,
          {String? source, Map<String, Object?>? fields}) =>
      lines.add('W $message');
  @override
  void error(String message, {String? source, Map<String, Object?>? fields}) =>
      lines.add('E $message');
}

/// A rig whose run and devices are scripted by the test.
///
/// Pause and resume move `sequenceExecutionStateProvider` the way the
/// executor does. Each device action can be held open with a [Completer]
/// so the test can look at the state while it runs.
class FakeRigOps implements NightRigOps {
  FakeRigOps(this.container);

  final ProviderContainer container;
  final List<String> calls = [];

  CommandActionResult pauseResult = CommandActionResult.ok;
  CommandActionResult resumeResult = CommandActionResult.ok;
  CommandActionResult startResult = CommandActionResult.ok;

  Completer<void>? actionGate;
  Object? actionError;
  Completer<void>? loopGate;
  SolveAndSyncResult solveResult = const SolveAndSyncResult(
    usedLastFrame: true,
    solveDuration: Duration(milliseconds: 4200),
    raHours: 1.5,
    decDegrees: 30,
    synced: true,
  );
  bool guiding = true;

  SequenceExecutionState get _run =>
      container.read(sequenceExecutionStateProvider);
  set _run(SequenceExecutionState value) =>
      container.read(sequenceExecutionStateProvider.notifier).state = value;

  Future<void> _act(String name) async {
    calls.add(name);
    final gate = actionGate;
    if (gate != null) await gate.future;
    final error = actionError;
    if (error != null) throw error;
  }

  @override
  Future<CommandActionResult> pauseRun() async {
    calls.add('pause');
    if (pauseResult.isSuccess && _run == SequenceExecutionState.running) {
      _run = SequenceExecutionState.paused;
    }
    return pauseResult;
  }

  @override
  Future<CommandActionResult> resumeRun() async {
    calls.add('resume');
    if (resumeResult.isSuccess && _run == SequenceExecutionState.paused) {
      _run = SequenceExecutionState.running;
    }
    return resumeResult;
  }

  @override
  Future<CommandActionResult> startRun() async {
    calls.add('start');
    return startResult;
  }

  @override
  Future<void> snapshot() => _act('snapshot');

  @override
  Future<void> loop({required void Function(String error) onError}) async {
    calls.add('loop');
    final gate = loopGate ??= Completer<void>();
    await gate.future;
  }

  @override
  void stopCapture() {
    calls.add('stopCapture');
    final gate = loopGate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  @override
  Future<AutofocusResult> autofocus() async {
    await _act('autofocus');
    return const AutofocusResult(
      bestPosition: 1000,
      bestHfr: 2.0,
      focusData: [],
      method: 'VCurve',
      timestamp: 0,
      curveFitQuality: 0.99,
      backlashApplied: false,
    );
  }

  @override
  Future<void> cancelAutofocus() async {
    calls.add('cancelAutofocus');
    final gate = actionGate;
    if (gate != null && !gate.isCompleted) {
      gate.completeError(const AutofocusCancelledException());
    }
  }

  @override
  Future<SolveAndSyncResult> solveAndSync({bool Function()? cancelled}) async {
    await _act('solveAndSync');
    return solveResult;
  }

  @override
  void cancelSolve() => calls.add('cancelSolve');

  @override
  Future<CenteringResult> center(NightCenterTarget target) async {
    await _act('center ${target.name}');
    return CenteringResult.success(
      finalOffsetArcsec: 10,
      iterations: 1,
      iterationHistory: const [],
    );
  }

  @override
  Future<void> cancelCenter() async => calls.add('cancelCenter');

  @override
  bool get isGuiding => guiding;

  @override
  Future<void> stopGuiding() async {
    calls.add('stopGuiding');
    guiding = false;
  }

  @override
  Future<void> startGuidingAndSettle() async {
    calls.add('startGuidingAndSettle');
    guiding = true;
  }

  @override
  Future<void> dither() => _act('dither');

  @override
  Future<String?> flip() async {
    calls.add('flip');
    return null;
  }

  @override
  Future<CommandActionResult> setTracking(bool enabled) async {
    calls.add('setTracking $enabled');
    return CommandActionResult.ok;
  }

  @override
  Future<void> setCooler({required bool enabled, double? targetTemp}) async {
    calls.add('setCooler $enabled $targetTemp');
  }
}

/// A container with every device connected, the run idle and [FakeRigOps].
({ProviderContainer container, FakeRigOps ops, RecordingLog log})
    actionHarness({
  bool canCommand = true,
  SequenceExecutionState runState = SequenceExecutionState.idle,
  NightCenterTarget? target = const NightCenterTarget(
    name: 'M74',
    raHours: 1.61,
    decDegrees: 15.78,
  ),
  double? coolerSetpoint = -10,
  DateTime? astroDark,
  List<Override> extra = const [],
}) {
  late FakeRigOps ops;
  final log = RecordingLog();
  final container = ProviderContainer(overrides: [
    backendCanCommandProvider.overrideWithValue(canCommand),
    loggingServiceProvider.overrideWithValue(log),
    cameraStateProvider.overrideWith(TestCameraNotifier.new),
    mountStateProvider.overrideWith(TestMountNotifier.new),
    focuserStateProvider.overrideWith(TestFocuserNotifier.new),
    guiderStateProvider.overrideWith(TestGuiderNotifier.new),
    activeEquipmentProfileProvider.overrideWithValue(null),
    nightCenterTargetProvider.overrideWithValue(target),
    nightCoolerSetpointProvider.overrideWithValue(coolerSetpoint),
    nightRigOpsProvider.overrideWith((ref) => ops),
    nightAstroDarkProvider.overrideWithValue(astroDark),
    ...extra,
  ]);
  ops = FakeRigOps(container);
  container.read(sequenceExecutionStateProvider.notifier).state = runState;
  // Keep the controller alive for the whole test.
  container.listen(nightActionControllerProvider, (_, __) {});
  return (container: container, ops: ops, log: log);
}

/// Lets queued microtasks and zero-length timers run.
Future<void> settle() => Future<void>.delayed(Duration.zero);
