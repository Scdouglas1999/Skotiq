// The catalog download offered three tiers that were the same download.
//
// Walked from an empty catalog directory on a fresh install: downloading
// "Essential (~10 MB, ~9,000 stars)" and then "Standard (~30 MB, ~40,000
// stars)" produced BYTE-IDENTICAL files — same SHA-256, 119,614 stars either
// way — because `_downloadCatalog` fetches `hygStarCatalog` / `openNgcCatalog`
// regardless of the `package` argument, which only ever reaches `_saveMetadata`
// as a label. The settings card then read that label back and printed
// "Depth mag <= 6.5" or "mag <= 8.0" for the very same bytes.
//
// The honest fix was to stop offering a choice that does not exist rather than
// invent three datasets. These tests pin that: one dataset, one set of figures,
// and no variant may claim a depth the shipped HYG file cannot deliver.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

void main() {
  test('every package variant describes the same installed dataset', () {
    for (final package in CatalogPackage.values) {
      expect(
        package.starMagnitudeLimit,
        kHygFaintFloorMag,
        reason:
            '${package.name} states a star depth the one installed file '
            'does not have',
      );
      expect(
        package.approximateStarCount,
        kInstalledStarApproxCount,
        reason: '${package.name} advertises a star count no download delivers',
      );
      expect(
        package.approximateDsoCount,
        kInstalledDsoApproxCount,
        reason: '${package.name} advertises a DSO count no download delivers',
      );
      expect(
        package.approximateSizeMB,
        kInstalledCatalogApproxSizeMB,
        reason:
            '${package.name} advertises a download size that is not the '
            'size of the one download',
      );
      expect(
        package.dsoMagnitudeLimit,
        kInstalledDsoDepthMag,
        reason: '${package.name} states a DSO bound the one file does not have',
      );
      expect(
        package.description,
        kInstalledCatalogDescription,
        reason:
            '${package.name} describes itself as something other than the '
            'one dataset it installs',
      );
    }
  });

  test('no variant claims a depth HYG cannot deliver', () {
    // The pre-fix figures, kept here by value so re-introducing any of them is
    // a test failure and not a review question.
    const fabricated = <double>[6.5, 8.0, 11.5, 15.0];
    for (final package in CatalogPackage.values) {
      expect(
        fabricated.contains(package.starMagnitudeLimit),
        isFalse,
        reason: '${package.name} is back to a fabricated depth',
      );
      expect(package.starMagnitudeLimit, lessThanOrEqualTo(kHygFaintFloorMag));
    }
  });

  test('the star and DSO catalogs each resolve to one asset', () {
    // The premise of the whole fix: there is nothing per-tier to download.
    // `catalogDownloadCandidates` is a mirror list for ONE asset (GitHub
    // release first, third-party upstream as fallback), not a set of
    // alternative datasets, and it takes no package argument to vary on.
    for (final source in [hygStarCatalog, openNgcCatalog]) {
      final candidates = resolveCatalogDownloadCandidates(
        source,
        baseUrl: kCatalogReleaseBaseUrl,
      );
      expect(candidates, isNotEmpty);
      // Every candidate ends in the same file name — they are mirrors of one
      // asset, so whichever is reached the installed bytes are the same.
      for (final url in candidates) {
        expect(
          url,
          contains(source.githubAssetName),
          reason:
              'a candidate for ${source.name} points at different data, '
              'which would make the installed catalog depend on which mirror '
              'answered',
        );
      }
    }
  });
}
