// The flat wizard after this morning's LRGB flats on a flat panel: every
// filter converged on half-well and took its 30 frames.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import 'shot_night.dart';

/// Panel exposure per filter, in seconds.
const _exposures = {'L': 0.42, 'R': 1.18, 'G': 1.06, 'B': 1.64};

/// The last flat: the optical train's vignetting on an even panel.
CapturedImageResult _lastFlat() {
  const width = 600;
  const height = 400;
  final random = math.Random(31);
  final rgba = Uint8List(width * height * 4);
  final histogram = List<int>.filled(256, 0);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final dx = (x - width * 0.51) / (width / 2);
      final dy = (y - height * 0.48) / (width / 2);
      final r2 = dx * dx + dy * dy;
      final value =
          (178 - 46 * r2 - 10 * r2 * r2 + (random.nextDouble() - 0.5) * 6)
              .round()
              .clamp(0, 255);
      final i = (y * width + x) * 4;
      rgba[i] = value;
      rgba[i + 1] = value;
      rgba[i + 2] = value;
      rgba[i + 3] = 255;
      histogram[value]++;
    }
  }
  return CapturedImageResult(
    width: width,
    height: height,
    displayData: rgba,
    histogram: histogram,
    stats: const ImageStatsResult(
      min: 29400,
      max: 35880,
      mean: 32790,
      median: 32810,
      stdDev: 1020,
      starCount: 0,
    ),
    exposureTime: _exposures['B']!,
    timestamp: _flatsAt.add(const Duration(minutes: 9)).toIso8601String(),
  );
}

DateTime get _flatsAt => ShotNight.at(-1, 6, 12);

class _Flats extends FlatWizardNotifier {
  _Flats(super.ref);

  /// The batch ends: every LRGB filter converged and took its frames.
  void finishBatch() {
    final filters = _exposures.keys.toList();
    // ignore: invalid_use_of_protected_member
    state = FlatWizardState(
      mode: FlatWizardMode.batch,
      globalSettings: const FlatWizardGlobalSettings(
        histogramTarget: 50,
        tolerancePercent: 8,
        minExposure: 0.01,
        maxExposure: 10,
        frameCount: 30,
        gain: 100,
        binning: 1,
        savePath: 'D:\\Astro\\Skotiq\\Flats',
      ),
      filterSettings: [
        for (final (i, f) in filters.indexed)
          FlatFilterSettings(
            filterName: f,
            filterPosition: ShotNight.filters.indexOf(f),
            gainOverride: ShotNight.gain,
            offsetOverride: ShotNight.offset,
            calibratedExposure: _exposures[f],
            capturedCount: 30,
            currentAdu: 32768 + (i * 137 % 300) - 150,
            status: FilterCalibrationStatus.complete,
          ),
        // The narrowband filters were not in this batch.
        for (final f in const ['Ha', 'OIII', 'SII'])
          FlatFilterSettings(
            filterName: f,
            filterPosition: ShotNight.filters.indexOf(f),
            enabled: false,
          ),
      ],
      currentFilterIndex: filters.length - 1,
      currentFrameIndex: 30,
      aduHistory: [
        // The last filter's calibration: four tries converging on 32 768.
        for (final (i, (exposure, adu)) in const [
          (1.0, 20140.0),
          (1.62, 32510.0),
          (1.65, 33090.0),
          (1.64, 32810.0),
        ].indexed)
          AduMeasurement(
            exposure: exposure,
            adu: adu,
            timestamp: _flatsAt.add(Duration(minutes: 8, seconds: 6 * i)),
          ),
      ],
      lastImageData: _lastFlat(),
      statusMessage: '120 flats in L, R, G and B',
    );
  }
}

List<Override> flatWizardOverrides() => [
      flatWizardProvider.overrideWith((ref) => _Flats(ref)),
    ];

/// Ends the batch once the screen has loaded the wheel's filters, as a run
/// started from the opened screen would.
Future<void> finishFlatBatch(
  WidgetTester tester,
  ProviderContainer container,
) async =>
    (container.read(flatWizardProvider.notifier) as _Flats).finishBatch();
