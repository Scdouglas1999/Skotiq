import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/run_dashboard/weather_safety_card.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  const colors = SkotiqColors.dark;

  group('weatherGradeAscending (higher is worse)', () {
    test('below warn threshold grades safe/green', () {
      final c = weatherGradeAscending(
        20,
        warnAt: 60,
        unsafeAt: 80,
        colors: colors,
      );
      expect(c, colors.success);
    });

    test('between warn and unsafe grades warning/amber', () {
      final c = weatherGradeAscending(
        65,
        warnAt: 60,
        unsafeAt: 80,
        colors: colors,
      );
      expect(c, colors.warning);
    });

    test('at or above unsafe grades error/red', () {
      expect(
        weatherGradeAscending(80, warnAt: 60, unsafeAt: 80, colors: colors),
        colors.error,
      );
      expect(
        weatherGradeAscending(95, warnAt: 60, unsafeAt: 80, colors: colors),
        colors.error,
      );
    });
  });

  group('weatherGradeDescending (lower is worse)', () {
    test('comfortably above warn grades safe/green', () {
      final c = weatherGradeDescending(
        12,
        warnBelow: 5,
        unsafeBelow: 2,
        colors: colors,
      );
      expect(c, colors.success);
    });

    test('between unsafe and warn grades warning/amber', () {
      final c = weatherGradeDescending(
        4,
        warnBelow: 5,
        unsafeBelow: 2,
        colors: colors,
      );
      expect(c, colors.warning);
    });

    test('at or below unsafe grades error/red', () {
      expect(
        weatherGradeDescending(2, warnBelow: 5, unsafeBelow: 2, colors: colors),
        colors.error,
      );
      expect(
        weatherGradeDescending(0.5,
            warnBelow: 5, unsafeBelow: 2, colors: colors),
        colors.error,
      );
    });
  });
}
