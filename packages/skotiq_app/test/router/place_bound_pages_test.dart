// A page pushed straight onto the shell's navigator (a target's page over the
// Plan list on a phone) closes when the app moves to another place. The
// shell's routed pages carry no key, so before this a tap on the Sequencer
// tab lit the tab while the target's page stayed on screen.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/router/app_router.dart';
import 'package:skotiq_app/router/place_bound_pages.dart';

import '../harness/mock_database.dart' show inMemoryDatabaseOverride;

/// The production shell's shape: routed pages without keys under a
/// [ShellRoute] whose navigator the screens push onto.
GoRouter _shellRouter() {
  late final GoRouter router;
  final pages = PlaceBoundPages(
    () => router.routeInformationProvider.value.uri.toString(),
  );
  Page<void> page(Widget child) => CustomTransitionPage<void>(
        transitionsBuilder: (context, animation, secondary, child) => child,
        child: child,
      );
  router = GoRouter(
    initialLocation: '/planner?tab=targets',
    routes: [
      ShellRoute(
        observers: [pages],
        builder: (context, state, child) => Scaffold(body: child),
        routes: [
          GoRoute(
            path: '/planner',
            pageBuilder: (context, state) => page(
              Builder(
                builder: (context) => Column(
                  children: [
                    Text('plan ${state.uri.queryParameters['tab']}'),
                    TextButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const Text('M1 detail'),
                        ),
                      ),
                      child: const Text('open M1'),
                    ),
                    TextButton(
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) => const Text('a dialog'),
                      ),
                      child: const Text('open dialog'),
                    ),
                  ],
                ),
              ),
            ),
          ),
          GoRoute(
            path: '/sequencer',
            pageBuilder: (context, state) => page(const Text('sequencer')),
          ),
        ],
      ),
    ],
  );
  pages.follow(router);
  return router;
}

Future<GoRouter> _pump(WidgetTester tester) async {
  final router = _shellRouter();
  addTearDown(router.dispose);
  await tester.pumpWidget(MaterialApp.router(routerConfig: router));
  await tester.pumpAndSettle();
  return router;
}

void main() {
  testWidgets('a tab move closes the page opened over the place it left',
      (tester) async {
    final router = await _pump(tester);
    await tester.tap(find.text('open M1'));
    await tester.pumpAndSettle();
    expect(find.text('M1 detail'), findsOneWidget);

    router.go('/sequencer');
    await tester.pumpAndSettle();

    expect(find.text('M1 detail'), findsNothing);
    expect(find.text('sequencer'), findsOneWidget);
  });

  testWidgets('a move to another tab of the same screen closes it too',
      (tester) async {
    final router = await _pump(tester);
    await tester.tap(find.text('open M1'));
    await tester.pumpAndSettle();

    // "Frame it" on a target's page goes to Plan > Framing.
    router.go('/planner?tab=framing');
    await tester.pumpAndSettle();

    expect(find.text('M1 detail'), findsNothing);
    expect(find.text('plan framing'), findsOneWidget);
  });

  testWidgets('the page stays while the app stays where it was',
      (tester) async {
    final router = await _pump(tester);
    await tester.tap(find.text('open M1'));
    await tester.pumpAndSettle();

    router.go('/planner?tab=targets');
    await tester.pumpAndSettle();

    expect(find.text('M1 detail'), findsOneWidget);
  });

  testWidgets('a dialog is left to its own code', (tester) async {
    final router = await _pump(tester);
    await tester.tap(find.text('open dialog'));
    await tester.pumpAndSettle();

    router.go('/sequencer');
    await tester.pumpAndSettle();

    expect(find.text('a dialog'), findsOneWidget);
  });

  test('the app router closes pushed pages on the shell\'s navigator', () {
    final container =
        ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
    addTearDown(container.dispose);
    final router = container.read(appRouterProvider);
    addTearDown(router.dispose);
    final shell = router.configuration.routes.whereType<ShellRoute>().single;
    expect(shell.observers?.whereType<PlaceBoundPages>(), hasLength(1));
  });
}
