// A location that matches no route showed go_router's own "Page Not Found"
// page: another look, no rail, and a "Home" link to `/`, which is not a
// route of this app either.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/localization/skotiq_localizations.dart';
import 'package:skotiq_app/router/app_router.dart';
import 'package:skotiq_app/router/app_routes.dart';
import 'package:skotiq_app/router/route_not_found_screen.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  test('the app router has its own page for an unknown location', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final router = container.read(appRouterProvider);
    addTearDown(router.dispose);

    expect(router.routerDelegate.builder.errorBuilder, isNotNull);
  });

  testWidgets('it names the location and leads back to Tonight',
      (tester) async {
    final router = GoRouter(
      initialLocation: '/no/such/page?x=1',
      routes: [
        GoRoute(
          path: AppRoute.tonight.path,
          builder: (_, __) => const Text('TONIGHT'),
        ),
      ],
      errorBuilder: (context, state) =>
          RouteNotFoundScreen(location: state.uri.toString()),
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(
        theme: SkotiqTheme.dark,
        routerConfig: router,
        localizationsDelegates: SkotiqLocalizations.localizationsDelegates,
        supportedLocales: SkotiqLocalizations.supportedLocales,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Page not found'), findsOneWidget);
    expect(find.textContaining('/no/such/page?x=1'), findsOneWidget);
    expect(find.text('TONIGHT'), findsNothing);

    await tester.tap(find.text('Go to Tonight'));
    await tester.pumpAndSettle();
    expect(find.text('TONIGHT'), findsOneWidget);
    expect(find.text('Page not found'), findsNothing);
  });
}
