import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

/// The catalogue queries take a SHORT-AXIS field of view. Without an aspect
/// correction they fetch a square sky region regardless of window shape, so on
/// a wide window the outer columns have no star data — and stars pop in and out
/// at the region boundary while panning. On a 3.6:1 ultrawide only ~42% of the
/// screen width had data.
void main() {
  /// A star at [raHours] on the celestial equator, bright enough to always pass
  /// the magnitude gate.
  Star starAt(double raHours) => Star(
    id: 'ra$raHours',
    name: 'ra$raHours',
    coordinates: CelestialCoordinate(ra: raHours, dec: 0),
    magnitude: 1.0,
  );

  StarSpatialIndex indexAcrossTheSky() {
    final index = StarSpatialIndex();
    // One star every 2 degrees of RA across the whole equator.
    index.addAll([for (var d = 0.0; d < 360; d += 2.0) starAt(d / 15.0)]);
    return index;
  }

  /// Widest RA offset (degrees, signed-shortest) present in [stars] relative to
  /// a view centred at RA 0.
  double widestOffsetDeg(List<Star> stars) {
    var widest = 0.0;
    for (final s in stars) {
      var d = s.coordinates.ra * 15.0;
      if (d > 180) d -= 360;
      if (d.abs() > widest) widest = d.abs();
    }
    return widest;
  }

  test('a wide canvas fetches stars across its full width', () {
    final index = indexAcrossTheSky();
    const fov = 60.0; // short axis

    final square = index.queryBrightestInViewport(
      0,
      0,
      fov,
      maxMagnitude: 6,
      maxResults: 100000,
    );
    final ultrawide = index.queryBrightestInViewport(
      0,
      0,
      fov,
      maxMagnitude: 6,
      maxResults: 100000,
      aspectRatio: 3.58, // 5120x1440-class window
    );

    // A 3.58:1 window spans +/-107 deg horizontally; the square query reaches
    // only +/-45 and cannot cover it. The corrected query saturates at the
    // +/-90 deg cap, which is the useful maximum — the projection culls
    // anything more than ~89 deg from the view centre as being behind the
    // viewer, so covering half the sky covers everything drawable.
    expect(widestOffsetDeg(square), lessThan(50));
    expect(
      widestOffsetDeg(ultrawide),
      greaterThan(80),
      reason: 'the ultrawide query must reach the edges of the window',
    );
    expect(ultrawide.length, greaterThan(square.length * 2));
  });

  test('a tall canvas fetches stars across its full height', () {
    final index = StarSpatialIndex();
    index.addAll([
      for (var dec = -80.0; dec <= 80.0; dec += 2.0)
        Star(
          id: 'dec$dec',
          name: 'dec$dec',
          coordinates: CelestialCoordinate(ra: 0, dec: dec),
          magnitude: 1.0,
        ),
    ]);

    List<Star> q(double aspect) => index.queryBrightestInViewport(
      0,
      0,
      30.0,
      maxMagnitude: 6,
      maxResults: 100000,
      aspectRatio: aspect,
    );

    double widestDec(List<Star> s) => s.fold(
      0.0,
      (m, x) => x.coordinates.dec.abs() > m ? x.coordinates.dec.abs() : m,
    );

    // Portrait: the LONG axis is vertical, so the dec extent must grow.
    expect(widestDec(q(1.0)), lessThan(25));
    expect(widestDec(q(1 / 3.0)), greaterThan(50));
  });

  test('a square canvas is unchanged by the correction', () {
    final index = indexAcrossTheSky();
    final withDefault = index.queryBrightestInViewport(
      0,
      0,
      60,
      maxMagnitude: 6,
      maxResults: 100000,
    );
    final withUnitAspect = index.queryBrightestInViewport(
      0,
      0,
      60,
      maxMagnitude: 6,
      maxResults: 100000,
      aspectRatio: 1.0,
    );
    expect(withUnitAspect.length, withDefault.length);
  });

  test('a nonsense aspect ratio falls back to square rather than throwing', () {
    final index = indexAcrossTheSky();
    for (final bad in [0.0, -2.0, double.nan, double.infinity]) {
      final r = index.queryBrightestInViewport(
        0,
        0,
        60,
        maxMagnitude: 6,
        maxResults: 100000,
        aspectRatio: bad,
      );
      expect(r, isNotEmpty);
      expect(widestOffsetDeg(r), lessThan(50));
    }
  });
}
