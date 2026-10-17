import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' show PlateSolveResult;

import 'package:skotiq_core/src/models/annotation_data.dart';
import 'package:skotiq_core/src/models/backend/device_types.dart';
import 'package:skotiq_core/src/models/imaging/imaging_models.dart';
import 'package:skotiq_core/src/models/plate_solver.dart';
import 'package:skotiq_core/src/providers/auto_stretch_provider.dart';
import 'package:skotiq_core/src/providers/equipment_provider.dart';
import 'package:skotiq_core/src/providers/first_light_provider.dart';
import 'package:skotiq_core/src/services/annotation_service.dart'
    show currentAnnotationProvider;
import 'package:skotiq_core/src/services/first_light/first_light_orchestrator.dart';
import 'package:skotiq_core/src/services/imaging_service.dart';
import 'package:skotiq_core/src/services/plate_solve_service.dart';

// Fakes

/// Imaging service whose [captureImage] returns a caller-supplied frame, or
/// throws a caller-supplied error, so each test can drive the exposure stage.
class _FakeImagingService extends ImagingService {
  _FakeImagingService(super.ref, {this.result, this.error});

  final CapturedImageData? result;
  final Object? error;

  /// Captures the [ExposureSettings] the orchestrator passed, so tests can
  /// assert it pinned the requested exposure length and forced a light frame.
  ExposureSettings? lastSettings;

  @override
  Future<CapturedImageData?> captureImage({
    required ExposureSettings settings,
    String? targetName,
    int? frameNumber,
    String? producingNodeId,
    String? producingRunId,
  }) async {
    lastSettings = settings;
    if (error != null) {
      throw error!;
    }
    return result;
  }
}

/// Plate-solve service with a scripted detection + solve outcome.
class _FakePlateSolveService extends PlateSolveService {
  _FakePlateSolveService(
    super.ref, {
    required this.detection,
    this.preference = const PlateSolverPreference(),
    this.solveResult,
    this.solveError,
  });

  final PlateSolverDetection detection;
  final PlateSolverPreference preference;
  final PlateSolveResult? solveResult;
  final Object? solveError;

  bool solveCalled = false;

  @override
  Future<PlateSolverDetection> detect() async => detection;

  @override
  Future<PlateSolverPreference> getConfig() async => preference;

  @override
  Future<PlateSolveResult> solveWithFallback({
    required String imagePath,
    double? hintRaHours,
    double? hintDecDegrees,
    double? searchRadiusDegrees,
    int? timeoutSeconds = 60,
  }) async {
    solveCalled = true;
    if (solveError != null) {
      throw solveError!;
    }
    return solveResult!;
  }
}

// Builders

CapturedImageData _makeCaptured({
  String? filePath = '/tmp/first_light.fits',
  int width = 64,
  int height = 48,
}) {
  return CapturedImageData(
    width: width,
    height: height,
    displayData: Uint8List(width * height * 4),
    histogram: List<int>.filled(256, 0),
    stats: const ImageStats(
      min: 0,
      max: 65535,
      mean: 1000,
      median: 900,
      stdDev: 50,
      hfr: 2.1,
      starCount: 42,
    ),
    capturedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
    settings: const ExposureSettings(exposureTime: 10, gain: 100, offset: 50),
    filePath: filePath,
  );
}

PlateSolveResult _makeSolve({bool success = true, String? error}) {
  return PlateSolveResult(
    success: success,
    ra: 5.5,
    dec: 23.4,
    pixelScale: 1.8,
    rotation: 12.0,
    fieldWidth: 1.2,
    fieldHeight: 0.9,
    solveTimeSecs: 3.2,
    error: error,
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
}

const _readyDetection = PlateSolverDetection(
  astapPath: '/usr/bin/astap',
  catalogPath: '/usr/share/astap/h17',
);

const _notReadyDetection = PlateSolverDetection();

/// astrometry.net is installed but ASTAP is not. `astapReady` is false here
/// (no ASTAP binary/catalog), but `hasAnySolver` is true — `solveWithFallback`
/// can still solve via astrometry.net, so first light MUST proceed to solve.
const _astrometryOnlyDetection = PlateSolverDetection(
  astrometryPath: '/usr/bin/solve-field',
);

/// Builds a container wiring the orchestrator's collaborators to the supplied
/// fakes. [cameraConnected] toggles the camera readiness gate.
ProviderContainer _container({
  required bool cameraConnected,
  required _FakeImagingService Function(Ref) imaging,
  required _FakePlateSolveService Function(Ref) plateSolve,
  Uint8List? Function()? stretch,
  Object? stretchError,
  FirstLightAnnotator? annotator,
}) {
  final container = ProviderContainer(
    overrides: [
      imagingServiceProvider.overrideWith(imaging),
      plateSolveServiceProvider.overrideWith(plateSolve),
      stretchedImageProvider.overrideWith((ref) async {
        if (stretchError != null) {
          throw stretchError;
        }
        return stretch?.call() ?? Uint8List(0);
      }),
      if (annotator != null)
        firstLightAnnotatorProvider.overrideWithValue(annotator),
    ],
  );
  addTearDown(container.dispose);

  if (cameraConnected) {
    final cam = container.read(cameraStateProvider.notifier);
    cam.setConnecting('cam-1', 'Test Camera');
    cam.setConnected();
  }
  return container;
}

/// Awaits the controller until [predicate] holds on its state, failing the
/// test with a clear message on timeout instead of hanging or guessing a
/// fixed delay (condition-based waiting).
Future<FirstLightState> _waitForPhase(
  ProviderContainer container,
  bool Function(FirstLightState) predicate, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final completer = Completer<FirstLightState>();

  void check(FirstLightState state) {
    if (!completer.isCompleted && predicate(state)) {
      completer.complete(state);
    }
  }

  final sub = container.listen<FirstLightState>(
    firstLightControllerProvider,
    (_, next) => check(next),
    fireImmediately: true,
  );

  try {
    return await completer.future.timeout(
      timeout,
      onTimeout: () => throw TimeoutException(
        'first-light state never satisfied predicate; last state was '
        '${container.read(firstLightControllerProvider)}',
        timeout,
      ),
    );
  } finally {
    sub.close();
  }
}

void main() {
  group('FirstLightOrchestrator', () {
    test('happy path: idle -> exposing -> stretching -> solving -> annotating '
        '-> success with a solve result', () async {
      final phases = <FirstLightPhase>[];

      final container = _container(
        cameraConnected: true,
        imaging: (ref) => _FakeImagingService(ref, result: _makeCaptured()),
        plateSolve: (ref) => _FakePlateSolveService(
          ref,
          detection: _readyDetection,
          solveResult: _makeSolve(),
        ),
        annotator: ({required imagePath, required plateSolve}) async =>
            ImageAnnotation(
              imagePath: imagePath,
              timestamp: DateTime.fromMillisecondsSinceEpoch(1700000001000),
              plateSolve: plateSolve,
              objects: const [],
            ),
      );

      // Record the ordered phase transitions to prove the full progression.
      final sub = container.listen<FirstLightState>(
        firstLightControllerProvider,
        (_, next) => phases.add(next.phase),
        fireImmediately: true,
      );
      addTearDown(sub.close);

      expect(
        container.read(firstLightControllerProvider).phase,
        FirstLightPhase.idle,
      );

      final controller = container.read(firstLightControllerProvider.notifier);
      final runFuture = controller.run(exposureSeconds: 12);

      final terminal = await _waitForPhase(container, (s) => s.isTerminal);
      await runFuture;

      expect(terminal.phase, FirstLightPhase.success);
      expect(terminal.exposureSeconds, 12);
      expect(terminal.stretched, isTrue);
      expect(terminal.annotated, isTrue);
      expect(terminal.errorMessage, isNull);
      expect(terminal.solveResult, isNotNull);
      expect(terminal.solveResult!.success, isTrue);
      expect(terminal.capturedImagePath, '/tmp/first_light.fits');
      expect(terminal.capturedImageId, '/tmp/first_light.fits');

      // Ordered progression through every happy-path stage.
      expect(
        phases,
        containsAllInOrder(<FirstLightPhase>[
          FirstLightPhase.idle,
          FirstLightPhase.exposing,
          FirstLightPhase.stretching,
          FirstLightPhase.solving,
          FirstLightPhase.annotating,
          FirstLightPhase.success,
        ]),
      );

      // The orchestrator published the captured frame + annotation so the
      // preview surfaces light up exactly like a manual snapshot.
      expect(container.read(currentImageProvider), isNotNull);
      expect(container.read(currentAnnotationProvider), isNotNull);

      // It pinned the requested exposure length and forced a light frame
      // rather than reusing whatever was last set.
      final imaging =
          container.read(imagingServiceProvider) as _FakeImagingService;
      expect(imaging.lastSettings?.exposureTime, 12);
      expect(imaging.lastSettings?.frameType, FrameType.light);
    });

    test('camera disconnected -> failed with an actionable message', () async {
      final container = _container(
        cameraConnected: false,
        imaging: (ref) => _FakeImagingService(ref, result: _makeCaptured()),
        plateSolve: (ref) => _FakePlateSolveService(
          ref,
          detection: _readyDetection,
          solveResult: _makeSolve(),
        ),
      );

      final controller = container.read(firstLightControllerProvider.notifier);
      await controller.run(exposureSeconds: 8);

      final state = container.read(firstLightControllerProvider);
      expect(state.phase, FirstLightPhase.failed);
      expect(state.errorMessage, isNotNull);
      expect(state.errorMessage, contains('No camera connected'));
      // No capture happened, so nothing downstream advanced.
      expect(state.capturedImagePath, isNull);
      expect(state.stretched, isFalse);
      expect(state.solveResult, isNull);
      expect(state.annotated, isFalse);
    });

    test('plate solver not ready -> success with null solveResult and the '
        'explanatory note (NOT failed)', () async {
      late final _FakePlateSolveService fakeSolver;
      final container = _container(
        cameraConnected: true,
        imaging: (ref) => _FakeImagingService(ref, result: _makeCaptured()),
        plateSolve: (ref) {
          fakeSolver = _FakePlateSolveService(
            ref,
            detection: _notReadyDetection,
          );
          return fakeSolver;
        },
      );

      final controller = container.read(firstLightControllerProvider.notifier);
      await controller.run(exposureSeconds: 6);

      final state = container.read(firstLightControllerProvider);
      expect(state.phase, FirstLightPhase.success);
      expect(state.errorMessage, isNull);
      expect(state.solveResult, isNull);
      expect(state.annotated, isFalse);
      expect(state.stretched, isTrue);
      expect(state.note, FirstLightOrchestrator.solverNotConfiguredNote);
      // The solver must NOT have been invoked when it isn't ready.
      expect(fakeSolver.solveCalled, isFalse);
    });

    test(
      'explicit unusable solver selection is not masked by another install',
      () async {
        late final _FakePlateSolveService fakeSolver;
        final container = _container(
          cameraConnected: true,
          imaging: (ref) => _FakeImagingService(ref, result: _makeCaptured()),
          plateSolve: (ref) {
            fakeSolver = _FakePlateSolveService(
              ref,
              detection: const PlateSolverDetection(
                astapPath: '/opt/astap/astap',
                astrometryPath: '/usr/bin/solve-field',
              ),
              preference: const PlateSolverPreference(
                choice: PlateSolverChoice.astap,
              ),
            );
            return fakeSolver;
          },
        );

        await container
            .read(firstLightControllerProvider.notifier)
            .run(exposureSeconds: 6);

        final state = container.read(firstLightControllerProvider);
        expect(state.phase, FirstLightPhase.success);
        expect(state.note, FirstLightOrchestrator.solverNotConfiguredNote);
        expect(fakeSolver.solveCalled, isFalse);
      },
    );

    test('astrometry.net-only setup in Auto mode still solves', () async {
      late final _FakePlateSolveService fakeSolver;
      final container = _container(
        cameraConnected: true,
        imaging: (ref) => _FakeImagingService(ref, result: _makeCaptured()),
        plateSolve: (ref) {
          fakeSolver = _FakePlateSolveService(
            ref,
            // astapReady == false, hasAnySolver == true.
            detection: _astrometryOnlyDetection,
            solveResult: _makeSolve(),
          );
          return fakeSolver;
        },
        annotator: ({required imagePath, required plateSolve}) async =>
            ImageAnnotation(
              imagePath: imagePath,
              timestamp: DateTime.fromMillisecondsSinceEpoch(1700000002000),
              plateSolve: plateSolve,
              objects: const [],
            ),
      );

      final controller = container.read(firstLightControllerProvider.notifier);
      await controller.run(exposureSeconds: 11);

      final state = container.read(firstLightControllerProvider);
      // The solve stage ran and the flow reached a real, labelled success —
      // NOT the "plate solver not configured" early-out.
      expect(fakeSolver.solveCalled, isTrue);
      expect(state.phase, FirstLightPhase.success);
      expect(state.solveResult, isNotNull);
      expect(state.solveResult!.success, isTrue);
      expect(state.annotated, isTrue);
      expect(state.note, isNull);
    });

    test('cameraDriverType is derived from the connected camera device id so '
        'the troubleshooter gets the right protocol', () async {
      final container = _container(
        cameraConnected: false,
        imaging: (ref) => _FakeImagingService(ref, result: _makeCaptured()),
        plateSolve: (ref) =>
            _FakePlateSolveService(ref, detection: _readyDetection),
      );

      // Connect a camera whose id carries an explicit protocol prefix.
      final cam = container.read(cameraStateProvider.notifier);
      cam.setConnecting('ascom:ASCOM.Simulator.Camera', 'Sim Camera');
      cam.setConnected();

      final controller = container.read(firstLightControllerProvider.notifier);
      await controller.run(exposureSeconds: 5);

      final state = container.read(firstLightControllerProvider);
      expect(state.cameraDriverType, DriverType.ascom);
    });

    test('driverTypeFromDeviceId maps every namespaced prefix', () {
      expect(
        driverTypeFromDeviceId('ascom:ASCOM.Foo.Camera'),
        DriverType.ascom,
      );
      expect(
        driverTypeFromDeviceId('alpaca:192.168.1.5:11111:0'),
        DriverType.alpaca,
      );
      expect(
        driverTypeFromDeviceId('indi:localhost:7624:ZWO CCD'),
        DriverType.indi,
      );
      expect(driverTypeFromDeviceId('native:zwo:0'), DriverType.native);
      expect(driverTypeFromDeviceId('simulator:cam'), DriverType.simulator);
      // Unknown / empty / null collapse to null (protocol unknown).
      expect(driverTypeFromDeviceId('mystery:thing'), isNull);
      expect(driverTypeFromDeviceId(''), isNull);
      expect(driverTypeFromDeviceId(null), isNull);
    });

    test('exposure error -> failed carrying the raw message', () async {
      final container = _container(
        cameraConnected: true,
        imaging: (ref) => _FakeImagingService(
          ref,
          error: Exception('camera read timeout: USB stall'),
        ),
        plateSolve: (ref) => _FakePlateSolveService(
          ref,
          detection: _readyDetection,
          solveResult: _makeSolve(),
        ),
      );

      final controller = container.read(firstLightControllerProvider.notifier);
      await controller.run(exposureSeconds: 5);

      final state = container.read(firstLightControllerProvider);
      expect(state.phase, FirstLightPhase.failed);
      // The raw underlying message is preserved (no swallowing / rewriting).
      expect(state.errorMessage, contains('camera read timeout: USB stall'));
      expect(state.solveResult, isNull);
    });

    test(
      'a thrown solver error surfaces as failed carrying the raw message',
      () async {
        final container = _container(
          cameraConnected: true,
          imaging: (ref) => _FakeImagingService(ref, result: _makeCaptured()),
          plateSolve: (ref) => _FakePlateSolveService(
            ref,
            detection: _readyDetection,
            solveError: Exception('ASTAP crashed: segfault'),
          ),
        );

        final controller = container.read(
          firstLightControllerProvider.notifier,
        );
        await controller.run(exposureSeconds: 7);

        final state = container.read(firstLightControllerProvider);
        expect(state.phase, FirstLightPhase.failed);
        expect(state.errorMessage, contains('ASTAP crashed: segfault'));
        expect(state.annotated, isFalse);
      },
    );

    test(
      'a failed solve (success=false) surfaces as failed, not faked success',
      () async {
        final container = _container(
          cameraConnected: true,
          imaging: (ref) => _FakeImagingService(ref, result: _makeCaptured()),
          plateSolve: (ref) => _FakePlateSolveService(
            ref,
            detection: _readyDetection,
            solveResult: _makeSolve(success: false, error: 'no stars matched'),
          ),
        );

        final controller = container.read(
          firstLightControllerProvider.notifier,
        );
        await controller.run(exposureSeconds: 9);

        final state = container.read(firstLightControllerProvider);
        expect(state.phase, FirstLightPhase.failed);
        expect(state.errorMessage, contains('no stars matched'));
        expect(state.annotated, isFalse);
      },
    );

    test('reset returns the controller to idle', () async {
      final container = _container(
        cameraConnected: false,
        imaging: (ref) => _FakeImagingService(ref, result: _makeCaptured()),
        plateSolve: (ref) =>
            _FakePlateSolveService(ref, detection: _readyDetection),
      );

      final controller = container.read(firstLightControllerProvider.notifier);
      await controller.run(exposureSeconds: 5);
      expect(
        container.read(firstLightControllerProvider).phase,
        FirstLightPhase.failed,
      );

      controller.reset();
      expect(
        container.read(firstLightControllerProvider),
        isA<FirstLightState>()
            .having((s) => s.phase, 'phase', FirstLightPhase.idle)
            .having((s) => s.errorMessage, 'errorMessage', isNull)
            .having((s) => s.solveResult, 'solveResult', isNull),
      );
    });

    test(
      'a non-positive exposure length is rejected as a programmer error',
      () async {
        final container = _container(
          cameraConnected: true,
          imaging: (ref) => _FakeImagingService(ref, result: _makeCaptured()),
          plateSolve: (ref) =>
              _FakePlateSolveService(ref, detection: _readyDetection),
        );

        final controller = container.read(
          firstLightControllerProvider.notifier,
        );
        expect(
          () => controller.run(exposureSeconds: 0),
          throwsA(isA<ArgumentError>()),
        );
      },
    );
  });
}
