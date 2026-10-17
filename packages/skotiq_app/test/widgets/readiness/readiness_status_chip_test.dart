import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/widgets/readiness/readiness_panel.dart';
import 'package:skotiq_app/widgets/readiness/readiness_status_chip.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// A report with one blocking critical-devices item and one caution item, so
/// the overall level is [ReadinessLevel.blocked] and there is a navigable
/// remediation to exercise.
const _blockedReport = ReadinessReport(
  items: [
    ReadinessItem(
      id: ReadinessItemId.criticalDevices,
      title: 'Critical devices',
      detail: 'No equipment profile is set up yet.',
      level: ReadinessLevel.blocked,
      fixRoute: '/equipment',
      fixLabel: 'Set up equipment',
    ),
    ReadinessItem(
      id: ReadinessItemId.plateSolver,
      title: 'Plate solver',
      detail: 'No plate solver is configured.',
      level: ReadinessLevel.caution,
      fixRoute: '/settings/plate-solving',
      fixLabel: 'Set up plate solving',
    ),
  ],
);

Widget _harness({
  required ReadinessReport report,
  required GoRouter router,
}) {
  return ProviderScope(
    overrides: [
      readinessReportProvider.overrideWithValue(report),
    ],
    child: MaterialApp.router(
      theme: SkotiqTheme.dark,
      routerConfig: router,
    ),
  );
}

GoRouter _routerWithProbe({required ValueNotifier<String?> visited}) {
  return GoRouter(
    initialLocation: '/dashboard',
    routes: [
      GoRoute(
        path: '/dashboard',
        builder: (context, state) => const Scaffold(
          body: Center(child: ReadinessStatusChip()),
        ),
      ),
      GoRoute(
        path: '/equipment',
        builder: (context, state) {
          visited.value = state.uri.toString();
          return const Scaffold(body: Text('EQUIPMENT SCREEN'));
        },
      ),
      GoRoute(
        path: '/settings/plate-solving',
        builder: (context, state) {
          visited.value = state.uri.toString();
          return const Scaffold(body: Text('PLATE SOLVING SCREEN'));
        },
      ),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'blocked report renders "Not ready" chip and a Fix button that '
      'navigates and closes the dialog', (tester) async {
    final visited = ValueNotifier<String?>(null);
    addTearDown(visited.dispose);

    await tester.pumpWidget(
      _harness(
        report: _blockedReport,
        router: _routerWithProbe(visited: visited),
      ),
    );
    // The blocked critical-devices row renders a `StatusDotVariant.urgent` dot
    // whose slow pulse repeats forever, so `pumpAndSettle` would never settle.
    // Pump a fixed number of frames instead.
    await tester.pump();

    // The chip surfaces the blocked summary label and the outstanding count.
    expect(find.text('Not ready: 1 to fix'), findsOneWidget);

    // Tapping the chip opens the readiness dialog.
    await tester.tap(find.byType(ReadinessStatusChip));
    await tester.pump(); // start the dialog route transition
    await tester.pump(const Duration(milliseconds: 400)); // finish it

    expect(find.byType(ReadinessPanel), findsOneWidget);
    expect(find.text('Set up equipment'), findsOneWidget);
    expect(find.text('Set up plate solving'), findsOneWidget);

    // The blocking item's Fix button navigates to /equipment and the dialog
    // closes (panel gone).
    await tester.tap(find.text('Set up equipment'));
    await tester.pump(); // process navigation + dialog pop
    await tester.pump(const Duration(milliseconds: 400)); // finish transitions

    expect(visited.value, '/equipment');
    expect(find.byType(ReadinessPanel), findsNothing);
    expect(find.text('EQUIPMENT SCREEN'), findsOneWidget);
  });

  testWidgets('ready report maps to a success pill with no outstanding work',
      (tester) async {
    const readyReport = ReadinessReport(
      items: [
        ReadinessItem(
          id: ReadinessItemId.criticalDevices,
          title: 'Critical devices',
          detail: 'Camera and mount are connected.',
          level: ReadinessLevel.ready,
        ),
      ],
    );

    final visited = ValueNotifier<String?>(null);
    addTearDown(visited.dispose);

    await tester.pumpWidget(
      _harness(
        report: readyReport,
        router: _routerWithProbe(visited: visited),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Ready to image: All set'), findsOneWidget);
  });
}
