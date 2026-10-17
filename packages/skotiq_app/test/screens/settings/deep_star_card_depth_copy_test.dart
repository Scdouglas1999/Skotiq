// The Deep-Star Tier card must quote the same HYG floor the HYG/deep-tier merge
// seam actually uses.
//
// A hard-coded "~mag 11.5" against a seam (kHygFaintFloorMag) of 9.0 that the
// Layers panel also reports leaves the settings sheet contradicting the running
// renderer about where the bundled catalog stops. The card must not call a
// self-hosted URL form an install either.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/deep_star_catalog_card.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

import '../../harness/pump_app_screen.dart';

void main() {
  late Directory catalogDir;

  setUp(() async {
    catalogDir = await Directory.systemTemp.createTemp('deep_star_card');
    await CatalogManager.instance.initialize(catalogDir.path);
  });

  tearDown(() async {
    if (catalogDir.existsSync()) await catalogDir.delete(recursive: true);
  });

  testWidgets('the card states the real HYG floor and that nothing is hosted',
      (tester) async {
    await pumpAppScreen(
      tester,
      const DeepStarCatalogCard(),
      size: const Size(700, 900),
      settle: false,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.textContaining('~mag 11.5'), findsNothing);
    expect(
      find.textContaining(
        'mag ${kHygFaintFloorMag.toStringAsFixed(1)}',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('No tileset is published yet'), findsOneWidget);
  });
}
