import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/services.dart';

class _Backend extends Mock implements SkotiqBackend {}

class _MeasuredFlats extends FlatWizardService {
  _MeasuredFlats(this.measure) : super(_Backend());

  final double Function(double exposure) measure;
  final exposures = <double>[];

  @override
  Future<({double? adu, FlatFrameCapture? outcome})> captureTestFrame({
    required String deviceId,
    required double exposureTime,
    int? gain,
    int? offset,
    String? filterName,
    int? filterPosition,
    String? filterWheelDeviceId,
    int binX = 1,
    int binY = 1,
    FlatCancelToken? cancelToken,
    Duration abortSettleTimeout = const Duration(seconds: 10),
    Duration? overallTimeout,
  }) async {
    exposures.add(exposureTime);
    return (adu: measure(exposureTime), outcome: null);
  }
}

void main() {
  const target = 40000.0;

  test(
    'a sub-millisecond nudge at 2 ms is taken, not treated as converged',
    () async {
      const exposure = 0.002;
      // 32000 / 40000 is 20% off, which is 1.5 times a 13.333...% tolerance,
      // and the proportional step from 0.002 is 0.0025.
      const tolerance = 20 / 1.5;
      final epsilon = math.max(1e-9, exposure * 1e-6);
      final service = _MeasuredFlats((seconds) {
        if ((seconds - exposure).abs() <= epsilon) return 32000;
        return target;
      });

      final result = await service.calibrateFilter(
        deviceId: 'camera',
        filter: 'R',
        targetAdu: target,
        tolerance: tolerance,
        minExposure: 0.001,
        maxExposure: 0.004,
      );

      expect(service.exposures.length, greaterThan(1));
      expect(
        (service.exposures[1] - service.exposures.first).abs(),
        greaterThan(epsilon),
      );
      expect(result.success, isTrue);
    },
  );

  test(
    'a clamped exposure outside tolerance is one unsuccessful result',
    () async {
      const exposure = 0.002;
      const tolerance = 10.0;
      final service = _MeasuredFlats((_) => target * 0.85);

      final result = await service.calibrateFilter(
        deviceId: 'camera',
        filter: 'R',
        targetAdu: target,
        tolerance: tolerance,
        minExposure: exposure,
        maxExposure: exposure,
        maxIterations: 4,
      );

      expect(service.exposures, [exposure]);
      expect(result.success, isFalse);
      expect(result.exposure, exposure);
      expect(result.errorMessage, isNotNull);
    },
  );

  test(
    'an exposure already inside tolerance succeeds before the stop check',
    () async {
      final service = _MeasuredFlats((_) => target);

      final result = await service.calibrateFilter(
        deviceId: 'camera',
        filter: 'R',
        targetAdu: target,
        tolerance: 10,
        minExposure: 0.001,
        maxExposure: 0.004,
      );

      expect(service.exposures, hasLength(1));
      expect(result.success, isTrue);
    },
  );
}
