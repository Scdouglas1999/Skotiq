// Round-trip test for the unified catalog API: installFromFile
// → getInstalledStatuses → uninstall → getInstalledStatuses.
//
// We intentionally do NOT exercise the network-fetch path here because
// the upstream URLs (Codeberg LFS, raw.githubusercontent) would make
// the test flaky in CI. The download path's wiring is covered by the
// handler test in apps/desktop/test/headless_api/catalog_handlers_test.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

/// Minimal OpenNGC-shaped CSV so `_countObjects` returns a positive
/// number after install.
String _miniNgcCsvBody() {
  const header =
      'Name;Type;RA;Dec;Const;MajAx;MinAx;PosAng;B-Mag;V-Mag;J-Mag;H-Mag;K-Mag;'
      'SurfBr;Hubble;Pax;Pm-RA;Pm-Dec;RadVel;Redshift;Cstar U-Mag;Cstar B-Mag;'
      'Cstar V-Mag;M;NGC;IC;Cstar Names;Identifiers;Common names;NED notes;'
      'OpenNGC notes;Sources';
  const row =
      'NGC0001;G;00:07:15.84;+27:42:29.1;Peg;1.59;1.07;112;;13.4;;;;;Sb;;;;;;;;;;;;;;;;;';
  return '$header\n$row\n';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CatalogManager unified install API', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('ns_catalog_install_');
      await CatalogManager.instance.initialize(tempDir.path);
    });

    tearDown(() async {
      for (final name in CatalogManager.knownCatalogs.keys) {
        try {
          await CatalogManager.instance.uninstall(name);
        } catch (_) {
          // Best-effort.
        }
      }
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('installFromFile → status → uninstall round-trip', () async {
      final csv = _miniNgcCsvBody();
      final csvBytes = utf8.encode(csv);
      final expectedSha = sha256.convert(csvBytes).toString();
      final src = await Directory.systemTemp.createTemp('ns_src_inst_');
      final srcFile = File('${src.path}/source.csv');
      await srcFile.writeAsString(csv);

      // Install.
      final install = await CatalogManager.instance.installFromFile(
        name: 'dso',
        source: srcFile,
        expectedSha256: expectedSha,
      );
      expect(install.sha256, expectedSha);
      expect(install.sizeBytes, csvBytes.length);
      expect(install.objectCount, greaterThan(0));

      // Status reports installed.
      var statuses = await CatalogManager.instance.getInstalledStatuses();
      final dso = statuses.firstWhere((s) => s.name == 'dso');
      expect(dso.status, CatalogInstallStatus.installed);
      expect(dso.sizeBytes, csvBytes.length);
      expect(dso.expectedHash, expectedSha);

      // Verify finds OK.
      final verifyResult = await CatalogManager.instance.verify(name: 'dso');
      expect(verifyResult['dso']!.ok, isTrue);
      expect(verifyResult['dso']!.actualHash, expectedSha);

      // Uninstall.
      final removed = await CatalogManager.instance.uninstall('dso');
      expect(removed, isTrue);

      // Status now missing.
      statuses = await CatalogManager.instance.getInstalledStatuses();
      final dsoAfter = statuses.firstWhere((s) => s.name == 'dso');
      expect(dsoAfter.status, CatalogInstallStatus.missing);

      // Verify on uninstalled reports not_installed.
      final verifyAfter = await CatalogManager.instance.verify(name: 'dso');
      expect(verifyAfter['dso']!.ok, isFalse);
      expect(verifyAfter['dso']!.errors, contains('not_installed'));

      await src.delete(recursive: true);
    });

    test('installFromFile rejects mismatched expected sha', () async {
      final csv = _miniNgcCsvBody();
      final src = await Directory.systemTemp.createTemp('ns_src_mismatch_');
      final srcFile = File('${src.path}/source.csv');
      await srcFile.writeAsString(csv);

      await expectLater(
        () => CatalogManager.instance.installFromFile(
          name: 'dso',
          source: srcFile,
          expectedSha256: 'a' * 64,
        ),
        throwsA(isA<CatalogHashMismatchException>()),
      );

      await src.delete(recursive: true);
    });

    test('listAvailable returns the known catalog map', () async {
      final available = await CatalogManager.instance.listAvailable();
      expect(available.length, CatalogManager.knownCatalogs.length);
      expect(
        available.map((a) => a.name).toSet(),
        equals(CatalogManager.knownCatalogs.keys.toSet()),
      );
    });
  });
}
