// The dawn park time read null on a machine whose zone is far from the site
// (Boston's night checked from Asia/Tokyo): nextDawn looked for the night
// after the host's local noon, which for a far-east host is the site's night
// before, so tonight's dawn was never a candidate.
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:test/test.dart';

void main() {
  const lat = 42.36;
  const lon = -71.06;

  test('the next dawn at the site does not depend on the host zone', () {
    // 18:36 EDT: tonight's dawn, about 05:29 EDT the next morning.
    final evening = DateTime.utc(2026, 10, 19, 22, 36);
    final dawn = AstronomyCalculations.nextDawn(
      now: evening,
      latitudeDeg: lat,
      longitudeDeg: lon,
    );
    expect(dawn, isNotNull);
    expect(dawn!.isAfter(evening), isTrue);
    expect(dawn.difference(evening), lessThan(const Duration(hours: 13)));
    expect(
      dawn,
      AstronomyCalculations.nightAt(
        now: evening,
        latitudeDeg: lat,
        longitudeDeg: lon,
      ).astronomicalDawn,
    );
  });

  test('after midnight the next dawn is the night in progress', () {
    // 02:00 EDT.
    final night = DateTime.utc(2026, 10, 20, 6);
    final dawn = AstronomyCalculations.nextDawn(
      now: night,
      latitudeDeg: lat,
      longitudeDeg: lon,
    )!;
    expect(dawn.isAfter(night), isTrue);
    expect(dawn.difference(night), lessThan(const Duration(hours: 5)));
  });
}
