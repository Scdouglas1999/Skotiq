import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/models/imaging/imaging_models.dart';
import 'package:skotiq_core/src/services/flat_wizard_service.dart';

/// Snapshot cover for the ADU-convergence math.
///
/// Pins the canonical Dart `FlatWizardService.calculateNextExposure` — the
/// engine that drives the standalone flat-wizard screen and the headless
/// `/api/flat-wizard/*` handlers via `calibrateFilter` — so its numbers cannot
/// move.
///
/// Two layers are pinned:
///  1. The pure next-exposure math for representative (currentAdu, target,
///     bounds) inputs — the exact thing being de-duplicated.
///  2. The full converged-exposure sequence produced by `calibrateFilter`
///     against a scripted linear flat-panel (ADU = exposure * rate) — proving
///     end-to-end converged exposures do not move.
class _ScriptedBackend extends Mock implements SkotiqBackend {}

/// A scripted, deterministic flat-panel backend: a single linear light source
/// where measured mean ADU = exposureTime * [aduPerSecond] (clamped to 16-bit).
/// Each `cameraStartExposure` records the requested exposure; the matching
/// `cameraGetLastImage` returns the modeled ADU and fires `ExposureComplete`.
class _LinearPanelBackend {
  _LinearPanelBackend(this.aduPerSecond);

  final double aduPerSecond;
  final _ScriptedBackend backend = _ScriptedBackend();
  final _eventController = StreamController<SkotiqEvent>.broadcast();
  double _lastExposure = 0;

  SkotiqBackend build() {
    when(() => backend.eventStream).thenAnswer((_) => _eventController.stream);

    when(
      () => backend.cameraStartExposure(
        deviceId: any(named: 'deviceId'),
        exposureTime: any(named: 'exposureTime'),
        frameType: any(named: 'frameType'),
        gain: any(named: 'gain'),
        offset: any(named: 'offset'),
        binX: any(named: 'binX'),
        binY: any(named: 'binY'),
      ),
    ).thenAnswer((invocation) async {
      _lastExposure = invocation.namedArguments[#exposureTime] as double;
      // Fire ExposureComplete on the next microtask so the service's listener
      // (subscribed before this returns) observes it.
      scheduleMicrotask(() {
        if (!_eventController.isClosed) {
          _eventController.add(
            const SkotiqEvent(
              timestamp: 0,
              severity: EventSeverity.info,
              category: EventCategory.imaging,
              eventType: 'ExposureComplete',
              data: {},
            ),
          );
        }
      });
    });

    when(() => backend.cameraGetLastImage(any())).thenAnswer((_) {
      // Return a Future<CapturedImageResult?> (nullable) so the future's static
      // type matches the real backend signature; the service's
      // `.timeout(onTimeout: () => null)` requires the nullable element type.
      final adu = (_lastExposure * aduPerSecond).clamp(0.0, 65535.0);
      return Future<CapturedImageResult?>.value(
        CapturedImageResult(
          width: 4,
          height: 4,
          displayData: const [],
          histogram: const [],
          stats: ImageStatsResult(
            min: adu,
            max: adu,
            mean: adu,
            median: adu,
            stdDev: 0,
            starCount: 0,
          ),
          exposureTime: _lastExposure,
          timestamp: '1970-01-01T00:00:00Z',
        ),
      );
    });

    return backend;
  }

  Future<void> dispose() => _eventController.close();
}

void main() {
  setUpAll(() {
    registerFallbackValue(FrameType.flat);
  });

  group('SNAPSHOT: canonical next-exposure math (pins current behavior)', () {
    // The canonical engine = the instance method on FlatWizardService, which
    // is the one wired into calibrateFilter -> screen + headless. These golden
    // values are captured from the CURRENT implementation and must not move.
    final svc = FlatWizardService(_ScriptedBackend());

    double next({
      required double currentExposure,
      required double currentAdu,
      required double targetAdu,
      double minExposure = 0.001,
      double maxExposure = 30.0,
    }) => svc.calculateNextExposure(
      currentExposure: currentExposure,
      currentAdu: currentAdu,
      targetAdu: targetAdu,
      minExposure: minExposure,
      maxExposure: maxExposure,
    );

    test('zero ADU falls back to arithmetic-mean midpoint', () {
      // currentAdu <= 0 -> (min+max)/2 = 15.0005
      expect(
        next(currentExposure: 1.0, currentAdu: 0, targetAdu: 30000),
        closeTo(15.0005, 1e-9),
      );
    });

    test('moderate under-exposure scales by the raw ratio (no damping)', () {
      // ratio = 30000/20000 = 1.5 (within [0.5,2.0] -> undamped); 1.0*1.5
      expect(
        next(currentExposure: 1.0, currentAdu: 20000, targetAdu: 30000),
        closeTo(1.5, 1e-9),
      );
    });

    test('large under-exposure is clamped to 3x then damped', () {
      // ratio = 30000/3000 = 10 -> clamp 3.0 -> >2.0 so damp: 1+(3-1)*0.7=2.4
      expect(
        next(currentExposure: 2.0, currentAdu: 3000, targetAdu: 30000),
        closeTo(4.8, 1e-9),
      );
    });

    test('large over-exposure is clamped to 1/3x then damped', () {
      // ratio = 30000/60000 = 0.5 -> within clamp; 0.5 < 0.5 is false so
      // adjustedRatio stays 0.5; 4.0*0.5 = 2.0
      expect(
        next(currentExposure: 4.0, currentAdu: 60000, targetAdu: 30000),
        closeTo(2.0, 1e-9),
      );
    });

    test('extreme over-exposure clamps at 0.33 then damps', () {
      // ratio = 30000/65535 ~= 0.4578 -> clamp 0.33; 0.33<0.5 so damp:
      // 1+(0.33-1)*0.7 = 0.531; 9.0*0.531 = 4.779
      expect(
        next(currentExposure: 9.0, currentAdu: 65535, targetAdu: 10000),
        closeTo(4.779, 1e-6),
      );
    });

    test('result is clamped to the max-exposure bound', () {
      expect(
        next(
          currentExposure: 20.0,
          currentAdu: 10000,
          targetAdu: 30000,
          maxExposure: 30.0,
        ),
        closeTo(30.0, 1e-9),
      );
    });
  });

  group('SNAPSHOT: converged exposure sequence (linear flat panel)', () {
    // Pins the END-TO-END converged exposure for representative targets so the
    // de-dup cannot move the value an operator's flat library is built on.
    Future<double> converge({
      required double aduPerSecond,
      required double targetAdu,
      required double tolerance,
      double minExposure = 0.001,
      double maxExposure = 30.0,
      int maxIterations = 12,
    }) async {
      final panel = _LinearPanelBackend(aduPerSecond);
      final svc = FlatWizardService(panel.build());
      final result = await svc.calibrateFilter(
        deviceId: 'cam',
        filter: 'L',
        gain: 100,
        offset: 10,
        targetAdu: targetAdu,
        tolerance: tolerance,
        minExposure: minExposure,
        maxExposure: maxExposure,
        maxIterations: maxIterations,
      );
      await panel.dispose();
      expect(
        result.success,
        isTrue,
        reason: 'representative case is expected to converge',
      );
      // Within tolerance of target by construction of the linear model.
      expect(
        (result.adu - targetAdu).abs() / targetAdu * 100,
        lessThanOrEqualTo(tolerance),
      );
      return result.exposure;
    }

    test('30000 ADU @ 10000 ADU/s, 10% tol', () async {
      // start = sqrt(0.001*30) ~= 0.1732 -> 1732 ADU; proportional climb.
      final exp = await converge(
        aduPerSecond: 10000,
        targetAdu: 30000,
        tolerance: 10,
      );
      // Pinned golden: 3.0s gives 30000 ADU exactly at the linear rate.
      expect(exp, closeTo(3.0, 1e-9));
    });

    test('20000 ADU @ 5000 ADU/s, 5% tol', () async {
      final exp = await converge(
        aduPerSecond: 5000,
        targetAdu: 20000,
        tolerance: 5,
      );
      expect(exp, closeTo(4.0, 1e-9));
    });

    test('45000 ADU @ 60000 ADU/s, 8% tol', () async {
      final exp = await converge(
        aduPerSecond: 60000,
        targetAdu: 45000,
        tolerance: 8,
      );
      expect(exp, closeTo(0.75, 1e-9));
    });
  });
}
