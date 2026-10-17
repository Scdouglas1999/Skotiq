import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/screens/equipment/widgets/equipment_blocker_row.dart';
import 'package:skotiq_app/screens/equipment/widgets/equipment_readiness_panel.dart';
import 'package:skotiq_app/widgets/readiness/readiness_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

/// Two hard blockers plus one caution — the exact shape the live audit hit:
/// the Equipment status rail said "2 items are blocking first light." over a
/// list from which one of the blockers had been dismissed away.
const _report = ReadinessReport(
  items: [
    ReadinessItem(
      id: ReadinessItemId.criticalDevices,
      title: 'Critical devices',
      detail: 'Camera is not connected.',
      level: ReadinessLevel.blocked,
      fixRoute: '/equipment',
      fixLabel: 'Connect camera',
    ),
    ReadinessItem(
      id: ReadinessItemId.outputPath,
      title: 'Capture output folder',
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
  ],
);

/// One blocker cleared: overall CAUTION with two caution rows, so the header
/// quotes a caution count that dismissal can move.
const _cautionReport = ReadinessReport(
  items: [
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

Widget _harness(ReadinessReport report) {
  return ProviderScope(
    overrides: [
      inMemoryDatabaseOverride(),
      readinessReportProvider.overrideWithValue(report)
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

/// The ✕ inside the readiness row carrying [title].
///
/// The row is an [EquipmentBlockerRow] and its ✕ is a [SkotiqIconButton],
/// which carries its tooltip through `Semantics`, not a Material `Tooltip` —
/// so `find.byTooltip` would miss it.
Finder _dismissFor(String title) => find.descendant(
      of: find.ancestor(
        of: find.text(title),
        matching: find.byType(EquipmentBlockerRow),
      ),
      matching: find.byWidgetPredicate(
        (w) => w is SkotiqIconButton && w.tooltip == 'Dismiss for this session',
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a blocking row offers no dismiss control', (tester) async {
    await tester.pumpWidget(_harness(_report));
    await tester.pump();

    expect(find.text('Critical devices'), findsOneWidget);
    expect(_dismissFor('Critical devices'), findsNothing);
    // The caution row keeps its ✕ — the affordance is not removed wholesale.
    expect(_dismissFor('Plate solver'), findsOneWidget);
  });

  testWidgets(
      'a blocker already in the dismissed set is still listed, and the header '
      'count matches the rows', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          readinessReportProvider.overrideWithValue(_report),
          // Simulate a stale/foreign dismissal of a hard blocker: the panel
          // must refuse to hide it rather than quietly shrink the list under
          // an unchanged "2 items are blocking" header.
          dismissedReadinessItemsProvider.overrideWith(
            (ref) => {ReadinessItemId.criticalDevices},
          ),
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
      ),
    );
    await tester.pump();

    expect(find.text('Critical devices'), findsOneWidget);
    expect(find.text('Capture output folder'), findsOneWidget);
    expect(
      find.text('2 blockers'),
      findsOneWidget,
      reason: 'the count must equal the number of blocking rows on screen',
    );
    expect(find.textContaining('dismissed'), findsNothing);
  });

  testWidgets('dismissing a caution row moves the header count with it',
      (tester) async {
    await tester.pumpWidget(_harness(_cautionReport));
    await tester.pump();

    expect(find.text('2 to review'), findsOneWidget);

    await tester.tap(_dismissFor('Plate solver'));
    await tester.pump();

    expect(find.text('Plate solver'), findsNothing);
    expect(
      find.text('1 to review'),
      findsOneWidget,
      reason: 'the chip must count the rows shown',
    );
  });
}
