// The planetarium must not invent an observing site.
//
// Before the app's settings sync pushes one in there is no site on record, and
// every site-derived readout has to say "unknown" rather than describe the sky
// over somewhere the observer is not. Phase and illumination are the same
// everywhere on Earth, so those survive.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

void main() {
  ProviderContainer makeContainer() {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    return container;
  }

  test('a fresh observer holds no coordinates', () {
    final container = makeContainer();
    final observer = container.read(observerLocationProvider);

    expect(observer.latitude, isNull);
    expect(observer.longitude, isNull);
    expect(observer.site, isNull);
    expect(observer.hasSite, isFalse);
  });

  test('site-derived readouts are unknown until a site is set', () {
    final container = makeContainer();

    expect(container.read(localSiderealTimeProvider), isNull);
    expect(container.read(observationSiderealTimeProvider), isNull);
    expect(container.read(sunAltitudeProvider), isNull);
    expect(container.read(skyViewHomeCenterProvider), isNull);

    final twilight = container.read(twilightTimesProvider);
    expect(twilight.sunset, isNull);
    expect(twilight.astronomicalDusk, isNull);
    expect(twilight.astronomicalDawn, isNull);
    expect(twilight.sunrise, isNull);
  });

  test('the moon keeps its global facts and drops its local ones', () {
    final container = makeContainer();
    final moon = container.read(moonInfoProvider);

    expect(moon.moonrise, isNull);
    expect(moon.moonset, isNull);
    // Phase and illumination do not depend on where the observer stands.
    expect(moon.illumination, inInclusiveRange(0, 100));
    expect(moon.phaseName, isNotEmpty);
  });

  test('tonight\'s targets are unknown, not empty, without a site', () async {
    final container = makeContainer();

    expect(await container.read(bestTargetsProvider.future), isNull);
  });

  test('the 0/0 settings sentinel does not become an observing site', () {
    final container = makeContainer();

    container
        .read(observerLocationProvider.notifier)
        .setLocation(latitude: 0.0, longitude: 0.0, elevation: 12);

    final observer = container.read(observerLocationProvider);
    expect(observer.site, isNull);
    expect(observer.elevation, 12);
    expect(container.read(localSiderealTimeProvider), isNull);
  });

  test('a real site turns the readouts back on', () {
    final container = makeContainer();

    container
        .read(observerLocationProvider.notifier)
        .setLocation(latitude: 40.71, longitude: -74.01);

    expect(container.read(observerLocationProvider).hasSite, isTrue);
    expect(container.read(localSiderealTimeProvider), isNotNull);
    expect(container.read(sunAltitudeProvider), isNotNull);
    expect(container.read(skyViewHomeCenterProvider), isNotNull);
    expect(container.read(twilightTimesProvider).sunset, isNotNull);
  });

  test('clearing the site puts every readout back to unknown', () {
    final container = makeContainer();
    final notifier = container.read(observerLocationProvider.notifier);

    notifier.setLocation(latitude: 40.71, longitude: -74.01);
    expect(container.read(localSiderealTimeProvider), isNotNull);

    notifier.clearLocation();
    expect(container.read(observerLocationProvider).hasSite, isFalse);
    expect(container.read(localSiderealTimeProvider), isNull);
    expect(container.read(moonInfoProvider).moonrise, isNull);
  });
}
