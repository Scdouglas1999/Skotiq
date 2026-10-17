// The RA unit contract of the star catalog.
//
// [CelestialCoordinate.ra] is HOURS (see coordinate_system.dart) and every
// consumer multiplies by 15 to reach degrees, so storing DEGREES in that field
// — in the HYG parser or the built-in fallback list — moves every star by a
// factor of 15 in hour angle.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/src/catalogs/star_catalog.dart';
import 'package:skotiq_planetarium/src/coordinate_system.dart';

/// Known J2000 right ascensions in HOURS.
const _knownRaHours = <String, double>{
  'Arcturus': 14.261,
  'Aldebaran': 4.599,
  'Alphard': 9.460,
  'Alhena': 6.629,
  'Capella': 5.278,
  'Polaris': 2.530,
};

String _hygLine({
  required String proper,
  required String raHours,
  required String dec,
}) {
  final cols = List<String>.filled(30, '');
  cols[0] = '1';
  cols[1] = '11767';
  cols[2] = '8890';
  cols[3] = '424';
  cols[6] = proper;
  cols[7] = raHours;
  cols[8] = dec;
  cols[9] = '100';
  cols[10] = '0';
  cols[11] = '0';
  cols[12] = '0';
  cols[13] = '1.98';
  cols[14] = '-3.6';
  cols[15] = 'F7Ib';
  cols[16] = '0.636';
  cols[29] = 'UMi';
  return cols.join(',');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('fallback bright stars store RA in hours, not degrees', () async {
    final catalog = HygStarCatalog(
      catalogPath: '/nonexistent/skotiq_no_such_catalog.csv',
    );
    final stars = await catalog.loadObjects();
    expect(stars, isNotEmpty);

    for (final entry in _knownRaHours.entries) {
      final star = stars.firstWhere(
        (s) => s.name == entry.key,
        orElse: () => throw StateError('${entry.key} missing from fallback'),
      );
      expect(
        star.coordinates.ra,
        closeTo(entry.value, 0.01),
        reason: '${entry.key} RA must be hours',
      );
      expect(
        star.coordinates.raDegrees,
        closeTo(entry.value * 15, 0.2),
        reason: '${entry.key} RA in degrees must stay inside 0-360',
      );
    }

    for (final star in stars) {
      expect(
        star.coordinates.ra,
        inInclusiveRange(0, 24),
        reason: '${star.name} RA out of the 0-24h range',
      );
    }
  });

  test('HYG parser stores the CSV RA column in hours', () async {
    final dir = await Directory.systemTemp.createTemp('sk_hyg_units_');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    final file = File('${dir.path}/hyg_units.csv');
    await file.writeAsString(
      [
        'header',
        _hygLine(proper: 'Polaris', raHours: '2.530', dec: '89.264'),
        _hygLine(proper: 'Arcturus', raHours: '14.261', dec: '19.183'),
      ].join('\n'),
    );

    final stars = await HygStarCatalog(catalogPath: file.path).loadObjects();
    expect(stars, hasLength(2));

    final polaris = stars.firstWhere((s) => s.name == 'Polaris');
    expect(polaris.coordinates.ra, closeTo(2.530, 1e-6));
    final arcturus = stars.firstWhere((s) => s.name == 'Arcturus');
    expect(arcturus.coordinates.ra, closeTo(14.261, 1e-6));
  });

  test('the cone search takes hours in and degrees for the radius', () async {
    final catalog = HygStarCatalog(
      catalogPath: '/nonexistent/skotiq_no_such_catalog.csv',
    );

    // Aldebaran (4.599h, +16.51 deg) and Alhena (6.629h, +16.40 deg) are ~29
    // degrees apart on the sky: a 5-degree cone on one must not reach the other.
    const aldebaran = CelestialCoordinate(ra: 4.599, dec: 16.509);
    final near = await catalog.getStarsNear(aldebaran, 5);
    expect(near.map((s) => s.name), contains('Aldebaran'));
    expect(near.map((s) => s.name), isNot(contains('Alhena')));

    final wide = await catalog.getStarsNear(aldebaran, 35);
    expect(wide.map((s) => s.name), contains('Alhena'));
  });
}
