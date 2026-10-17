// The Catalog Settings "Depth" chip is what a user reads to judge the catalog —
// "119.6k objects, 32.4 MB, Version 4.2, Package Complete, Depth mag <= 15.0"
// beside a green "Installed" badge. 15.0 is the HYG loader's inclusion filter,
// not the catalog's completeness; printed as "Depth" next to "Package: Complete"
// it tells the user the nearly-empty field at an imaging FOV is the real sky.
//
// The sibling unit test pins CatalogPackage.complete.starMagnitudeLimit to
// kHygFaintFloorMag, but that alone does not prove the CHIP quotes it — a
// hard-coded string in card_builders.dart would keep that test green. This test
// renders the real screen over a real installed-catalog fixture and reads the
// chip.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/catalog_settings_screen.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:path/path.dart' as p;

import '../../harness/harness.dart';

Future<void> _settleCatalogLoad(WidgetTester tester) async {
  for (var attempt = 0; attempt < 20; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    if (find.text('DEPTH').evaluate().isNotEmpty) return;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory catalogDirectory;

  setUp(() async {
    catalogDirectory = await Directory.systemTemp.createTemp(
      'skotiq_catalog_depth_chip_',
    );
    // Minimum fixture CatalogManager reports as an installed "Complete"
    // package: a non-empty catalog file plus its metadata sidecar.
    await File(p.join(catalogDirectory.path, hygStarCatalog.fileName))
        .writeAsString('id,proper,ra,dec,mag\n1,Fixture,0,0,1.0\n');
    await File(p.join(catalogDirectory.path, 'stars_metadata.json'))
        .writeAsString(jsonEncode({
      'package': CatalogPackage.complete.name,
      'version': '4.2',
      'objectCount': 119626,
      'installedDate': DateTime(2026, 8, 3).toIso8601String(),
    }));
    await CatalogManager.instance.initialize(catalogDirectory.path);
  });

  tearDown(() async {
    if (catalogDirectory.existsSync()) {
      await catalogDirectory.delete(recursive: true);
    }
  });

  testWidgets(
      'the installed star catalog reports HYG completeness as its depth',
      (tester) async {
    await pumpAppScreen(
      tester,
      const CatalogSettingsScreen(),
      size: const Size(1400, 1400),
      settle: false,
    );
    await _settleCatalogLoad(tester);

    expect(find.text('DEPTH'), findsWidgets);
    expect(
      find.text('mag ≤ ${kHygFaintFloorMag.toStringAsFixed(1)}'),
      findsOneWidget,
    );
    // The loader's inclusion filter must never be presented as the depth.
    expect(find.text('mag ≤ 15.0'), findsNothing);
  });
}
