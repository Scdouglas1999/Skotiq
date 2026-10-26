import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  test('sky noise over read noise, from the measured noise in ADU', () {
    // 20 e- total noise with 2 e- read noise: sqrt(400 - 4) / 2.
    expect(
      skyToReadNoiseRatio(noiseAdu: 100, gainEPerAdu: 0.2, readNoiseE: 2),
      closeTo(9.95, 0.01),
    );
  });

  test('the ratio rises with a brighter sky, so it never flags the darkest '
      'frames as the worst', () {
    final dark = skyToReadNoiseRatio(
      noiseAdu: 169,
      gainEPerAdu: 0.123,
      readNoiseE: 2,
    )!;
    final bright = skyToReadNoiseRatio(
      noiseAdu: 276,
      gainEPerAdu: 0.123,
      readNoiseE: 2,
    )!;
    expect(bright, greaterThan(dark));
  });

  test('unknown camera values give no ratio', () {
    expect(
      skyToReadNoiseRatio(noiseAdu: 100, gainEPerAdu: null, readNoiseE: 2),
      isNull,
    );
    expect(
      skyToReadNoiseRatio(noiseAdu: 100, gainEPerAdu: 0.2, readNoiseE: 0),
      isNull,
    );
  });

  test('noise at or below the read noise reads 0', () {
    expect(
      skyToReadNoiseRatio(noiseAdu: 5, gainEPerAdu: 0.2, readNoiseE: 2),
      0.0,
    );
  });

  test('read-noise penalty', () {
    expect(readNoisePenalty(3), closeTo(0.054, 0.001));
    expect(readNoisePenalty(1), closeTo(0.414, 0.001));
  });
}
