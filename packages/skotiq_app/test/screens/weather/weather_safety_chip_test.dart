import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/weather/weather_screen.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  // Night test 2026-11-26: the Weather chip said "Not monitored" while the
  // rig's safety monitor was connected, reporting Safe and guarding the run.
  group('the header chip with weather monitoring off', () {
    for (final (monitor, label, tone)
        in <(SafetySourceReading, String, ChipTone)>[
      (SafetySourceReading.safe, 'Safe', ChipTone.success),
      (SafetySourceReading.unsafe, 'Unsafe', ChipTone.error),
      (SafetySourceReading.unknown, 'Not monitored', ChipTone.neutral),
      (SafetySourceReading.absent, 'Not monitored', ChipTone.neutral),
    ]) {
      test('a safety monitor reading $monitor reads "$label"', () {
        expect(
          weatherSafetyChipLabel(
            status: WeatherSafetyStatus.safe,
            monitoring: false,
            monitor: monitor,
          ),
          label,
        );
        expect(
          weatherSafetyChipTone(
            status: WeatherSafetyStatus.safe,
            monitoring: false,
            monitor: monitor,
          ),
          tone,
        );
      });
    }
  });
}
