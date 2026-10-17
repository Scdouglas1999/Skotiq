import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/router/app_router.dart';
import 'package:skotiq_app/screens/session_review/auto_integration_service.dart';
import 'package:skotiq_app/widgets/auto_integration_launcher.dart';

void main() {
  testWidgets('outer-wrapper topology can show completion toast',
      (tester) async {
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
          autoIntegrationCoordinatorProvider.overrideWith((ref) {}),
        ],
        child: AutoIntegrationLauncher(
          child: MaterialApp.router(routerConfig: router),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(AutoIntegrationLauncher)),
    );
    container.read(autoIntegrationCompletionProvider.notifier).state =
        const AutoIntegrationCompletion(
      generation: 1,
      result: AutoIntegrationResult(
        ran: true,
        message: 'Integrated 42 accepted frames.',
      ),
    );
    await tester.pump();

    expect(find.text('Integrated 42 accepted frames.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 5));
  });
}
