import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/src/astronomy/astronomy_calculations.dart';
import 'package:skotiq_planetarium/src/astronomy/planetary_positions.dart';

/// Parity harness for the planetarium half of the astronomy consolidation
/// (release pass, Wave C2).
///
/// `PlanetaryPositions.julianDate`, `MinorPlanetCatalog._julianDate` and
/// `VariableStarCatalog._julianDate` were three re-typings of
/// [AstronomyCalculations.julianDate] and now call through to it. Each retired
/// body is transcribed here and compared with exact `==`, because the values
/// feed orbit propagation and variable-star phase, where a tolerance would
/// hide a real drift.
void main() {
  /// `planetary_positions.dart:23` and `minor_planet_catalog.dart:312` —
  /// Fliegel–Van Flandern, millisecond day fraction. (The minor-planet copy
  /// omitted the `toUtc()`; its only caller already passed a UTC instant, so
  /// the two agree wherever it was actually used, which is what the
  /// `already UTC` case below pins.)
  double retiredFliegelMilliseconds(DateTime dt, {bool normalize = true}) {
    final utc = normalize ? dt.toUtc() : dt;
    final y = utc.year;
    final m = utc.month;
    final d =
        utc.day +
        utc.hour / 24 +
        utc.minute / 1440 +
        utc.second / 86400 +
        utc.millisecond / 86400000;

    final a = ((14 - m) / 12).floor();
    final y2 = y + 4800 - a;
    final m2 = m + 12 * a - 3;

    return d +
        ((153 * m2 + 2) / 5).floor() +
        365 * y2 +
        (y2 / 4).floor() -
        (y2 / 100).floor() +
        (y2 / 400).floor() -
        32045 -
        0.5;
  }

  /// `variable_star_catalog.dart:235` — same form, whole-second day fraction.
  double retiredFliegelWholeSeconds(DateTime dt) {
    final utc = dt.toUtc();
    final y = utc.year;
    final m = utc.month;
    final d = utc.day + utc.hour / 24 + utc.minute / 1440 + utc.second / 86400;
    final a = ((14 - m) / 12).floor();
    final y2 = y + 4800 - a;
    final m2 = m + 12 * a - 3;
    return d +
        ((153 * m2 + 2) / 5).floor() +
        365 * y2 +
        (y2 / 4).floor() -
        (y2 / 100).floor() +
        (y2 / 400).floor() -
        32045 -
        0.5;
  }

  final instants = <DateTime>[
    DateTime.utc(2000, 1, 1, 12), // J2000.0
    DateTime.utc(1999, 12, 31, 23, 59, 59, 999),
    DateTime.utc(2026, 1, 1),
    DateTime.utc(2026, 2, 28, 23, 59, 59, 999),
    DateTime.utc(2024, 2, 29, 6, 30, 15, 250), // leap day
    DateTime.utc(1900, 3, 1), // century, not a leap year
    DateTime.utc(2000, 3, 1), // century that IS a leap year
    DateTime.utc(2100, 7, 4, 18, 45, 12, 1),
    DateTime.utc(2026, 8, 13, 3, 21, 44, 617),
    DateTime.utc(1957, 10, 4, 19, 28, 34), // Sputnik, pre-J2000 by decades
  ];

  group('AstronomyCalculations.julianDate', () {
    test(
      'millisecond form matches the retired planetary/minor-planet copy',
      () {
        for (final t in instants) {
          expect(
            AstronomyCalculations.julianDate(t),
            equals(retiredFliegelMilliseconds(t)),
            reason: 'JD(ms) diverged at $t',
          );
        }
      },
    );

    test('whole-second form matches the retired variable-star copy', () {
      for (final t in instants) {
        expect(
          AstronomyCalculations.julianDate(t, includeMilliseconds: false),
          equals(retiredFliegelWholeSeconds(t)),
          reason: 'JD(s) diverged at $t',
        );
      }
    });

    test('the flag is actually wired through', () {
      final t = DateTime.utc(2026, 8, 13, 3, 21, 44, 617);
      expect(
        AstronomyCalculations.julianDate(t),
        isNot(
          equals(
            AstronomyCalculations.julianDate(t, includeMilliseconds: false),
          ),
        ),
      );
    });

    test('a zero-millisecond instant is identical under both flags', () {
      final t = DateTime.utc(2026, 8, 13, 3, 21, 44);
      expect(
        AstronomyCalculations.julianDate(t),
        equals(AstronomyCalculations.julianDate(t, includeMilliseconds: false)),
      );
    });

    test('the minor-planet copy agreed wherever it was called', () {
      // `KeplerianPropagator.propagate` passes `time.toUtc()`, so the copy's
      // missing normalization never fired; routing it through the shared
      // function is exact for every instant it ever saw.
      for (final t in instants) {
        expect(
          AstronomyCalculations.julianDate(t),
          equals(retiredFliegelMilliseconds(t, normalize: false)),
          reason: 'minor-planet parity diverged at $t',
        );
      }
    });

    test('a local DateTime normalizes before it computes', () {
      final local = DateTime(2026, 8, 13, 3, 21, 44, 617);
      expect(
        AstronomyCalculations.julianDate(local),
        equals(AstronomyCalculations.julianDate(local.toUtc())),
      );
    });

    test('J2000.0 is 2451545.0 on the nose', () {
      expect(
        AstronomyCalculations.julianDate(DateTime.utc(2000, 1, 1, 12)),
        2451545.0,
      );
    });

    test('PlanetaryPositions.julianDate is the same function', () {
      for (final t in instants) {
        expect(
          PlanetaryPositions.julianDate(t),
          equals(AstronomyCalculations.julianDate(t)),
        );
      }
    });
  });

  group('GMST / LST built on the shared Julian Date', () {
    test('GMST stays in [0, 24) hours', () {
      for (final t in instants) {
        final gmst = AstronomyCalculations.greenwichMeanSiderealTime(t);
        expect(gmst, greaterThanOrEqualTo(0.0));
        expect(gmst, lessThan(24.0));
      }
    });

    test('LST stays in [0, 24) for longitudes past the antimeridian', () {
      for (final t in instants) {
        for (final lon in const [
          0.0,
          -122.4194,
          151.2093,
          179.9999,
          -179.9999,
          360.0,
          -400.0,
        ]) {
          final lst = AstronomyCalculations.localSiderealTime(t, lon);
          expect(lst, greaterThanOrEqualTo(0.0), reason: 't=$t lon=$lon');
          expect(lst, lessThan(24.0), reason: 't=$t lon=$lon');
        }
      }
    });

    test('LST at longitude 0 is GMST', () {
      for (final t in instants) {
        expect(
          AstronomyCalculations.localSiderealTime(t, 0.0),
          equals(AstronomyCalculations.greenwichMeanSiderealTime(t)),
        );
      }
    });
  });
}
