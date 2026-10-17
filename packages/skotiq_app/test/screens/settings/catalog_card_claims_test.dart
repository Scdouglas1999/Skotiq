// Two claims the installed-catalog card printed that were not true of the
// bytes on disk.
//
// 1. "Package Standard". The three download tiers were retired because they
//    were a placebo — Essential and Standard produced byte-identical files
//    (same SHA-256, same 119,614 rows). The chip kept reading the retired tier
//    off the legacy metadata sidecar, so every install wore a grade that could
//    no longer be chosen and never described anything.
//
// 2. "Update available" beside `Version 4.4` — the NEWEST asset the resolver
//    can fetch. The predicate was `installed != latestVersion` against a '4.2'
//    literal typed into the screen, which went stale when HYG rolled to v4.4.
//    A fresh install of the newest catalog advertised an update to a version
//    that no longer exists.
//
// Rendered against the real screen over a real installed-catalog fixture,
// because both defects lived in the presentation, not in the model.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/catalog_settings_screen.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:path/path.dart' as p;

import '../../harness/harness.dart';

late Directory _catalogDirectory;

Future<void> _installStarCatalog({required String version}) async {
  await File(p.join(_catalogDirectory.path, hygStarCatalog.fileName))
      .writeAsString('id,proper,ra,dec,mag\n1,Fixture,0,0,1.0\n');
  await File(p.join(_catalogDirectory.path, 'stars_metadata.json'))
      .writeAsString(jsonEncode({
    'package': CatalogPackage.standard.name,
    'version': version,
    'objectCount': 119614,
    'installedDate': DateTime(2026, 8, 11).toIso8601String(),
  }));
  await CatalogManager.instance.initialize(_catalogDirectory.path);
}

Future<void> _settleCatalogLoad(WidgetTester tester) async {
  for (var attempt = 0; attempt < 20; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    if (find.text('VERSION').evaluate().isNotEmpty) return;
  }
}

Future<void> _pumpCatalogs(WidgetTester tester) async {
  await pumpAppScreen(
    tester,
    const CatalogSettingsScreen(),
    size: const Size(1400, 1600),
    settle: false,
  );
  await _settleCatalogLoad(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    _catalogDirectory = await Directory.systemTemp.createTemp(
      'skotiq_catalog_card_claims_',
    );
  });

  tearDown(() async {
    if (_catalogDirectory.existsSync()) {
      await _catalogDirectory.delete(recursive: true);
    }
  });

  testWidgets('the installed card prints no download-tier grade',
      (tester) async {
    await tester
        .runAsync(() => _installStarCatalog(version: hygStarCatalog.version));
    await _pumpCatalogs(tester);

    // The card is up (it is printing the chips that ARE facts about the file).
    expect(find.text('VERSION'), findsWidgets);
    expect(find.text('OBJECTS'), findsWidgets);

    expect(find.text('PACKAGE'), findsNothing,
        reason: 'the download tier was retired; a grade that can no longer be '
            'chosen is not a fact about the install');
    // The chips that remain are the ones the sidecar and the file can back:
    // a measured count, a measured size, the dataset version and the install
    // date. (A bare `find.text('Standard')` is not the assertion to make here:
    // the same screen renders an unrelated download-status word, so the chip
    // LABEL is what identifies the claim.)
    expect(find.text('SIZE'), findsWidgets);
    expect(find.text('Installed'), findsWidgets);
  });

  testWidgets('the newest fetchable catalog does not advertise an update',
      (tester) async {
    await tester
        .runAsync(() => _installStarCatalog(version: hygStarCatalog.version));
    await _pumpCatalogs(tester);

    expect(find.text(hygStarCatalog.version), findsWidgets);
    expect(find.text('Update available'), findsNothing,
        reason: 'the installed version IS the newest the resolver can fetch');
  });

  testWidgets('a genuinely older install still advertises the update',
      (tester) async {
    // The v42 asset HYG shipped before the v44 roll — still readable, and
    // really is superseded by what the resolver would download today.
    await tester.runAsync(() => _installStarCatalog(version: '4.2'));
    await _pumpCatalogs(tester);

    expect(find.text('4.2'), findsWidgets);
    expect(find.text('Update available'), findsOneWidget);
  });
}
