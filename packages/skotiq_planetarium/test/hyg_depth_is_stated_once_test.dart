// The app states ONE depth for the bundled star catalog.
//
// Three surfaces quote it: reached from the planetarium's Layers panel > Deep
// stars > Install, the Catalog Settings sheet describes the installed HYG Star
// Database ("119.6k objects, 32.4 MB, Version 4.2, Package Complete, Depth
// mag <= 15.0"), two cards further down the Deep-Star Tier card names the same
// catalog's floor, and the Layers panel says which stars are unavailable. 15.0
// is the LOADER'S inclusion filter mislabelled "Depth"; counting the shipped
// file (119,626 rows) the per-magnitude gain turns over after 9. "Package:
// Complete" beside "Depth: mag <= 15.0" tells the user that the nearly-empty
// field at an imaging FOV is the real sky.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

void main() {
  test('the catalog-package depth chip quotes HYG\'s real completeness', () {
    expect(CatalogPackage.complete.starMagnitudeLimit, kHygFaintFloorMag);
    expect(kHygFaintFloorMag, 9.0);
  });

  test('nothing claims the old 15.0 or 11.5 depth', () {
    for (final package in CatalogPackage.values) {
      expect(
        package.starMagnitudeLimit,
        lessThanOrEqualTo(kHygFaintFloorMag),
        reason: '${package.name} claims a depth HYG cannot deliver',
      );
    }
  });
}
