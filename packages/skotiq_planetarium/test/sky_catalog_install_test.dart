// The one install of the star and deep-sky catalogs that first-run setup, the
// planner and Settings > Catalogs all start and all show.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

DownloadProgress _at(SkyCatalog catalog, double progress) => DownloadProgress(
  catalog: catalog,
  progress: progress,
  bytesReceived: 0,
  totalBytes: 0,
  status: 'Downloading ${catalog.displayName}',
);

void main() {
  test(
    'installs stars then deep-sky objects, reporting overall progress',
    () async {
      final installed = <SkyCatalog>[];
      final seen = <double>[];
      final notifier = SkyCatalogInstallNotifier((
        catalog, {
        onProgress,
        isCancelled,
      }) async {
        onProgress?.call(_at(catalog, 0.5));
        installed.add(catalog);
        return null;
      });
      notifier.addListener((s) => seen.add(s.progress), fireImmediately: false);

      final result = await notifier.start();

      expect(installed, [SkyCatalog.stars, SkyCatalog.dso]);
      expect(result.phase, SkyCatalogInstallPhase.done);
      expect(seen, containsAllInOrder([0.25, 0.75, 1.0]));
    },
  );

  test('a failed download keeps its reason and can be tried again', () async {
    var attempts = 0;
    final notifier = SkyCatalogInstallNotifier((
      catalog, {
      onProgress,
      isCancelled,
    }) async {
      attempts++;
      if (attempts == 1) {
        throw const CatalogDownloadException(
          phase: 'download',
          message: 'Could not reach github.com or codeberg.org.',
        );
      }
      return null;
    });

    final failed = await notifier.start();
    expect(failed.phase, SkyCatalogInstallPhase.failed);
    expect('${failed.error}', 'Could not reach github.com or codeberg.org.');

    final retried = await notifier.start();
    expect(retried.phase, SkyCatalogInstallPhase.done);
  });

  test('a cancel returns to the offer, not to an error', () async {
    late SkyCatalogInstallNotifier notifier;
    notifier = SkyCatalogInstallNotifier((
      catalog, {
      onProgress,
      isCancelled,
    }) async {
      notifier.cancel();
      if (await isCancelled!()) throw const CatalogCancelled();
      return null;
    });

    final result = await notifier.start();

    expect(result.phase, SkyCatalogInstallPhase.idle);
    expect(result.error, isNull);
  });
}
