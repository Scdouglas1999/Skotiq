import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/router/app_router.dart';
import 'package:skotiq_app/startup/night_end_toasts.dart';
import 'package:skotiq_core/services.dart';

void main() {
  testWidgets('a night-end result toasts over the routed app', (tester) async {
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, __) => const Scaffold(body: Text('Dashboard')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appRouterProvider.overrideWithValue(router),
          nightEndCoordinatorProvider.overrideWith((ref) {}),
        ],
        child: NightEndToasts(
          child: MaterialApp.router(routerConfig: router),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(NightEndToasts)),
    );
    container.read(nightEndCompletionProvider.notifier).state =
        const NightEndCompletion(
      generation: 1,
      toast: NightEndToast(message: 'NGC 891: masters ready from 2 nights.'),
    );
    await tester.pump();

    expect(find.text('NGC 891: masters ready from 2 nights.'), findsOneWidget);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 11));
  });
}
