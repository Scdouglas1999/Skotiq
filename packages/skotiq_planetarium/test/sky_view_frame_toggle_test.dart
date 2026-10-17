// Switching the sky view between the equatorial and horizontal frames is a
// change of GRID, not of target.
//
// With the chart centred on M57 at a 2.0 deg imaging field, one click on the
// command bar's Alt/Az toggle otherwise recentres it on RA 4h42m52s /
// Dec +39d59' — hour angle 0 at declination = the 40 deg site latitude, i.e.
// the zenith. Flipping only SkyViewState.viewMode leaves the two frames on
// their independent centres, and the horizontal one still holds the
// (az 0, alt 90) the last reset left there.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

const _lat = 40.0;
const _lon = -105.0;

/// M57, the target the finding was framed on.
const _m57Ra = 18 + 53 / 60 + 35.0 / 3600;
const _m57Dec = 33 + 1 / 60 + 45.0 / 3600;

ProviderContainer _container() {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  container
      .read(observerLocationProvider.notifier)
      .setLocation(latitude: _lat, longitude: _lon);
  return container;
}

void main() {
  final instant = DateTime.utc(2026, 8, 3, 4, 43);

  test('switching to Alt/Az keeps the aimed patch of sky, not the zenith', () {
    final container = _container();
    final view = container.read(skyViewStateProvider.notifier);
    final observer = container.read(observerLocationProvider);

    // Whatever the horizontal frame was last left on — the reset action parks
    // it at the zenith, which is exactly what used to leak through.
    view.setHorizontalCenter(0, 90);
    view.setCenter(_m57Ra, _m57Dec);
    view.setFieldOfView(2);

    view.setViewMode(
      SkyViewMode.horizontal,
      observer: observer,
      instant: instant,
    );

    // The CAMERA transform, not objectAltAz: the renderer projects catalog
    // J2000 positions with this same unprecessed transform, so precessing the
    // view centre would slide the frame ~22 arcmin off the stars it draws.
    final expected = AstronomyCalculations.equatorialToHorizontal(
      raDeg: _m57Ra * 15,
      decDeg: _m57Dec,
      latitudeDeg: _lat,
      lstHours: AstronomyCalculations.localSiderealTime(instant, _lon),
    );

    final state = container.read(skyViewStateProvider);
    expect(state.viewMode, SkyViewMode.horizontal);
    expect(state.centerAltitude, closeTo(expected.$1, 0.2));
    expect(state.centerAz, closeTo(expected.$2, 0.2));
    expect(
      state.centerAltitude,
      isNot(closeTo(90, 1)),
      reason: 'landing on the zenith is the original bug',
    );
    expect(state.fieldOfView, 2, reason: 'the frame change is not a zoom');
  });

  test('toggling back returns to the same patch of sky', () {
    final container = _container();
    final view = container.read(skyViewStateProvider.notifier);
    final observer = container.read(observerLocationProvider);

    view.setCenter(_m57Ra, _m57Dec);
    view.setViewMode(
      SkyViewMode.horizontal,
      observer: observer,
      instant: instant,
    );
    view.setViewMode(
      SkyViewMode.equatorial,
      observer: observer,
      instant: instant,
    );

    final state = container.read(skyViewStateProvider);
    expect(state.viewMode, SkyViewMode.equatorial);
    expect(state.centerRA, closeTo(_m57Ra, 0.01));
    expect(state.centerDec, closeTo(_m57Dec, 0.05));
  });

  test(
    'a centre below the horizon converts honestly rather than snapping up',
    () {
      final container = _container();
      final view = container.read(skyViewStateProvider.notifier);
      final observer = container.read(observerLocationProvider);

      // Anti-zenith of the instant above: guaranteed under the horizon.
      final zenith = skyViewHomeCenterAt(observer, instant)!;
      view.setCenter((zenith.$1 + 12) % 24, -zenith.$2);

      view.setViewMode(
        SkyViewMode.horizontal,
        observer: observer,
        instant: instant,
      );

      expect(container.read(skyViewStateProvider).centerAltitude, lessThan(0));
    },
  );
}
