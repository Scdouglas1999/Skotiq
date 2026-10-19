// Every V-curve point carries the star count of its own frame, so the Focus
// tab can show it per point rather than only for the latest one.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

String _detail(List<Map<String, Object?>> points) => jsonEncode({
  'type': 'autofocus_progress',
  'point': points.length,
  'total_points': 9,
  'hfr': 2.4,
  'star_count': 41,
  'focus_range': {'min': 1000, 'max': 1800},
  'vcurve_points': points,
  'star_crops': <Object>[],
});

void main() {
  test('each point keeps its own star count', () {
    final data = AutofocusProgressData.tryParse(
      _detail([
        {'position': 1000, 'hfr': 4.1, 'star_count': 18},
        {'position': 1100, 'hfr': 3.2, 'star_count': 33},
        {'position': 1200, 'hfr': 2.4, 'star_count': 41},
      ]),
    )!;

    expect(data.vcurvePoints.map((p) => p.starCount), [18, 33, 41]);
    expect(data.starCount, 41);
  });

  test('a point without a count reads as unknown, not 0', () {
    final data = AutofocusProgressData.tryParse(
      _detail([
        {'position': 1000, 'hfr': 4.1},
      ]),
    )!;

    expect(data.vcurvePoints.single.starCount, isNull);
  });
}
