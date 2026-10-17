// Drift guard for the two catalog subsystems that currently coexist:
//   * the legacy per-type API (CatalogSource constants in source_models.dart),
//     used by the desktop/mobile CatalogSettingsScreen, and
//   * the unified name-based API (CatalogManager.knownCatalogs), used by the
//     headless /api/catalog surface.
//
// Both hardcode the same fileName / downloadUrl / version per catalog. If they
// silently diverge, the UI and the REST API would disagree about where a
// catalog lives or what URL to fetch. This test fails loudly the moment they
// drift, so a single edit can't leave the two halves inconsistent.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

void main() {
  group('legacy CatalogSource ↔ unified knownCatalogs consistency', () {
    test('stars descriptor matches hygStarCatalog', () {
      final d = CatalogManager.knownCatalogs['stars']!;
      expect(d.fileName, hygStarCatalog.fileName);
      expect(d.downloadUrl, hygStarCatalog.downloadUrl);
      expect(d.version, hygStarCatalog.version);
      // The HYG source is the gzipped one; keep the unified flag honest.
      expect(d.isGzipped, hygStarCatalog.downloadUrl.endsWith('.gz'));
    });

    test('dso descriptor matches openNgcCatalog', () {
      final d = CatalogManager.knownCatalogs['dso']!;
      expect(d.fileName, openNgcCatalog.fileName);
      expect(d.downloadUrl, openNgcCatalog.downloadUrl);
      expect(d.version, openNgcCatalog.version);
      expect(d.isGzipped, openNgcCatalog.downloadUrl.endsWith('.gz'));
    });

    test('annotation descriptor matches gladePlusCatalog', () {
      final d = CatalogManager.knownCatalogs['annotation']!;
      expect(d.fileName, gladePlusCatalog.fileName);
      // GLADE+ builds its URL dynamically per tier, so both sides record it as
      // empty — assert that invariant rather than a concrete URL.
      expect(d.downloadUrl, isEmpty);
      expect(gladePlusCatalog.downloadUrl, isEmpty);
      expect(d.version, gladePlusCatalog.version);
    });

    test(
      'metadata sidecar names follow the "{key}_metadata.json" convention',
      () {
        for (final entry in CatalogManager.knownCatalogs.entries) {
          expect(entry.value.metadataFileName, '${entry.key}_metadata.json');
        }
      },
    );
  });
}
