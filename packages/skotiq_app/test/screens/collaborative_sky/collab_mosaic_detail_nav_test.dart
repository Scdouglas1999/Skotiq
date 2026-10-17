import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/screens/collaborative_sky/collab_mosaic_detail_screen.dart';
import 'package:skotiq_app/screens/collaborative_sky/collaborative_sky_providers.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The detail page is pushed imperatively over the app shell, so before this it
/// had no back control AND survived every nav-rail destination — the rail
/// repainted the new destination as selected while the mosaic stayed on screen.
const _mosaic = CollabMosaic(
  mosaicId: 'm1',
  ownerAccountId: 'owner',
  ownerDisplayName: 'Ada',
  name: 'M31 Wide Field',
  rows: 2,
  cols: 2,
  overlapPct: 15,
  positionAngleDeg: 0,
  centerRaDeg: 10.68,
  centerDecDeg: 41.27,
  status: 'open',
  outputPresent: false,
  panels: [],
);

late GoRouter _router;

/// Mirrors the shape that traps: a [ShellRoute] (the AppShell) plus a detail
/// pushed imperatively onto the ROOT navigator. The pushed route is then
/// anchored to the SHELL's page, which does not change when the rail moves
/// between shell destinations — so `context.go` swaps the content underneath a
/// route that stays on screen.
GoRouter _buildRouter() => GoRouter(
      initialLocation: '/collab',
      routes: [
        ShellRoute(
          builder: (context, state, child) => Scaffold(
            body: Column(
              children: [
                const Text('nav rail'),
                Expanded(child: child),
              ],
            ),
          ),
          routes: [
            GoRoute(
              path: '/collab',
              builder: (context, _) => Center(
                child: FilledButton(
                  onPressed: () =>
                      Navigator.of(context, rootNavigator: true).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const CollabMosaicDetailScreen(
                        mosaicId: 'm1',
                        mosaicName: 'M31 Wide Field',
                      ),
                    ),
                  ),
                  child: const Text('View panels'),
                ),
              ),
            ),
            GoRoute(
              path: '/dashboard',
              builder: (_, __) => const Text('dashboard stub'),
            ),
          ],
        ),
      ],
    );

Future<void> _openDetail(WidgetTester tester) async {
  _router = _buildRouter();
  addTearDown(_router.dispose);
  // Deliberately NOT wrapped in an outer MaterialApp: production's root
  // navigator is the one GoRouter owns, and a wrapper would put
  // `rootNavigator: true` outside the router scope entirely.
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        collaborativeMosaicDetailProvider
            .overrideWith((ref, id) async => _mosaic),
        collaborativeMosaicAttributionProvider.overrideWith(
          (ref, id) async => const ArtifactAttribution(
            artifactType: 'mosaic',
            artifactRef: 'm1',
            contributors: [],
          ),
        ),
      ],
      child: MaterialApp.router(
        theme: SkotiqTheme.dark,
        routerConfig: _router,
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tap(find.text('View panels'));
  await tester.pumpAndSettle();
  expect(find.text('M31 Wide Field'), findsWidgets);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the detail page has a working back control', (tester) async {
    await _openDetail(tester);

    // The back affordance moved into the one PageHeader (06 removes the second
    // header row), and SkotiqIconButton publishes its words on the
    // semantics node rather than in a Material Tooltip.
    final back = find.bySemanticsLabel('Back to Collaborate');
    expect(back, findsOneWidget);
    await tester.tap(back);
    await tester.pumpAndSettle();

    expect(find.text('M31 Wide Field'), findsNothing);
    expect(find.text('View panels'), findsOneWidget);
  });

  testWidgets('navigating the shell dismisses the pushed detail page',
      (tester) async {
    await _openDetail(tester);

    _router.go('/dashboard');
    await tester.pumpAndSettle();

    expect(find.text('M31 Wide Field'), findsNothing);
    expect(find.text('dashboard stub'), findsOneWidget);
  });
}
