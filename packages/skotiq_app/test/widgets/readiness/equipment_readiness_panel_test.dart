import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/screens/equipment/widgets/equipment_readiness_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

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

const _readyReport = ReadinessReport(
  items: [
    ReadinessItem(
      id: ReadinessItemId.criticalDevices,
      title: 'Critical devices',
      detail: 'Camera and mount are connected.',
      level: ReadinessLevel.ready,
    ),
  ],
);

Widget _harness(ReadinessReport report) {
  return ProviderScope(
    overrides: [
      readinessReportProvider.overrideWithValue(report),
    ],
    child: MaterialApp.router(
      theme: SkotiqTheme.dark,
      routerConfig: GoRouter(
        initialLocation: '/equipment',
        routes: [
          GoRoute(
            path: '/equipment',
            builder: (_, __) => const Scaffold(
              body: SingleChildScrollView(child: EquipmentReadinessPanel()),
            ),
          ),
        ],
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders the section title + itemized blockers when not ready',
      (tester) async {
    await tester.pumpWidget(_harness(_blockedReport));
    // Blocked item has a forever-pulsing urgent dot; pump frames.
    await tester.pump();

    // 06 §Equipment: a SectionTitle with the outstanding count, then one row
    // per item that still needs action. The old SectionHeader sentence
    // ("2 items are blocking first light") is the chip's job now.
    expect(find.text('Readiness'), findsOneWidget);
    expect(find.text('1 blocker'), findsOneWidget);
    // Per-item rows and their Fix actions render.
    expect(find.text('Critical devices'), findsOneWidget);
    expect(find.text('Set up equipment'), findsOneWidget);
  });

  testWidgets('summarises an all-ready rig', (tester) async {
    await tester.pumpWidget(_harness(_readyReport));
    await tester.pumpAndSettle();

    expect(find.text('Readiness'), findsOneWidget);
    expect(find.text('All clear'), findsOneWidget);
    // Outstanding-only: ONE confirmation row instead of repeating every green
    // check back at the operator.
    expect(find.text('Ready for first light'), findsOneWidget);
    expect(
      find.text('Everything first light needs is in place.'),
      findsOneWidget,
    );
  });

  testWidgets('lists every outstanding item and counts the blockers among them',
      (tester) async {
    // Five outstanding items. The side panel scrolls (06 §Equipment), so the
    // list is no longer capped at three with a "View all" escape hatch — a
    // blocker the operator cannot see is a blocker they will not fix.
    const manyReport = ReadinessReport(
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
          id: ReadinessItemId.location,
          title: 'Location',
          detail: 'Set your observing location.',
          level: ReadinessLevel.blocked,
          fixRoute: '/settings',
          fixLabel: 'Set location',
        ),
        ReadinessItem(
          id: ReadinessItemId.outputPath,
          title: 'Capture folder',
          detail: 'Pick where captures are saved.',
          level: ReadinessLevel.blocked,
          fixRoute: '/settings',
          fixLabel: 'Choose folder',
        ),
        ReadinessItem(
          id: ReadinessItemId.plateSolver,
          title: 'Plate solver',
          detail: 'No plate solver is configured.',
          level: ReadinessLevel.caution,
          fixRoute: '/settings/plate-solving',
          fixLabel: 'Set up plate solving',
        ),
        ReadinessItem(
          id: ReadinessItemId.darkLibrary,
          title: 'Dark library',
          detail: 'No master darks yet.',
          level: ReadinessLevel.caution,
          fixRoute: '/imaging',
          fixLabel: 'Build darks',
        ),
      ],
    );

    await tester.pumpWidget(_harness(manyReport));
    await tester.pump();

    // Blocked first, then cautions; all five are listed.
    expect(find.text('Critical devices'), findsOneWidget);
    expect(find.text('Location'), findsOneWidget);
    expect(find.text('Capture folder'), findsOneWidget);
    expect(find.text('Plate solver'), findsOneWidget);
    expect(find.text('Dark library'), findsOneWidget);
    // The chip counts the BLOCKERS, which is what stops first light.
    expect(find.text('3 blockers'), findsOneWidget);
  });

  testWidgets('puts Fix actions below row content in the narrow status rail',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_harness(_blockedReport));
    await tester.pump();

    final titleBottom = tester.getBottomLeft(find.text('Critical devices')).dy;
    final fixTop = tester
        .getTopLeft(find.widgetWithText(SkotiqButton, 'Set up equipment'))
        .dy;

    expect(
      fixTop,
      greaterThan(titleBottom),
      reason: 'the action must not squeeze the readiness title into a sliver',
    );
    expect(tester.takeException(), isNull);
  });
}
