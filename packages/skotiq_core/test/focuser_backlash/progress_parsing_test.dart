import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/focuser_backlash_calibration.dart';
import 'package:skotiq_core/src/models/focuser_backlash_progress.dart';

import 'fixtures.dart';

String progressFrame({
  required String phase,
  int point = 3,
  int totalPoints = 13,
  int position = 6500,
  double hfr = 5.66,
  int starCount = 41,
}) => jsonEncode({
  'type': 'focuser_backlash_progress',
  'phase': phase,
  'point': point,
  'total_points': totalPoints,
  'position': position,
  'hfr': hfr,
  'star_count': starCount,
  'scan_range': {'min': 6440, 'max': 6800},
  'points': [
    {'position': 6440, 'hfr': 11.2},
    {'position': 6470, 'hfr': 8.9},
    {'position': position, 'hfr': hfr},
  ],
});

void main() {
  test('a from-below frame carries the point, the field and the curve', () {
    final progress = FocuserBacklashProgressData.tryParse(
      progressFrame(phase: 'from_below'),
    );

    expect(progress, isNotNull);
    expect(progress!.phase, FocuserBacklashPhase.scanningFromBelow);
    expect(progress.point, 3);
    expect(progress.totalPoints, 13);
    expect(progress.position, 6500);
    expect(progress.hfr, 5.66);
    expect(progress.starCount, 41);
    expect(progress.scanRange!.min, 6440);
    expect(progress.scanRange!.max, 6800);
    expect(progress.points, hasLength(3));
    expect(progress.points.last.position, 6500);
    expect(progress.phase.isActive, isTrue);
  });

  test('a from-above frame is a distinct phase, not a flag on one scan', () {
    final below = FocuserBacklashProgressData.tryParse(
      progressFrame(phase: 'from_below'),
    )!;
    final above = FocuserBacklashProgressData.tryParse(
      progressFrame(phase: 'from_above'),
    )!;

    expect(below.phase, isNot(above.phase));
    expect(above.phase, FocuserBacklashPhase.scanningFromAbove);
  });

  test('the analysing frame carries only its type and phase', () {
    final progress = FocuserBacklashProgressData.tryParse(
      jsonEncode({'type': 'focuser_backlash_progress', 'phase': 'analysing'}),
    );

    expect(progress, isNotNull);
    expect(progress!.phase, FocuserBacklashPhase.analysing);
    expect(progress.point, 0);
    expect(progress.totalPoints, 0);
    expect(progress.position, isNull);
    expect(progress.hfr, isNull);
    expect(progress.starCount, isNull);
    expect(progress.scanRange, isNull);
    expect(progress.points, isEmpty);
    // Both scans are done but the focuser has not been released yet.
    expect(progress.phase.isActive, isTrue);
  });

  test('the result frame parses as a result, never as progress', () {
    final frame = jsonEncode({
      'type': 'focuser_backlash_result',
      'result': jsonDecode(measuredOutcomeJson()),
    });

    expect(FocuserBacklashProgressData.tryParse(frame), isNull);
    final result = FocuserBacklashProgressData.tryParseResult(frame);
    expect(result, isNotNull);
    expect(result!.kind, FocuserBacklashOutcomeKind.measured);
    expect(result.calibration!.steps, 105);
  });

  test('a progress frame does not parse as a result', () {
    expect(
      FocuserBacklashProgressData.tryParseResult(
        progressFrame(phase: 'from_below'),
      ),
      isNull,
    );
  });

  group('frames that cannot be trusted are dropped', () {
    final cases = <String, String>{
      'not JSON': 'from_below point 3',
      'an autofocus frame': jsonEncode({
        'type': 'autofocus_progress',
        'point': 3,
      }),
      'an unknown phase': progressFrame(phase: 'sideways'),
      'a missing star count': jsonEncode({
        'type': 'focuser_backlash_progress',
        'phase': 'from_below',
        'point': 3,
        'total_points': 13,
        'position': 6500,
        'hfr': 5.66,
        'points': const <Object>[],
      }),
      'a malformed scan range': jsonEncode({
        'type': 'focuser_backlash_progress',
        'phase': 'from_below',
        'point': 3,
        'total_points': 13,
        'position': 6500,
        'hfr': 5.66,
        'star_count': 41,
        'scan_range': {'min': 'low', 'max': 6800},
        'points': const <Object>[],
      }),
      'a point with no HFR': jsonEncode({
        'type': 'focuser_backlash_progress',
        'phase': 'from_below',
        'point': 3,
        'total_points': 13,
        'position': 6500,
        'hfr': 5.66,
        'star_count': 41,
        'points': [
          {'position': 6440},
        ],
      }),
    };

    for (final entry in cases.entries) {
      test(entry.key, () {
        expect(FocuserBacklashProgressData.tryParse(entry.value), isNull);
      });
    }
  });
}
