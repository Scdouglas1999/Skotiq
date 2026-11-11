import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  group('SkotiqChartColors', () {
    test('provides six desaturated series colors', () {
      expect(SkotiqChartColors.series, hasLength(6));
    });

    test('gradient presets preserve stop count', () {
      expect(SkotiqChartColors.psfGradient, hasLength(3));
      expect(SkotiqChartColors.clipLowGradient, hasLength(3));
    });

    test('twilight astro applies alpha', () {
      expect(SkotiqChartColors.twilightAstro(alpha: 0.4).a, closeTo(0.4, 0.01));
    });
  });
}
