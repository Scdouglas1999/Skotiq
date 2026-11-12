// The status bar shows sidereal time as HH:MM, so the provider behind it is
// recomputed once per sidereal minute. Each recompute costs the app a frame
// whether or not the readout changes, and at once a second it was most of an
// idle window's frames.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:skotiq_planetarium/src/providers/planetarium_providers.dart';

const double _longitude = 155.66;

int _siderealMinute(DateTime t) =>
    (AstronomyCalculations.localSiderealTime(t, _longitude) * 60).floor();

void main() {
  test('the wait ends just after the sidereal minute turns', () {
    final start = DateTime.utc(2026, 11, 12, 13, 0);
    for (var s = 0; s < 600; s += 7) {
      final t = start.add(Duration(milliseconds: s * 1013));
      final wait = untilNextSiderealMinute(
        AstronomyCalculations.localSiderealTime(t, _longitude),
      );
      expect(wait, lessThanOrEqualTo(const Duration(seconds: 60)));
      expect(
        _siderealMinute(t.add(wait)),
        (_siderealMinute(t) + 1) % (24 * 60),
        reason: 'at $t the recompute must land in the next minute',
      );
      expect(
        _siderealMinute(t.add(wait - const Duration(milliseconds: 20))),
        _siderealMinute(t),
        reason: 'at $t the recompute must not come a whole minute early',
      );
    }
  });

  // Real time on purpose: the provider reads the wall clock, which a fake
  // clock does not move. A once-a-second clock publishes at least twice in
  // this window; a once-a-minute one at most once.
  test('sidereal time is not republished every second', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(observerLocationProvider.notifier)
        .setLocation(latitude: 40, longitude: _longitude);
    var published = 0;
    container.listen(localSiderealTimeProvider, (_, __) => published++);

    await Future<void>.delayed(const Duration(milliseconds: 2500));

    expect(published, lessThanOrEqualTo(1));
  });
}
