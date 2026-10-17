import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

/// `calculateTwilightTimes(date:)` describes a dusk-tonight → dawn-tomorrow
/// window. Anchoring the dashboard on the calendar date therefore describes the
/// *next* night once local midnight passes: observed live at 01:04 with the sun
/// 30.6° below the horizon, the header read "Dark in 21h 7m" while the observer
/// was standing in the middle of astronomical night.
///
/// [twilightTimesProvider] picks the previous evening's window while its dawn is
/// still ahead. That choice is a date-boundary rule with no other coverage, and
/// it is exactly the kind of thing that silently regresses, so these tests pin
/// the property rather than a clock reading — no assertion here depends on the
/// machine's timezone or on the date the suite happens to run.
class _FixedClock extends ObservationTimeNotifier {
  _FixedClock(DateTime when) {
    // speedMultiplier 0 so the inherited 1s timer cannot advance simulated
    // time mid-test and turn a boundary assertion into a flake.
    state = ObservationTimeState(
      time: when,
      isRealTime: false,
      speedMultiplier: 0,
    );
  }
}

class _FixedSite extends PlanetariumObserverNotifier {
  _FixedSite(double lat, double lon) {
    state = PlanetariumObserver(latitude: lat, longitude: lon);
  }
}

void main() {
  // A mid-latitude site with a genuine astronomical night in July.
  const lat = 39.9846;
  const lon = -75.3514;

  ProviderContainer containerAt(DateTime now) {
    final container = ProviderContainer(
      overrides: [
        observationTimeProvider.overrideWith((ref) => _FixedClock(now)),
        observerLocationProvider.overrideWith((ref) => _FixedSite(lat, lon)),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  TwilightTimes windowFor(DateTime date) =>
      AstronomyCalculations.calculateTwilightTimes(
        date: date,
        latitudeDeg: lat,
        longitudeDeg: lon,
      );

  test('during the small hours it reports the night actually in progress', () {
    // Anchor on a real night, then step back an hour from its dawn: that
    // instant is unambiguously inside the night that began the evening before.
    final tonight = windowFor(DateTime(2026, 7, 25));
    final dawn = tonight.astronomicalDawn;
    expect(dawn, isNotNull, reason: 'site must have a true astronomical night');
    final now = dawn!.subtract(const Duration(hours: 1));

    final active = containerAt(now).read(twilightTimesProvider);

    expect(
      active.astronomicalDusk!.isBefore(now),
      isTrue,
      reason: 'the reported night must already have begun',
    );
    expect(
      active.astronomicalDawn!.isAfter(now),
      isTrue,
      reason:
          'the reported night must not have ended yet — this is the '
          'regression: the calendar-anchored window described the NEXT night, '
          'so darkness looked ~21h away while it was pitch dark outside',
    );
  });

  test('after dawn it switches to the night starting tonight', () {
    final tonight = windowFor(DateTime(2026, 7, 25));
    // An hour past dawn: the previous night is over.
    final now = tonight.astronomicalDawn!.add(const Duration(hours: 1));

    final active = containerAt(now).read(twilightTimesProvider);

    expect(
      active.astronomicalDusk!.isAfter(now),
      isTrue,
      reason: 'once the night has ended the next one must still be ahead',
    );
  });

  test('in the evening it reports tonight, not last night', () {
    final tonight = windowFor(DateTime(2026, 7, 25));
    final now = tonight.astronomicalDusk!.add(const Duration(minutes: 30));

    final active = containerAt(now).read(twilightTimesProvider);

    expect(active.astronomicalDusk!.isBefore(now), isTrue);
    expect(active.astronomicalDawn!.isAfter(now), isTrue);
  });
}
