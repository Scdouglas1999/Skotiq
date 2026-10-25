// A toast that leads somewhere offers to open it: a Darkroom notification
// opens the target or its framing check, and one that leads nowhere offers
// nothing.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/widgets/notification_toast_overlay.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../harness/mock_database.dart' show inMemoryDatabaseOverride;

void main() {
  late ProviderContainer container;
  late List<String> visited;

  Future<void> pump(WidgetTester tester) async {
    visited = [];
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(
            body: Stack(children: [NotificationToastOverlay()]),
          ),
        ),
        GoRoute(
          path: '/darkroom',
          builder: (_, state) {
            visited.add(state.uri.toString());
            return const Scaffold(body: Text('Darkroom'));
          },
        ),
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
    await tester.pump();
  }

  setUp(() {
    container = ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
  });
  tearDown(() => container.dispose());

  testWidgets('a framing-check notification opens the framing check', (
    tester,
  ) async {
    container.read(uiNotificationProvider.notifier).showWarning(
          'The common crop keeps 55.0% of the field (minimum 80%).',
          title: 'Masters wait for the framing check: NGC 891',
          deepLink: darkroomFramingPayload('NGC 891'),
        );
    await pump(tester);

    await tester.tap(find.byKey(const ValueKey('notification-toast-open')));
    await tester.pumpAndSettle();
    expect(visited, ['/darkroom?tab=targets&target=NGC+891&view=framing']);
    expect(find.text('Darkroom'), findsOneWidget);
  });

  testWidgets('a notification that leads nowhere offers no Open', (
    tester,
  ) async {
    container
        .read(uiNotificationProvider.notifier)
        .showInfo('Guider connected', title: 'Equipment');
    await pump(tester);
    expect(find.byKey(const ValueKey('notification-toast-open')), findsNothing);
    await tester.pump(const Duration(seconds: 5));
  });
}
