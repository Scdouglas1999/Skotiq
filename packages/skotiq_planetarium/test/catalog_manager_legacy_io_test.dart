// The legacy catalog IO path used by the desktop/mobile
// CatalogSettingsScreen: install-status reliability and crash-safe imports.
//
// A half-written (0-byte) catalog must not masquerade as installed, a failed
// import must not clobber a good existing catalog, and a successful install
// must report its on-disk size — the temp-file + atomic-rename path is what
// holds all three. The network download path is left to the handler tests (the
// upstream URLs would make CI flaky).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

String _miniHygCsv() {
  const header = 'id,hip,proper,ra,dec,mag,ci';
  const row = '1,11767,Polaris,2.529750,89.264109,1.97,0.636';
  return '$header\n$row\n';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CatalogManager legacy IO', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('sk_catalog_legacy_');
      await CatalogManager.instance.initialize(tempDir.path);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('zero-byte catalog file is not reported as installed', () async {
      // Simulate a download that was interrupted mid-write.
      await File(
        CatalogManager.instance.starCatalogPath,
      ).writeAsBytes(const []);

      final status = await CatalogManager.instance.getStarCatalogStatus();
      expect(status.isInstalled, isFalse);
    });

    test('successful import reports size and leaves no .partial', () async {
      final csv = _miniHygCsv();
      final src = await Directory.systemTemp.createTemp('sk_src_legacy_');
      final srcFile = File('${src.path}/stars.csv');
      await srcFile.writeAsString(csv);

      final ok = await CatalogManager.instance.importCatalog(
        sourcePath: srcFile.path,
        type: 'stars',
      );
      expect(ok, isTrue);

      final status = await CatalogManager.instance.getStarCatalogStatus();
      expect(status.isInstalled, isTrue);
      expect(status.fileSizeBytes, await srcFile.length());
      expect(status.objectCount, 1); // one data row past the header

      // The atomic-promote temp file must not be left behind.
      final partial = File(
        '${CatalogManager.instance.starCatalogPath}.partial',
      );
      expect(await partial.exists(), isFalse);

      await src.delete(recursive: true);
    });

    test('failed import does not clobber an existing catalog', () async {
      // Seed a good catalog first.
      final src = await Directory.systemTemp.createTemp('sk_src_good_');
      final goodFile = File('${src.path}/good.csv');
      await goodFile.writeAsString(_miniHygCsv());
      await CatalogManager.instance.importCatalog(
        sourcePath: goodFile.path,
        type: 'stars',
      );
      final goodSize = await File(
        CatalogManager.instance.starCatalogPath,
      ).length();

      // Now attempt to import an empty file — this must fail and preserve the
      // existing install rather than overwriting it with garbage.
      final emptyFile = File('${src.path}/empty.csv');
      await emptyFile.writeAsBytes(const []);
      final ok = await CatalogManager.instance.importCatalog(
        sourcePath: emptyFile.path,
        type: 'stars',
      );
      expect(ok, isFalse);

      final status = await CatalogManager.instance.getStarCatalogStatus();
      expect(status.isInstalled, isTrue);
      expect(status.fileSizeBytes, goodSize);

      await src.delete(recursive: true);
    });

    test('activeDownloads is empty when nothing is in flight', () {
      expect(CatalogManager.instance.activeDownloads, isEmpty);
      expect(CatalogManager.instance.isDownloading('stars'), isFalse);
    });

    test(
      'deleteCatalogs removes data and metadata for both legacy catalogs',
      () async {
        final files = [
          File(CatalogManager.instance.starCatalogPath),
          File(CatalogManager.instance.dsoCatalogPath),
          File('${tempDir.path}/stars_metadata.json'),
          File('${tempDir.path}/dso_metadata.json'),
        ];
        for (final file in files) {
          await file.writeAsString('installed');
        }

        await CatalogManager.instance.deleteCatalogs();

        for (final file in files) {
          expect(await file.exists(), isFalse, reason: file.path);
        }
      },
    );
  });
}
