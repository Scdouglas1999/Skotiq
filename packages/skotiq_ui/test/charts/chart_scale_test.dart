import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/src/charts/chart_scale.dart';

void main() {
  group('niceStep', () {
    test('rounds up to 1, 2, 2.5 or 5 times a power of ten', () {
      expect(ChartScale.niceStep(0.07), closeTo(0.1, 1e-12));
      expect(ChartScale.niceStep(0.11), closeTo(0.2, 1e-12));
      expect(ChartScale.niceStep(0.21), closeTo(0.25, 1e-12));
      expect(ChartScale.niceStep(0.3), closeTo(0.5, 1e-12));
      expect(ChartScale.niceStep(7), 10);
      expect(ChartScale.niceStep(1), 1);
      expect(ChartScale.niceStep(0), 1);
      expect(ChartScale.niceStep(double.nan), 1);
    });
  });

  group('niceRange', () {
    test('snaps both ends to ticks so no end label crowds a tick', () {
      final r = ChartScale.niceRange(1.71, 3.25);
      expect(r.min, lessThanOrEqualTo(1.71));
      expect(r.max, greaterThanOrEqualTo(3.25));
      expect(r.ticks.values.first, r.min);
      expect(r.ticks.values.last, r.max);
      final step = r.ticks.step;
      for (final v in r.ticks.values) {
        expect((v / step - (v / step).round()).abs(), lessThan(1e-6));
      }
    });

    test('labels carry the precision of the step', () {
      final r = ChartScale.niceRange(0.0, 0.043, padFraction: 0.1);
      expect(
        r.ticks.values.map(r.ticks.label).toSet().length,
        r.ticks.values.length,
        reason: 'no two ticks may print the same text',
      );
    });

    test('a flat series gets a window centered on its value', () {
      final r = ChartScale.niceRange(0.7, 0.7);
      expect(r.min, lessThan(0.7));
      expect(r.max, greaterThan(0.7));
      expect(r.ticks.values.length, 5);
      expect(r.ticks.values.first, r.min);
    });

    test('includeZero keeps zero in the range', () {
      expect(ChartScale.niceRange(40, 55, includeZero: true).min, 0);
      expect(ChartScale.niceRange(-55, -40, includeZero: true).max, 0);
    });

    test('never prints a negative zero', () {
      final r = ChartScale.niceRange(-0.2, 0.2);
      expect(r.ticks.label(-0.0000001), isNot(startsWith('-')));
    });
  });

  test('a reading is one place finer than the ticks', () {
    const hfr = ChartTicks(<double>[1.5, 2, 2.5, 3, 3.5], 1);
    expect(hfr.label(2.02), '2.0');
    expect(hfr.reading(2.02), '2.02');
    const steps = ChartTicks(<double>[45420, 45440, 45460], 0);
    expect(steps.reading(45438.4), '45438');
    const temp = ChartTicks(<double>[-10.2, -10, -9.8], 1);
    expect(temp.reading(-10.0), '-10.00');
    expect(temp.reading(-0.001), '0.00');
  });

  group('ticksWithin', () {
    test('picks round values inside the range', () {
      expect(ChartScale.ticksWithin(0, 90, 4).values, <double>[0, 25, 50, 75]);
      expect(ChartScale.ticksWithin(0, 90, 2).values, <double>[0, 50]);
      expect(ChartScale.ticksWithin(1.9, 3.3, 3).values, <double>[2, 2.5, 3]);
      expect(ChartScale.ticksWithin(-1, 1, 3).values, <double>[-1, 0, 1]);
    });

    test('keeps both ends when only two fit', () {
      expect(ChartScale.ticksWithin(-1, 1, 2).values, <double>[-1, 1]);
    });

    test('falls back to the ends when no round value is inside', () {
      final t = ChartScale.ticksWithin(0.123401, 0.123409, 3);
      expect(t.values.length, greaterThanOrEqualTo(2));
    });

    test('a degenerate range is one tick', () {
      expect(ChartScale.ticksWithin(2, 2, 3).values, <double>[2]);
    });
  });

  group('time axes', () {
    test('clock ticks land on round minutes counted from midnight', () {
      final ticks = ChartScale.clockTicks(
        DateTime(2026, 11, 10, 21, 7),
        DateTime(2026, 11, 11, 4, 52),
        5,
      );
      expect(ticks, isNotEmpty);
      for (final t in ticks) {
        expect(t.minute, 0);
        expect(t.hour % 2, 0);
      }
    });

    test('elapsed ticks use round time steps', () {
      // 7 h 8 min used to be cut into four equal parts: 1h47m, 3h34m, ...
      expect(ChartScale.elapsedTicks(0, 25680, 5), <double>[
        0,
        7200,
        14400,
        21600,
      ]);
      expect(ChartScale.elapsedTicks(-300, 0, 5), <double>[-240, -120, 0]);
      expect(ChartScale.elapsedTicks(-300, 0, 6), <double>[
        -300,
        -240,
        -180,
        -120,
        -60,
        0,
      ]);
    });

    test('log ticks sit at 1, 2 and 5 per decade', () {
      expect(ChartScale.logTicks(0.08, 3.2), <double>[0.1, 0.2, 0.5, 1, 2]);
      expect(ChartScale.logTicks(0.001, 1000, maxTicks: 7), <double>[
        0.001,
        0.01,
        0.1,
        1,
        10,
        100,
        1000,
      ]);
      expect(ChartScale.logTicks(1.2, 1.4), <double>[1.2, 1.4]);
    });

    test('elapsed labels pick the unit from the size', () {
      expect(ChartScale.elapsedLabel(45), '45s');
      expect(ChartScale.elapsedLabel(720), '12m');
      expect(ChartScale.elapsedLabel(90), '1:30');
      expect(ChartScale.elapsedLabel(7200), '2h');
      expect(ChartScale.elapsedLabel(5400), '1h30m');
      expect(ChartScale.elapsedLabel(3 * 86400), '3d');
      expect(ChartScale.elapsedLabel(-120), '-2m');
      expect(ChartScale.elapsedLabel(0), '0s');
    });
  });
}
