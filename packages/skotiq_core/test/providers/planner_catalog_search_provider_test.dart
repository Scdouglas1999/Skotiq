import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import '../harness/in_memory_database.dart';

TargetSuggestion _suggestion({
  required int id,
  required String name,
  String? catalogId,
}) {
  return TargetSuggestion(
    targetId: id,
    targetName: name,
    catalogId: catalogId,
    raHours: 0.7,
    decDegrees: 41.3,
    totalScore: 88.0,
    visibility: const TargetVisibilityInfo(
      currentAltitude: 45.0,
      currentAzimuth: 180.0,
      airmass: 1.2,
      moonDistance: 90.0,
      peakAltitude: 60.0,
      hoursAboveMinAlt: 6.0,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const openNgcHeader =
      'Name;Type;RA;Dec;Const;MajAx;MinAx;PosAng;B-Mag;V-Mag;J-Mag;H-Mag;K-Mag;SurfBr;Hubble;Pax;Pm-RA;Pm-Dec;RadVel;Redshift;Cstar U-Mag;Cstar B-Mag;Cstar V-Mag;M;NGC;IC;Cstar Names;Identifiers;Common names;NED notes;OpenNGC notes;Sources';

  test(
    'planner installed-catalog search finds local catalog matches excluded from tonight suggestions',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'planner_catalog_search_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      await CatalogManager.instance.initialize(tempDir.path);
      await File(CatalogManager.instance.dsoCatalogPath).writeAsString(
        [
          openNgcHeader,
          'NGC1976;Cl+N;05:35:16.48;-05:23:22.8;Ori;90.00;60.00;;4.00;4.00;;;;;;;1.670;-0.300;28;0.000093;;;;042;;;;LBN 974,MWSC 0582;Great Orion Nebula,Orion Nebula;;;test',
        ].join('\n'),
      );

      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          tonightSuggestionsProvider.overrideWith(
            (ref) async => [
              _suggestion(id: 1, name: 'M31 Andromeda', catalogId: 'M31'),
            ],
          ),
        ],
      );
      addTearDown(container.dispose);

      final provider = plannerInstalledCatalogSearchProvider('M42');
      final sub = container.listen(provider, (_, __) {});
      addTearDown(sub.close);
      final results = await container.read(provider.future);

      expect(results, hasLength(1));
      expect(results.single.name, 'M42');
      expect(results.single.catalogId, 'NGC1976');
    },
  );

  test(
    'planner installed-catalog search normalizes Messier NGC IC HIP and HD identifiers',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'planner_catalog_search_ids_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      await CatalogManager.instance.initialize(tempDir.path);
      await File(CatalogManager.instance.dsoCatalogPath).writeAsString(
        [
          openNgcHeader,
          'NGC0001;G;00:07:15.84;+27:42:29.1;Peg;1.55;1.07;112;13.65;12.90;;;;;;;;;;;;;;;;;;;;;;;;;;test',
          'IC0410;EmN;05:22:39.00;+33:31:00.0;Aur;40.00;30.00;;;;;;;;;;;;;;;410;;;Tadpole Nebula;;;test',
          'NGC1976;Cl+N;05:35:16.48;-05:23:22.8;Ori;90.00;60.00;;4.00;4.00;;;;;;;1.670;-0.300;28;0.000093;;;;042;;;;LBN 974,MWSC 0582;Great Orion Nebula,Orion Nebula;;;test',
        ].join('\n'),
      );
      await File(CatalogManager.instance.starCatalogPath).writeAsString(
        [
          'id,hip,hd,hr,gl,bf,proper,ra,dec,dist,pmra,pmdec,rv,mag,absmag,spect,ci,x,y,z,vx,vy,vz,rarad,decrad,pmrarad,pmdecrad,bayer,flam,con,comp,comp_primary,base,lum,var,var_min,var_max',
          '1,91262,172167,7001,,,"Vega",18.615649,38.783689,7.68,0,0,0,0.03,0.58,A0V,0.0,0,0,0,0,0,0,0,0,0,0,alp,3,Lyr,1,1,1,40,0,0,0',
        ].join('\n'),
      );

      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          tonightSuggestionsProvider.overrideWith((ref) async => const []),
        ],
      );
      addTearDown(container.dispose);

      Future<List<CatalogSearchResult>> search(String query) async {
        final provider = plannerInstalledCatalogSearchProvider(query);
        final sub = container.listen(provider, (_, __) {});
        addTearDown(sub.close);
        return container.read(provider.future);
      }

      expect((await search('M 42')).single.name, 'M42');
      expect((await search('NGC 1')).first.catalogId, 'NGC0001');
      expect((await search('NGC0001')).first.catalogId, 'NGC0001');
      expect((await search('IC 410')).single.catalogId, 'IC0410');
      expect((await search('IC0410')).single.catalogId, 'IC0410');
      expect((await search('HIP 91262')).single.name, 'Vega');
      expect((await search('HD 172167')).single.name, 'Vega');
    },
  );
}
