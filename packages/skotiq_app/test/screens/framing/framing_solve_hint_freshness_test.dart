// Where "Solve latest camera frame" gets its position hint.
//
// The framing target is resolved once and then outlives every slew of the
// session. On 2026-09-13 at 03:21 UTC the owner's manual solves hinted from
// coordinates that were hours and a whole polar alignment old, ASTAP was told
// to look within 5° of them, and it answered "No solution found!" in a second
// — twice — while the automatic post-capture solve of the same camera was
// succeeding from the mount's live position. The button has to hint from where
// the telescope IS, read at click time.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/framing/widgets/framing_actions_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

class _SeededFramingNotifier extends FramingNotifier {
  _SeededFramingNotifier(super.ref, FramingState seed) {
    // ignore: invalid_use_of_protected_member
    state = seed;
  }
}

/// A mount whose reported position the test moves between clicks, the way a
/// slew does.
class _StagedMountNotifier extends MountStateNotifier {
  _StagedMountNotifier(super.ref, MountState seed) {
    report(seed);
  }

  void report(MountState next) {
    // ignore: invalid_use_of_protected_member
    state = next;
  }
}

/// Records the hint each solve was asked for.
class _RecordingPlateSolveService extends PlateSolveService {
  _RecordingPlateSolveService(super.ref);

  final hints = <({double? raHours, double? decDegrees, double? radius})>[];

  @override
  Future<PlateSolveResult> solveWithFallback({
    required String imagePath,
    double? hintRaHours,
    double? hintDecDegrees,
    double? searchRadiusDegrees,
    int? timeoutSeconds,
  }) async {
    hints.add((
      raHours: hintRaHours,
      decDegrees: hintDecDegrees,
      radius: searchRadiusDegrees,
    ));
    return _solved();
  }
}

const _target = FramingTarget(name: 'M42', raHours: 5.5, decDegrees: -5.4);
const _framingState = FramingState(target: _target);

MountState _mountAt(double raHours, double decDegrees) => MountState(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'mount-1',
      deviceName: 'NYX-101',
      ra: raHours,
      dec: decDegrees,
      isParked: false,
      isTracking: true,
    );

CapturedImageData _frame() => CapturedImageData(
      width: 2,
      height: 2,
      displayData: Uint8List(16),
      histogram: List<int>.filled(256, 0),
      stats: const ImageStats(mean: 100, stdDev: 5, hfr: 1.5),
      capturedAt: DateTime.utc(2026, 9, 13),
      settings: const ExposureSettings(
        exposureTime: 1,
        gain: 100,
        offset: 10,
      ),
      filePath: '/tmp/frame.fits',
    );

PlateSolveResult _solved() => PlateSolveResult(
      success: true,
      ra: 0,
      dec: 0,
      pixelScale: 1.2,
      rotation: 0,
      fieldWidth: 1,
      fieldHeight: 1,
      solveTimeSecs: 2,
      cd11: 0,
      cd12: 0,
      cd21: 0,
      cd22: 0,
      sipAOrder: 0,
      sipBOrder: 0,
      sipACoeffs: Float64List(0),
      sipBCoeffs: Float64List(0),
      sipApOrder: 0,
      sipBpOrder: 0,
      sipApCoeffs: Float64List(0),
      sipBpCoeffs: Float64List(0),
    );

Future<(_RecordingPlateSolveService, _StagedMountNotifier)> _pumpRail(
  WidgetTester tester, {
  required MountState mount,
}) async {
  late _RecordingPlateSolveService service;
  late _StagedMountNotifier mountNotifier;

  await pumpAppScreen(
    tester,
    const SingleChildScrollView(
      child: SizedBox(width: 500, child: FramingTelescopeSection()),
    ),
    size: const Size(700, 1200),
    extraOverrides: [
      framingProvider.overrideWith(
        (ref) => _SeededFramingNotifier(ref, _framingState),
      ),
      framingFOVProvider.overrideWith(
        (ref) async =>
            const FramingEquipmentResult(status: EquipmentStatus.noProfile),
      ),
      currentImageProvider.overrideWith((ref) => _frame()),
      mountStateProvider.overrideWith(
        (ref) => mountNotifier = _StagedMountNotifier(ref, mount),
      ),
      plateSolverDetectionProvider.overrideWith(
        (ref) async => const PlateSolverDetection(
          astrometryPath: '/usr/bin/solve-field',
        ),
      ),
      plateSolverPreferenceProvider.overrideWith(
        (ref) async => const PlateSolverPreference(
          choice: PlateSolverChoice.astrometry,
        ),
      ),
      plateSolveServiceProvider.overrideWith(
        (ref) => service = _RecordingPlateSolveService(ref),
      ),
    ],
  );

  return (service, mountNotifier);
}

Future<void> _tapSolve(WidgetTester tester) async {
  await tester.tap(find.text('Solve latest camera frame').last);
  await tester.pump();
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('each click hints from the mount position as it is now',
      (tester) async {
    final (service, mount) = await _pumpRail(
      tester,
      mount: _mountAt(1.25, 10.0),
    );

    await _tapSolve(tester);
    expect(service.hints, hasLength(1));
    expect(service.hints.first.raHours, 1.25);
    expect(service.hints.first.decDegrees, 10.0);

    // The mount slews. The framing target has not changed, and that is the
    // point: the second solve must follow the telescope, not the target.
    mount.report(_mountAt(22.79, 58.13));
    await tester.pump();

    await _tapSolve(tester);
    expect(service.hints, hasLength(2));
    expect(service.hints.last.raHours, 22.79);
    expect(service.hints.last.decDegrees, 58.13);
    expect(
      service.hints.last.raHours,
      isNot(service.hints.first.raHours),
      reason: 'a cached hint would have produced the same solve twice',
    );
  });

  testWidgets('with no mount the target is the only guess there is',
      (tester) async {
    final (service, _) = await _pumpRail(
      tester,
      mount: const MountState(),
    );

    await _tapSolve(tester);
    expect(service.hints, hasLength(1));
    expect(service.hints.first.raHours, _target.raHours);
    expect(service.hints.first.decDegrees, _target.decDegrees);
  });

  /// A mount that is connected but has not reported a position yet has nothing
  /// to offer, and a fabricated 0h/0° hint sends the solver to a patch of sky
  /// the telescope is nowhere near.
  testWidgets('a connected mount with no position falls back to the target',
      (tester) async {
    final (service, _) = await _pumpRail(
      tester,
      mount: const MountState(
        connectionState: DeviceConnectionState.connected,
        deviceId: 'mount-1',
        isParked: false,
      ),
    );

    await _tapSolve(tester);
    expect(service.hints.first.raHours, _target.raHours);
    expect(service.hints.first.decDegrees, _target.decDegrees);
  });
}
