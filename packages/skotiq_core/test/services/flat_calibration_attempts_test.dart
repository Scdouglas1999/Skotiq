// The owner's report: "Flat system is hard locked to 3 iterations for exposure
// calibration or it fails". Sky flats stopped after 3 test exposures, panel
// flats after 10, and the headless API after 10, whatever the settings said.
// Every path now uses one setting, "Exposure calibration attempts", default 20.
//
// Two ordinary skies need more than three tries from the 0.17 s geometric-mean
// start: a bright early-dusk sky that saturates the first frames, and a dim
// one whose bias pedestal makes the first frame read high per second. On the
// Linux simulator the Flat Wizard failed this way at 3 (2026-11-08).

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _Backend extends Mock implements SkotiqBackend {}

/// A sky whose mean ADU is a pedestal plus a rate, clipped at full scale.
class _Sky extends FlatWizardService {
  _Sky({
    required this.aduPerSecond,
    this.pedestal = 2000,
    super.defaultMaxIterations,
  }) : super(_Backend());

  final double aduPerSecond;
  final double pedestal;
  final List<double> exposures = [];

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
    final adu = (pedestal + aduPerSecond * exposureTime).clamp(0.0, 65535.0);
    return (adu: adu, outcome: null);
  }
}

Future<FlatResult> _skyFlat(_Sky sky, {int? maxIterations}) =>
    sky.calibrateFilterWithRateTracking(
      deviceId: 'cam',
      filter: 'L',
      targetAdu: 32768,
      tolerance: 5,
      minExposure: 0.001,
      maxExposure: 30,
      brightnessTracker: SkyBrightnessTracker(),
      maxIterations: maxIterations,
    );

void main() {
  test('the default is 20 attempts', () {
    expect(const AppSettingsState().flatCalibrationAttempts, 20);
    expect(FlatWizardService(_Backend()).defaultMaxIterations, 20);
  });

  for (final (name, rate) in [('dim', 1150.0), ('saturating', 3e6)]) {
    test('a $name sky that needs more than 3 tries now converges', () async {
      final sky = _Sky(aduPerSecond: rate);
      final result = await _skyFlat(sky);
      expect(result.success, isTrue, reason: result.errorMessage);
      expect(sky.exposures.length, greaterThan(3),
          reason: 'this sky would have failed at the old limit of 3');
    });
  }

  test('the setting is the limit, and the failure names it', () async {
    final sky = _Sky(aduPerSecond: 1150, defaultMaxIterations: 3);
    final result = await _skyFlat(sky);
    expect(result.success, isFalse);
    expect(sky.exposures, hasLength(3));
    expect(result.errorMessage, contains('Exposure calibration attempts'));
  });

  test('panel flats use the setting too', () async {
    final sky = _Sky(aduPerSecond: 1150, defaultMaxIterations: 2);
    final result = await sky.calibrateFilter(
      deviceId: 'cam',
      filter: 'L',
      targetAdu: 32768,
      tolerance: 5,
      minExposure: 0.001,
      maxExposure: 30,
    );
    expect(result.success, isFalse);
    expect(sky.exposures, hasLength(2));
    expect(result.errorMessage, contains('Exposure calibration attempts'));
  });

  test('a caller limit still wins over the setting', () async {
    final sky = _Sky(aduPerSecond: 1150);
    await _skyFlat(sky, maxIterations: 1);
    expect(sky.exposures, hasLength(1));
  });
}
