// E2E test for the FlatWizardService.
//
// What this exercises end-to-end through the real `FlatWizardService`:
//   1. Multi-filter calibration via `calibrateMultipleFilters` for L, R, G.
//   2. Camera exposure with the user-configured gain/offset propagated.
//      FlatWizardService must not forward gain=0 and offset=0 over the
//      configured values; this test asserts the values that came in (100, 50)
//      are the values that reach the camera.
//   3. The exposure-completion event handshake — FlatWizardService subscribes
//      to `backend.eventStream` and waits for an `ExposureComplete` event
//      before reading the captured frame.
//   4. The proportional-adjustment loop until the simulated ADU converges to
//      the target within tolerance.
//   5. Filter-wheel selection via `captureTestFrame` (the lower-level entry
//      point the service exposes) — verifies the wheel-name path works.
//   6. Negative path: when the camera fails for one filter (returns null
//      image), that filter's result is non-converged with an actionable
//      error while the others complete normally.
//
// `FlatWizardService.calibrateMultipleFilters` does NOT call the filter wheel
// itself — by design the wheel move is the caller's responsibility (the UI
// screen handles it before calling). So we exercise the wheel path through
// `captureTestFrame`, which does take a `filterWheelDeviceId`.
//
// The backend here is a hand-rolled test double that extends `Mock` from
// `package:mocktail` so the 100+ unused `SkotiqBackend` methods are
// safely defaulted, but the methods we actually exercise are real
// implementations that simulate hardware behavior end-to-end.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/models/imaging/imaging_models.dart';
import 'package:skotiq_core/src/services/flat_wizard_service.dart';

void main() {
  group('FlatWizardService end-to-end through fake bridge', () {
    const cameraId = 'native:asi:0';
    const wheelId = 'native:zwo-efw:0';
    const filters = ['L', 'R', 'G'];

    test('3-filter run converges; gain/offset propagated to camera', () async {
      final backend = _FlatWizardTestBackend(
        // Linear synthetic ADU: at exposure = 1.0s the model returns exactly
        // 30000 ADU (== target). Below 1.0s the ADU is under target; above,
        // over. FlatWizardService's proportional loop should converge in a
        // few iterations from the geometric-midpoint starting exposure.
        //   adu(t) = 10000 + 20000 * t
        aduForExposure: (t) => 10000.0 + 20000.0 * t,
      );
      addTearDown(backend.disposeFake);

      final service = FlatWizardService(backend);

      final results = await service.calibrateMultipleFilters(
        deviceId: cameraId,
        filters: filters,
        gain: 100,
        offset: 50,
        targetAdu: 30000,
        tolerance: 5.0, // percent
        minExposure: 0.01,
        maxExposure: 10.0,
        maxIterations: 12,
      );

      // Per-filter convergence assertions
      expect(results, hasLength(3));
      for (final r in results) {
        expect(
          r.success,
          isTrue,
          reason:
              'Filter "${r.filter}" did not converge: '
              'adu=${r.adu}, exposure=${r.exposure}, '
              'iterations=${r.iterations}, error=${r.errorMessage}',
        );
        // Within 5% of target ADU per the configured tolerance.
        final pctError = ((r.adu - 30000).abs() / 30000) * 100;
        expect(
          pctError,
          lessThanOrEqualTo(5.0),
          reason: 'Filter "${r.filter}" ADU outside tolerance',
        );
      }

      // Gain/offset must propagate, NOT default to 0
      // Every cameraStartExposure call recorded must use gain=100, offset=50.
      expect(backend.exposureCalls, isNotEmpty);
      for (final call in backend.exposureCalls) {
        expect(
          call.gain,
          equals(100),
          reason: 'gain was not forwarded to camera',
        );
        expect(
          call.offset,
          equals(50),
          reason: 'offset was not forwarded to camera',
        );
        expect(call.frameType, equals(FrameType.flat));
        expect(call.deviceId, equals(cameraId));
      }
    });

    test('captureTestFrame drives the filter wheel by name', () async {
      // FlatWizardService.calibrateMultipleFilters does NOT change filters
      // itself (that is the caller's responsibility — see flat_wizard_screen.
      // dart's `_moveFilterWheel`). The wheel-by-name path is exposed via
      // `captureTestFrame(filterWheelDeviceId: ...)`. Verify it works.
      final backend = _FlatWizardTestBackend(aduForExposure: (t) => 25000.0);
      addTearDown(backend.disposeFake);

      final service = FlatWizardService(backend);

      final adu = (await service.captureTestFrame(
        deviceId: cameraId,
        exposureTime: 0.5,
        gain: 100,
        offset: 50,
        filterName: 'L',
        filterWheelDeviceId: wheelId,
      )).adu;

      expect(adu, isNotNull);
      expect(adu, closeTo(25000.0, 0.01));
      expect(backend.filterChangesByName, equals(['L']));

      // Propagation also holds on the captureTestFrame entry point.
      expect(backend.exposureCalls.single.gain, equals(100));
      expect(backend.exposureCalls.single.offset, equals(50));
    });

    test('camera failure on R isolates that filter; L and G converge', () async {
      // FlatWizardService.calibrateFilter reads back the last image via
      // `cameraGetLastImage`. If that returns null, the service surfaces a
      // non-converged `FlatResult` with `errorMessage: "Failed to capture
      // test frame"`. This is the real failure mode the production code
      // exposes — we drive it per-filter by varying the backend's
      // `failCameraForFilter` between iterations.
      //
      // Why not via `calibrateMultipleFilters` end-to-end: the multi-filter
      // entry point does NOT call the filter wheel (the UI screen is
      // responsible for that — see `flat_wizard_screen.dart::_moveFilterWheel`)
      // so the backend has no per-filter signal to know when to fail. The
      // service contract is "iterate single-filter calibrations"; driving
      // those directly preserves the real code path for each filter while
      // letting us configure the camera failure per-iteration.
      final backend = _FlatWizardTestBackend(
        aduForExposure: (t) => 10000.0 + 20000.0 * t,
      );
      addTearDown(backend.disposeFake);

      final service = FlatWizardService(backend);
      final results = <FlatResult>[];

      for (final filter in filters) {
        backend.failCameraForNextCalls = filter == 'R';
        final r = await service.calibrateFilter(
          deviceId: cameraId,
          filter: filter,
          gain: 100,
          offset: 50,
          targetAdu: 30000,
          tolerance: 5.0,
          minExposure: 0.01,
          maxExposure: 10.0,
          maxIterations: 12,
        );
        results.add(r);
      }

      expect(results, hasLength(3));

      final byFilter = {for (final r in results) r.filter: r};

      expect(byFilter['L']!.success, isTrue, reason: 'L should converge');
      expect(byFilter['G']!.success, isTrue, reason: 'G should converge');

      expect(
        byFilter['R']!.success,
        isFalse,
        reason: 'R should have failed when the camera returned no image',
      );
      expect(byFilter['R']!.errorMessage, isNotNull);
      expect(
        byFilter['R']!.errorMessage!.toLowerCase(),
        contains('failed to capture test frame'),
      );
    });
  });
}

/// Records a single call to `cameraStartExposure`.
class _ExposureCall {
  final String deviceId;
  final double exposureTime;
  final FrameType frameType;
  final int? gain;
  final int? offset;
  final int binX;
  final int binY;

  const _ExposureCall({
    required this.deviceId,
    required this.exposureTime,
    required this.frameType,
    required this.gain,
    required this.offset,
    required this.binX,
    required this.binY,
  });
}

/// Test backend that simulates a camera + filter wheel for the flat-wizard
/// calibration loop.
///
/// Extends mocktail's `Mock` so the 100+ unused `SkotiqBackend` methods
/// noSuchMethod-default. The methods we actually exercise are real
/// implementations layered on top:
///   - `eventStream` is a broadcast controller. After every exposure we emit
///     `ExposureComplete` so `FlatWizardService`'s completer wakes up.
///   - `cameraStartExposure` records its arguments and, on a microtask,
///     fires `ExposureComplete`.
///   - `cameraGetLastImage` returns a `CapturedImageResult` whose `mean`
///     equals the ADU computed by `aduForExposure`. If the active filter
///     matches `failCameraForFilter`, it returns null instead (simulating
///     a download failure).
///   - `filterWheelSetByName` records the call and tracks the active filter
///     so `cameraGetLastImage` can decide whether to fail.
class _FlatWizardTestBackend extends Mock implements SkotiqBackend {
  _FlatWizardTestBackend({required this.aduForExposure});

  final double Function(double exposureTime) aduForExposure;

  /// When true, the very next `cameraGetLastImage` call returns null,
  /// simulating a download/decode failure. The test sets this before
  /// `calibrateFilter` to inject a per-filter failure.
  bool failCameraForNextCalls = false;

  final StreamController<SkotiqEvent> _events =
      StreamController<SkotiqEvent>.broadcast();
  final List<_ExposureCall> exposureCalls = [];
  final List<String> filterChangesByName = [];

  double? _lastExposureTime;
  int _eventCounter = 0;

  void disposeFake() {
    if (!_events.isClosed) {
      _events.close();
    }
  }

  @override
  Stream<SkotiqEvent> get eventStream => _events.stream;

  @override
  Stream<Map<String, dynamic>> get polarAlignmentEvents => const Stream.empty();

  @override
  Future<void> filterWheelSetByName(String deviceId, String name) async {
    filterChangesByName.add(name);
  }

  @override
  Future<void> cameraStartExposure({
    required String deviceId,
    required double exposureTime,
    required FrameType frameType,
    int? gain,
    int? offset,
    int binX = 1,
    int binY = 1,
    int? x,
    int? y,
    int? width,
    int? height,
  }) async {
    exposureCalls.add(
      _ExposureCall(
        deviceId: deviceId,
        exposureTime: exposureTime,
        frameType: frameType,
        gain: gain,
        offset: offset,
        binX: binX,
        binY: binY,
      ),
    );
    _lastExposureTime = exposureTime;

    // Emit ExposureComplete on the next microtask. FlatWizardService
    // subscribes BEFORE awaiting cameraStartExposure, then awaits the event;
    // emitting from a microtask keeps the test fast (no real delay).
    scheduleMicrotask(() {
      if (_events.isClosed) return;
      _eventCounter++;
      _events.add(
        SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch + _eventCounter,
          severity: EventSeverity.info,
          category: EventCategory.imaging,
          eventType: 'ExposureComplete',
          data: <String, dynamic>{
            'deviceId': deviceId,
            'exposureTime': exposureTime,
          },
        ),
      );
    });
  }

  @override
  Future<CapturedImageResult?> cameraGetLastImage(String deviceId) async {
    final t = _lastExposureTime;
    if (t == null) return null;
    if (failCameraForNextCalls) {
      // Simulate a camera download failure. The service surfaces this as a
      // non-converged FlatResult with `errorMessage: "Failed to capture test
      // frame"`.
      return null;
    }
    final adu = aduForExposure(t);
    return CapturedImageResult(
      width: 8,
      height: 8,
      displayData: List<int>.filled(8 * 8 * 4, 128),
      histogram: List<int>.filled(256, 1),
      stats: ImageStatsResult(
        min: adu * 0.9,
        max: adu * 1.1,
        mean: adu,
        median: adu,
        stdDev: adu * 0.05,
        starCount: 0,
      ),
      exposureTime: t,
      timestamp: DateTime.now().toUtc().toIso8601String(),
    );
  }
}
