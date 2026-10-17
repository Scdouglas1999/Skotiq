// What the shell reads to decide which rail row is lit.
//
// The rail is a statement about where the operator is, so the location it is
// handed has to be the route on top of the navigator. A `context.push` of a
// route that lives inside the ShellRoute — which is how every Darkroom and
// session-review entry point navigates — folds its match into the existing
// shell match, so the top-level match list still ends with the shell and the
// shell's own `matchedLocation` is the rail route the push started from.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/screens/shell/app_shell.dart';
import 'package:skotiq_app/screens/shell/shell_navigation.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// A router shaped like the app's: rail destinations and the Darkroom side by
/// side inside one ShellRoute, reached by `go` and by `push` respectively.
({GoRouter router, GlobalKey<NavigatorState> shellKey}) buildRouter() {
  final shellKey = GlobalKey<NavigatorState>();
  final router = GoRouter(
    navigatorKey: GlobalKey<NavigatorState>(),
    initialLocation: '/dashboard',
    routes: [
      ShellRoute(
        navigatorKey: shellKey,
        builder: (context, state, child) => Scaffold(body: child),
        routes: [
          GoRoute(
            path: '/dashboard',
            builder: (_, __) => const Text('dashboard'),
          ),
          GoRoute(
            path: '/analytics',
            builder: (_, __) => const Text('analytics'),
          ),
          GoRoute(
            path: '/imaging',
            builder: (_, __) => const Text('imaging'),
            routes: [
              GoRoute(
                path: 'preview/:id',
                builder: (_, __) => const Text('preview'),
              ),
            ],
          ),
          GoRoute(
              path: '/darkroom', builder: (_, __) => const Text('darkroom')),
          GoRoute(
            path: '/session-review',
            builder: (_, __) => const Text('review'),
          ),
        ],
      ),
    ],
  );
  return (router: router, shellKey: shellKey);
}

void main() {
  testWidgets('a declarative move answers with the route it moved to',
      (tester) async {
    final built = buildRouter();
    addTearDown(built.router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: built.router));
    await tester.pumpAndSettle();

    expect(topRouteLocation(built.router), '/dashboard');

    built.router.go('/analytics');
    await tester.pumpAndSettle();
    expect(topRouteLocation(built.router), '/analytics');
    expect(
      ShellNavigation.primaryIndexForLocation(topRouteLocation(built.router)),
      ShellNavigation.primaryRoutes.indexOf('/analytics'),
    );
  });

  testWidgets(
      'a pushed Darkroom answers with the Darkroom, so the rail lights '
      'Darkroom', (tester) async {
    final built = buildRouter();
    addTearDown(built.router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: built.router));
    await tester.pumpAndSettle();

    built.router.go('/analytics');
    await tester.pumpAndSettle();

    // openDarkroomForMaster pushes from inside the shell.
    unawaited(built.shellKey.currentContext!.push('/darkroom?master=7'));
    await tester.pumpAndSettle();

    expect(topRouteLocation(built.router), '/darkroom');
    // The Darkroom became a rail destination in the Observatory shell, so a
    // pushed Darkroom lights Darkroom. What this case still protects is the
    // reason it was written: `topRouteLocation` must descend to the LEAF
    // match. Reading the shell's own `matchedLocation` answers `/analytics`
    // here, which would light Analytics while the Darkroom is on screen.
    expect(
      ShellNavigation.primaryIndexForLocation(topRouteLocation(built.router)),
      ShellNavigation.primaryRoutes.indexOf('/darkroom'),
      reason: 'the rail follows the route that is actually painted',
    );
    expect(locationToAppScreen(topRouteLocation(built.router)),
        AppScreen.darkroom);
  });

  testWidgets('a pushed session review answers the same way', (tester) async {
    final built = buildRouter();
    addTearDown(built.router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: built.router));
    await tester.pumpAndSettle();

    built.router.go('/analytics');
    await tester.pumpAndSettle();
    unawaited(built.shellKey.currentContext!.push('/session-review'));
    await tester.pumpAndSettle();

    expect(topRouteLocation(built.router), '/session-review');
    // /session-review is a Darkroom surface (04 §3.2's alias table), and it
    // shares no path prefix with /darkroom — which is exactly why the table
    // exists and a prefix walk could not answer this.
    expect(
      ShellNavigation.primaryIndexForLocation(topRouteLocation(built.router)),
      ShellNavigation.primaryRoutes.indexOf('/darkroom'),
    );
  });

  testWidgets('popping the pushed route hands the rail its row back',
      (tester) async {
    final built = buildRouter();
    addTearDown(built.router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: built.router));
    await tester.pumpAndSettle();

    built.router.go('/analytics');
    await tester.pumpAndSettle();
    unawaited(built.shellKey.currentContext!.push('/darkroom?master=7'));
    await tester.pumpAndSettle();
    built.router.pop();
    await tester.pumpAndSettle();

    expect(topRouteLocation(built.router), '/analytics');
    expect(
      ShellNavigation.primaryIndexForLocation(topRouteLocation(built.router)),
      ShellNavigation.primaryRoutes.indexOf('/analytics'),
    );
  });

  testWidgets('a sub-route still resolves to its host', (tester) async {
    final built = buildRouter();
    addTearDown(built.router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: built.router));
    await tester.pumpAndSettle();

    built.router.go('/imaging/preview/42');
    await tester.pumpAndSettle();

    expect(topRouteLocation(built.router), '/imaging/preview/42');
    expect(
      ShellNavigation.primaryIndexForLocation(topRouteLocation(built.router)),
      ShellNavigation.primaryRoutes.indexOf('/imaging'),
    );
  });
}
