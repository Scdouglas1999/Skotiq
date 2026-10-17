// The planetarium falls back to a ~79-star built-in list whenever no HYG catalog
// file is on disk — a catalog rename can orphan an existing install. That state
// has to ANNOUNCE itself: silently, the sky just loses almost every star.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/planetarium/widgets/star_catalog_fallback_banner.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Widget _host({required bool onFallback}) {
  return ProviderScope(
    overrides: [
      starCatalogFallbackProvider.overrideWithValue(onFallback),
      fallbackStarCountProvider.overrideWithValue(79),
    ],
    child: MaterialApp(
      theme: ThemeData(extensions: const [SkotiqColors.dark]),
      home: const Scaffold(body: StarCatalogFallbackBanner()),
    ),
  );
}

void main() {
  testWidgets('warns when the sky is the built-in fallback list', (
    tester,
  ) async {
    await tester.pumpWidget(_host(onFallback: true));
    await tester.pump();

    expect(find.text('Star catalog not installed'), findsOneWidget);
    expect(find.textContaining('79-star built-in list'), findsOneWidget);
    expect(find.text('Install'), findsOneWidget);
  });

  testWidgets('stays out of the way once a real catalog is installed', (
    tester,
  ) async {
    await tester.pumpWidget(_host(onFallback: false));
    await tester.pump();

    expect(find.byType(SkotiqAlert), findsNothing);
  });
}
