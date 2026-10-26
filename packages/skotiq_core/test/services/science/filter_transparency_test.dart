import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/services/science/filter_transparency.dart';

/// Per-frame zero points of the 2026-10-24 and 2026-10-25 NGC 891 nights
/// (L, R, G, B interleaved, 120 s), fitted against APASS V by the science
/// pipeline with the catalog projection fixed, with each frame's airmass.
/// 10-25 was clear all night; on 10-24 haze cleared early in the night.
List<FramePhotometricCalibration> _night(String date) {
  final lines = File(
    'test/fixtures/science/ngc891_${date}_zero_points.csv',
  ).readAsLinesSync().skip(1).where((l) => l.trim().isNotEmpty);
  return [
    for (final (i, line) in lines.indexed)
      () {
        final c = line.split(',');
        return FramePhotometricCalibration(
          capturedImageId: i + 1,
          sessionId: 1,
          timestamp: DateTime.parse(c[0]),
          airmass: double.parse(c[2]),
          isCalibrated: true,
          zeroPoint: double.parse(c[3]),
          calibrationRms: double.parse(c[4]),
          solverId: 'astap',
          filter: c[1],
          photometricBand: 'V',
        );
      }(),
  ];
}

/// Run the estimator the way the pipeline does: once per frame, over every
/// calibration recorded up to and including that frame.
List<TransparencySample?> _replay(List<FramePhotometricCalibration> night) => [
  for (var i = 0; i < night.length; i++)
    estimateFilterTransparency(
      night.sublist(0, i + 1),
      const TransparencyOptions(),
    ),
];

void main() {
  test('a clear LRGB night gets a sample on nearly every frame, near 100%', () {
    final night = _night('2026-10-25');
    final samples = _replay(night);
    final produced = samples.whereType<TransparencySample>().toList();
    // Only the first three frames of each filter have too little history.
    expect(produced.length, greaterThanOrEqualTo(night.length - 12));
    final clear = produced.where((s) => s.transparencyPercent >= 85).length;
    expect(clear / produced.length, greaterThan(0.9));
    for (final s in produced) {
      expect(s.filter, isNotNull);
    }
  });

  test('extinction is measured per filter and ordered B > G > R', () {
    final night = _night('2026-10-25');
    final samples = _replay(night);
    double lastK(String filter) {
      final s = samples.lastWhere(
        (s) => s != null && s.filter == filter && s.extinctionFromAirmassFit,
      )!;
      return s.extinctionCoefficient;
    }

    final kB = lastK('B'), kG = lastK('G'), kR = lastK('R');
    expect(kB, greaterThan(kG));
    expect(kG, greaterThan(kR));
    for (final k in [kB, kG, kR]) {
      expect(k, inInclusiveRange(0.05, 0.4));
    }
  });

  test('a frame is never compared with another filter', () {
    // The first B frame after three L frames: comparing B's zero point with
    // L's reported a clear sky as 48% "Poor".
    final night = _night('2026-10-25');
    final firstFour = night.take(4).toList();
    expect(firstFour.map((c) => c.filter).toSet().length, 4);
    expect(
      estimateFilterTransparency(firstFour, const TransparencyOptions()),
      isNull,
    );
  });

  test('without enough airmass range no extinction is reported, and the '
      'note says so', () {
    final night = _night(
      '2026-10-25',
    ).where((c) => c.filter == 'G').take(6).toList();
    final sample = estimateFilterTransparency(
      night,
      const TransparencyOptions(),
    )!;
    expect(sample.extinctionFromAirmassFit, isFalse);
    expect(sample.extinctionCoefficient, 0);
    expect(sample.note, contains('Extinction not measured'));
    expect(sample.transparencyPercent, greaterThan(90));
  });

  test('a changing sky is not reported as extinction', () {
    final samples = _replay(_night('2026-10-24'));
    for (final s in samples.whereType<TransparencySample>()) {
      if (s.extinctionFromAirmassFit) {
        expect(s.extinctionCoefficient, lessThanOrEqualTo(0.8));
      }
    }
  });
}
