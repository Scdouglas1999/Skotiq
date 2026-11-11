// The palette's field reads "Search targets, settings, or jump to a screen",
// so typing a catalog designation or a star's name has to list that object.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/router/app_routes.dart';
import 'package:skotiq_app/screens/planner/planner_route.dart';
import 'package:skotiq_app/screens/planetarium/show_in_sky.dart';
import 'package:skotiq_app/widgets/command_palette/command_palette.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_astro/skotiq_astro.dart';

import '../harness/harness.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

const _m31 = DeepSkyObject(
  id: 'NGC224',
  name: 'M31',
  coordinates: CelestialCoordinate(ra: 0.7123, dec: 41.269),
  type: DsoType.galaxy,
  magnitude: 3.44,
  catalogIds: ['UGC 00454', 'M31'],
  commonNames: 'Andromeda Galaxy',
);
const _ngc891 = DeepSkyObject(
  id: 'NGC891',
  name: 'NGC891',
  coordinates: CelestialCoordinate(ra: 2.3757, dec: 42.349),
  type: DsoType.galaxy,
  magnitude: 9.9,
);
const _vega = Star(
  id: 'HIP91262',
  name: 'Vega',
  coordinates: CelestialCoordinate(ra: 18.6156, dec: 38.7837),
  magnitude: 0.03,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpPalette(WidgetTester tester) async {
    await pumpAppScreen(
      tester,
      const CommandPalette(),
      size: const Size(1920, 1080),
      extraOverrides: <Override>[
        loadedDsosProvider.overrideWith((ref) async => const [_m31, _ngc891]),
        loadedStarsProvider.overrideWith((ref) async => const [_vega]),
      ],
    );
  }

  Future<void> search(WidgetTester tester, String query) async {
    await tester.enterText(find.byType(TextField), query);
    await tester.pump();
  }

  testWidgets('a Messier number lists the object', (tester) async {
    await pumpPalette(tester);
    await search(tester, 'M31');
    expect(find.text('M31 (NGC224) · Andromeda Galaxy'), findsOneWidget);
    expect(find.textContaining('Nothing matches'), findsNothing);
  });

  testWidgets('a designation typed with a space lists the object',
      (tester) async {
    await pumpPalette(tester);
    await search(tester, 'NGC 891');
    expect(find.text('NGC891'), findsOneWidget);
  });

  testWidgets('a star name lists the star', (tester) async {
    await pumpPalette(tester);
    await search(tester, 'Vega');
    // The field holds "Vega" too; the row is the one with the Framing hint.
    expect(find.textContaining('Open in Framing'), findsOneWidget);
  });

  testWidgets('on the Planetarium tab, Enter centers the sky on the target',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1600, 1000);
    addTearDown(tester.view.reset);
    Widget page(String name) => Builder(
          builder: (context) => Scaffold(
            body: Column(
              children: [
                Text('page $name'),
                TextButton(
                  onPressed: () => showCommandPalette(context),
                  child: const Text('search'),
                ),
              ],
            ),
          ),
        );
    final router = GoRouter(
      initialLocation: '/planner',
      routes: [
        GoRoute(
          path: '/planner',
          name: 'planner',
          builder: (_, __) => page('planner'),
        ),
        GoRoute(path: '/planetarium', builder: (_, __) => page('sky')),
        GoRoute(path: '/framing', builder: (_, __) => page('framing')),
      ],
    );
    addTearDown(router.dispose);
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        loadedDsosProvider.overrideWith((ref) async => const [_m31, _ngc891]),
        loadedStarsProvider.overrideWith((ref) async => const [_vega]),
        plannerShowsSkyProvider.overrideWith((ref) => true),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: SkotiqTheme.dark,
          routerConfig: router,
        ),
      ),
    );
    await tester.tap(find.text('search'));
    await tester.pumpAndSettle();
    await search(tester, 'M31');
    await tester.pump();
    expect(find.textContaining('Show in sky'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    final location = router.routerDelegate.currentConfiguration.uri;
    expect(location.path, AppRoute.planner.path);
    expect(location.queryParameters['tab'], PlannerTab.planetarium.word);
    final selected = container.read(selectedObjectProvider).coordinates;
    expect(selected?.ra, closeTo(0.7123, 1e-6));
    expect(selected?.dec, closeTo(41.269, 1e-6));

    // The sky clock ticks until its container goes, and drift closes its
    // query streams on a timer due now (see settleProviderTeardown).
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await tester.pump(const Duration(milliseconds: 1));
  });
}
