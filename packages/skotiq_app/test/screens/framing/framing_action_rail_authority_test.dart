import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/framing/widgets/framing_actions_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

class _SwitchableBackendNotifier extends BackendNotifier {
  _SwitchableBackendNotifier(super.ref, SkotiqBackend backend) {
    // ignore: invalid_use_of_protected_member
    state = backend;
  }

  void replaceBackend(SkotiqBackend backend) => state = backend;
}

class _SeededFramingNotifier extends FramingNotifier {
  _SeededFramingNotifier(super.ref, FramingState seed) {
    setSeed(seed);
  }

  void setSeed(FramingState seed) {
    // ignore: invalid_use_of_protected_member
    state = seed;
  }
}

class _ControlledPlateSolveService extends PlateSolveService {
  _ControlledPlateSolveService(super.ref);

  final result = Completer<PlateSolveResult>();
  int calls = 0;

  @override
  Future<PlateSolveResult> solveWithFallback({
    required String imagePath,
    double? hintRaHours,
    double? hintDecDegrees,
    double? searchRadiusDegrees,
    int? timeoutSeconds,
  }) {
    calls++;
    return result.future;
  }
}

const _target = FramingTarget(
  name: 'M42',
  raHours: 5.5,
  decDegrees: -5.4,
);

const _framingState = FramingState(target: _target);

CapturedImageData _frame() => CapturedImageData(
      width: 2,
      height: 2,
      displayData: Uint8List(16),
      histogram: List<int>.filled(256, 0),
      stats: const ImageStats(mean: 100, stdDev: 5, hfr: 1.5),
      capturedAt: DateTime.utc(2026, 7, 15),
      settings: const ExposureSettings(
        exposureTime: 1,
        gain: 100,
        offset: 10,
      ),
      filePath: '/tmp/frame.fits',
    );

PlateSolveResult _solved() => PlateSolveResult(
      success: true,
      ra: _target.raHours,
      dec: _target.decDegrees,
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('solve unlocks on host switch and discards old-host completion',
      (tester) async {
    final backendA = mockBackend();
    final backendB = mockBackend();
    late _SwitchableBackendNotifier backendNotifier;
    late _SeededFramingNotifier framingNotifier;
    late _ControlledPlateSolveService serviceA;
    late _ControlledPlateSolveService serviceB;

    await pumpAppScreen(
      tester,
      const SingleChildScrollView(
        child: SizedBox(width: 500, child: FramingTelescopeSection()),
      ),
      size: const Size(700, 1200),
      backend: backendA,
      extraOverrides: [
        backendProvider.overrideWith(
          (ref) => backendNotifier = _SwitchableBackendNotifier(ref, backendA),
        ),
        framingProvider.overrideWith(
          (ref) => framingNotifier = _SeededFramingNotifier(ref, _framingState),
        ),
        framingFOVProvider.overrideWith(
          (ref) async => const FramingEquipmentResult(
            status: EquipmentStatus.noProfile,
          ),
        ),
        currentImageProvider.overrideWith((ref) => _frame()),
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
        plateSolveServiceProvider.overrideWith((ref) {
          final backend = ref.watch(backendProvider);
          final service = _ControlledPlateSolveService(ref);
          if (identical(backend, backendA)) {
            serviceA = service;
          } else {
            serviceB = service;
          }
          return service;
        }),
      ],
    );

    await tester.tap(find.text('Solve latest camera frame').last);
    await tester.pump();
    expect(serviceA.calls, 1);

    backendNotifier.replaceBackend(backendB);
    await tester.pump();
    framingNotifier.setSeed(_framingState);
    await tester.pump();

    serviceA.result.complete(_solved());
    await tester.pump();
    expect(find.textContaining('Frame solved'), findsNothing);

    await tester.tap(find.text('Solve latest camera frame').last);
    await tester.pump();
    expect(serviceB.calls, 1);

    serviceB.result.complete(_solved());
    await tester.pump();
    // findsWidgets, not findsOneWidget: SkotiqBanner composes its title
    // and message into one Text.rich, and `textContaining` matches both the
    // rich text and the span inside it. The assertion that matters is that the
    // NEW host's result appears at all — the `findsNothing` above already
    // proved the old host's did not.
    expect(find.textContaining('Frame solved'), findsWidgets);
  });
}
