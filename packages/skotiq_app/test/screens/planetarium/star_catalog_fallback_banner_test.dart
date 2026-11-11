// The planetarium falls back to a ~79-star built-in list whenever no HYG catalog
// file is on disk — a catalog rename can orphan an existing install. That state
// has to ANNOUNCE itself: silently, the sky just loses almost every star.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/planetarium/widgets/star_catalog_fallback_banner.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_astro/skotiq_astro.dart' show HygStarCatalog;
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _BackendNotifier extends BackendNotifier {
  _BackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

Widget _host({required bool onFallback, SkotiqBackend? backend}) {
  return ProviderScope(
    overrides: [
      if (backend != null)
        backendProvider.overrideWith((ref) => _BackendNotifier(ref, backend)),
      starCatalogFallbackProvider.overrideWithValue(onFallback),
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
    expect(
        find.textContaining(
          '${HygStarCatalog.fallbackStarCount}-star built-in list',
        ),
        findsOneWidget);
    expect(find.text('Install'), findsOneWidget);
  });

  // SY-07: a fresh linked client showed this banner with nothing saying the
  // sky is this computer's, not the host's.
  testWidgets('a linked client says the sky is this computer\'s', (
    tester,
  ) async {
    final backend = _MockNetworkBackend();
    when(() => backend.serverHost).thenReturn('192.168.1.100');
    await tester.pumpWidget(_host(onFallback: true, backend: backend));
    await tester.pump();

    expect(
      find.text('Star catalog not installed on this computer'),
      findsOneWidget,
    );
    expect(
      find.textContaining('not from the imaging host (192.168.1.100)'),
      findsOneWidget,
    );
    expect(
        find.textContaining(
          '${HygStarCatalog.fallbackStarCount}-star built-in list',
        ),
        findsOneWidget);
    expect(find.text('Install here'), findsOneWidget);
  });

  testWidgets('stays out of the way once a real catalog is installed', (
    tester,
  ) async {
    await tester.pumpWidget(_host(onFallback: false));
    await tester.pump();

    expect(find.byType(SkotiqAlert), findsNothing);
  });
}
