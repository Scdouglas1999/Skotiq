// The v42 -> v44 HYG rename.
//
// The expected star-catalog filename is hyg_v44.csv, but installs made before
// the rename still have hyg_v42.csv on disk. A legacy name honoured only by the
// delete path leaves an upgraded install silently reporting "not installed" and
// drops the planetarium to the 79-star fallback list.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

String _miniHygCsv() {
  final cols = List<String>.filled(30, '');
  cols[0] = '1';
  cols[1] = '11767';
  cols[6] = 'Polaris';
  cols[7] = '2.530';
  cols[8] = '89.264';
  cols[13] = '1.98';
  cols[15] = 'F7Ib';
  cols[29] = 'UMi';
  return 'header\n${cols.join(',')}\n';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('legacy hyg_v42.csv install', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('sk_catalog_v42_');
      await CatalogManager.instance.initialize(tempDir.path);
      await File('${tempDir.path}/hyg_v42.csv').writeAsString(_miniHygCsv());
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('is reported as installed', () async {
      final status = await CatalogManager.instance.getStarCatalogStatus();
      expect(status.isInstalled, isTrue);
      expect(status.installedPath, endsWith('hyg_v42.csv'));
    });

    test('is the path the star catalog loads from', () async {
      expect(CatalogManager.instance.starCatalogPath, endsWith('hyg_v42.csv'));

      final catalog = HygStarCatalog();
      final stars = await catalog.loadObjects();
      expect(catalog.isUsingFallback, isFalse);
      expect(stars, hasLength(1));
      expect(stars.single.name, 'Polaris');
    });

    test('is removed once the current-name catalog is installed', () async {
      final src = await Directory.systemTemp.createTemp('sk_v44_src_');
      addTearDown(() async {
        if (await src.exists()) await src.delete(recursive: true);
      });
      final srcFile = File('${src.path}/stars.csv');
      await srcFile.writeAsString(_miniHygCsv());

      final ok = await CatalogManager.instance.importCatalog(
        sourcePath: srcFile.path,
        type: 'stars',
      );
      expect(ok, isTrue);

      expect(await File('${tempDir.path}/hyg_v44.csv').exists(), isTrue);
      expect(await File('${tempDir.path}/hyg_v42.csv').exists(), isFalse);
      expect(CatalogManager.instance.starCatalogPath, endsWith('hyg_v44.csv'));
    });
  });

  group('no star catalog installed', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('sk_catalog_none_');
      await CatalogManager.instance.initialize(tempDir.path);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('the fallback list is flagged so the UI can warn', () async {
      final catalog = HygStarCatalog();
      final stars = await catalog.loadObjects();
      expect(stars, isNotEmpty);
      expect(catalog.isUsingFallback, isTrue);
    });
  });
}
