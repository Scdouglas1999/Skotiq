// The filter rule on the shipped catalog data: OpenNGC with the nebula light
// table, as the app loads it. Reflection nebulae OpenNGC files as plain
// nebulae plan LRGB; emission nebulae plan narrowband.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';

/// The owner's wheel (profile "10\" Newt", ZWO EFW, 8 slots).
const _ownerWheel = ['L', 'R', 'G', 'B', 'Ha', 'SII', 'OIII', 'DARK'];

void main() {
  late List<DeepSkyObject> objects;

  setUpAll(() async {
    // flutter test runs in the package root.
    objects = await OpenNgcDsoCatalog(
      'assets/catalogs/NGC.csv',
      nebulaLight: parseNebulaLightTable(
        File('assets/catalogs/nebula_light.csv').readAsStringSync(),
      ),
    ).load();
  });

  SmartNightStrategy strategyFor(String designation) {
    final dso = objects.firstWhere(
      (o) => o.id == designation || o.catalogIds.contains(designation),
    );
    return chooseSmartNightFilters(
      target: TargetSuggestion(
        targetId: dso.id.hashCode,
        targetName: designation,
        raHours: dso.coordinates.ra,
        decDegrees: dso.coordinates.dec,
        totalScore: 90,
        objectType: dso.type.displayName,
        visibility: const TargetVisibilityInfo(
          currentAltitude: 55,
          currentAzimuth: 111,
          airmass: 1.2,
          moonDistance: 90,
        ),
      ),
      availableFilters: _ownerWheel,
    ).strategy;
  }

  test('reflection nebulae OpenNGC files as "Neb" or "Cl+N" plan LRGB', () {
    for (final designation in ['NGC1333', 'IC348', 'NGC1435', 'NGC7023']) {
      expect(
        strategyFor(designation),
        SmartNightStrategy.autoLrgb,
        reason: designation,
      );
    }
  });

  test('emission nebulae and the Crab plan narrowband', () {
    for (final designation in ['M42', 'M8', 'M16', 'M17', 'M20', 'M1']) {
      expect(
        strategyFor(designation),
        SmartNightStrategy.narrowbandSho,
        reason: designation,
      );
    }
  });

  test('a reflection nebula OpenNGC types as one stays LRGB', () {
    expect(strategyFor('M78'), SmartNightStrategy.autoLrgb);
  });
}
