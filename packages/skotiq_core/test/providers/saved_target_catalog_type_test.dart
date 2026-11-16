// A saved target reads its object type from the installed catalog by its
// catalog identity, so a target saved before the catalog classed a nebula
// plans by the class the catalog gives it now.

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

import '../harness/in_memory_database.dart';

const _ownerWheel = ['L', 'R', 'G', 'B', 'Ha', 'SII', 'OIII', 'DARK'];

SmartNightStrategy _plannedSet(DbTarget target) => chooseSmartNightFilters(
  target: TargetSuggestion(
    targetId: target.id,
    targetName: target.name,
    catalogId: target.catalogId,
    raHours: target.ra,
    decDegrees: target.dec,
    totalScore: 90,
    objectType: target.objectType,
    visibility: const TargetVisibilityInfo(
      currentAltitude: 55,
      currentAzimuth: 111,
      airmass: 1.2,
      moonDistance: 90,
    ),
  ),
  availableFilters: _ownerWheel,
).strategy;

void main() {
  setUpAll(() async {
    final dir = await Directory.systemTemp.createTemp('saved_target_type_');
    addTearDown(() => dir.delete(recursive: true));
    // flutter test runs in the package root.
    await CatalogManager.instance.initialize(
      dir.path,
      nebulaLight: () =>
          File('assets/catalogs/nebula_light.csv').readAsString(),
    );
    await File(
      'assets/catalogs/NGC.csv',
    ).copy(CatalogManager.instance.pathOf(SkyCatalog.dso));
  });

  Future<List<DbTarget>> savedTargets(List<TargetsCompanion> rows) async {
    final container = ProviderContainer(
      overrides: [inMemoryDatabaseOverride()],
    );
    addTearDown(container.dispose);
    final dao = container.read(databaseProvider).targetsDao;
    for (final row in rows) {
      await dao.createTarget(row);
    }
    final sub = container.listen(allDbTargetsProvider, (_, _) {});
    addTearDown(sub.close);
    return container.read(allDbTargetsProvider.future);
  }

  test(
    'NGC 1333 saved as "Neb" reads its catalog class and plans LRGB',
    () async {
      final [target] = await savedTargets([
        TargetsCompanion.insert(
          name: 'NGC 1333',
          catalogId: const Value('NGC1333'),
          objectType: const Value('Neb'),
          ra: 3.482,
          dec: 31.37,
        ),
      ]);

      expect(target.objectType, 'Cluster + Reflection Nebula');
      expect(_plannedSet(target), SmartNightStrategy.autoLrgb);
    },
  );

  test('a catalog id in another catalog, or a designation as the name, '
      'identifies the target', () async {
    final [iris, orion] = await savedTargets([
      TargetsCompanion.insert(
        name: 'Iris Nebula',
        catalogId: const Value('C 004'),
        objectType: const Value('Nebula'),
        ra: 21.026,
        dec: 68.17,
      ),
      TargetsCompanion.insert(
        name: 'M42',
        objectType: const Value('Galaxy'),
        ra: 5.588,
        dec: -5.39,
      ),
    ]);

    expect(iris.objectType, 'Reflection Nebula');
    expect(_plannedSet(iris), SmartNightStrategy.autoLrgb);
    expect(orion.objectType, 'Cluster + Emission Nebula');
    expect(_plannedSet(orion), SmartNightStrategy.narrowbandSho);
  });

  test('a target no designation identifies keeps its stored type', () async {
    final targets = await savedTargets([
      TargetsCompanion.insert(
        name: 'My comet field',
        objectType: const Value('Emission Nebula'),
        ra: 3.482,
        dec: 31.37,
      ),
      TargetsCompanion.insert(
        name: 'Heart mosaic - Panel 2',
        objectType: const Value('mosaic-panel'),
        ra: 2.55,
        dec: 61.45,
      ),
    ]);

    expect(targets.map((t) => t.objectType), [
      'Emission Nebula',
      'mosaic-panel',
    ]);
  });
}
