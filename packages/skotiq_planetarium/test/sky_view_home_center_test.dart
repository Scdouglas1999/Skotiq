// The planetarium's OPENING view homes on the zenith.
//
// A reset that homes on the zenith is not enough on its own: an initial state
// left at the constructor's RA 0h / Dec 0 puts first paint at 40N / 105W
// 25-45 deg BELOW the horizon, with the bottom bar reading "Center RA 0h 0m 0s
// Center Dec +0 0'" while the compass HUD reads alt -45 — a map that opens
// aimed into the ground.
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_planetarium/src/astronomy/astronomy_calculations.dart';
import 'package:skotiq_planetarium/src/providers/planetarium_providers.dart';

const _latitude = 40.0;
const _longitude = -105.0;

double _altitudeOfViewCentre(ProviderContainer container) {
  final view = container.read(skyViewStateProvider);
  final (alt, _) = AstronomyCalculations.objectAltAz(
    raDeg: view.centerRA * 15,
    decDeg: view.centerDec,
    dt: container.read(observationTimeProvider).time,
    latitudeDeg: _latitude,
    longitudeDeg: _longitude,
  );
  return alt;
}

void main() {
  test('first paint opens on sky that is up, not on RA 0h / Dec 0', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(observerLocationProvider.notifier)
        .setLocation(latitude: _latitude, longitude: _longitude);

    final home = container.read(skyViewHomeCenterProvider)!;
    final (homeRa, homeDec) = home;
    final view = container.read(skyViewStateProvider);

    // Tolerance: the notifier homes off the wall clock, the provider off the
    // minute-truncated observation clock, so they can differ by up to a minute
    // of sidereal rotation (1/60 h of RA).
    expect(view.centerRA, closeTo(homeRa, 0.02));
    expect(view.centerDec, closeTo(homeDec, 1e-9));
    // The zenith, so within a minute of clock slop of straight up — and above
    // all the horizon is what actually matters.
    expect(
      _altitudeOfViewCentre(container),
      greaterThan(85.0),
      reason: 'the opening view must not be aimed below the horizon',
    );
  });

  test('a site that arrives after first build re-homes an untouched view', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    // Materialise the view BEFORE the site is known — this is the real order:
    // the observer starts with no site and the app's settings sync pushes the
    // user's site in later.
    container.read(skyViewStateProvider);
    container
        .read(observerLocationProvider.notifier)
        .setLocation(latitude: _latitude, longitude: _longitude);

    final (homeRa, homeDec) = container.read(skyViewHomeCenterProvider)!;
    final view = container.read(skyViewStateProvider);
    expect(view.centerRA, closeTo(homeRa, 0.02));
    expect(view.centerDec, closeTo(homeDec, 1e-9));
    expect(_altitudeOfViewCentre(container), greaterThan(85.0));
  });

  test('with no site on record there is no home to point at', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(observerLocationProvider).hasSite, isFalse);
    expect(container.read(skyViewHomeCenterProvider), isNull);
  });

  test('the settings 0/0 sentinel leaves the site unset', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container
        .read(observerLocationProvider.notifier)
        .setLocation(latitude: 0.0, longitude: 0.0);

    expect(container.read(observerLocationProvider).hasSite, isFalse);
    expect(container.read(skyViewHomeCenterProvider), isNull);
  });

  test('a late site never yanks the camera off a view the user aimed', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(skyViewStateProvider.notifier).setCenter(5.5, 12.5);
    container
        .read(observerLocationProvider.notifier)
        .setLocation(latitude: _latitude, longitude: _longitude);

    final view = container.read(skyViewStateProvider);
    expect(view.centerRA, closeTo(5.5, 1e-9));
    expect(view.centerDec, closeTo(12.5, 1e-9));
  });
}
