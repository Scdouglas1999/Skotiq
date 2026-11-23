// The Loop node's "Civil dawn" and "Nautical dawn" buttons set the loop to
// end at the next dawn at the site.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/next_dawn.dart';
import 'package:skotiq_astro/skotiq_astro.dart';

const _latitude = 40.7;
const _longitude = -74.0;

void main() {
  DateTime start(int year, int month, int day) =>
      AstronomyCalculations.nightStartOf(
        NightDate(year, month, day),
        longitudeDeg: _longitude,
      );

  void expectDawnOfNight(DateTime? dawn, NightDate night, DateTime now) {
    expect(dawn, isNotNull);
    final from = start(night.year, night.month, night.day);
    final to = from.add(const Duration(days: 1));
    expect(
      !dawn!.isBefore(from) && dawn.isBefore(to) && dawn.isAfter(now),
      isTrue,
      reason: 'dawn $dawn for $now is not the dawn of the night of $night',
    );
  }

  DateTime? civil(DateTime now) => nextDawn(
        now,
        latitudeDeg: _latitude,
        longitudeDeg: _longitude,
        dawn: (t) => t.civilDawn,
      );

  // The buttons read the computer's clock, which is local time.
  test('in the evening it is the coming morning', () {
    final now = DateTime.utc(2026, 11, 22, 2).toLocal(); // 21:00 at the site
    expectDawnOfNight(civil(now), const NightDate(2026, 11, 21), now);
  });

  test('after dawn it is the next morning', () {
    final now = DateTime.utc(2026, 11, 22, 13).toLocal(); // 08:00 at the site
    expectDawnOfNight(civil(now), const NightDate(2026, 11, 22), now);
  });
}
