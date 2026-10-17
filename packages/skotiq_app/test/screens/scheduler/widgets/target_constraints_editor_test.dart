// Widget tests for the wizard-mode "Add constraint" flow on the per-target
// constraints editor. Verifies:
//   * Step 1 renders five constraint-type cards (timeWindow, moon
//     illumination, moon separation, customHorizon, scheduledWindow).
//   * Picking "Time window" advances Step 2 with the 22:00–02:00 default.
//   * Saving on Step 3 persists the constraint via TargetConstraintService.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:skotiq_app/screens/scheduler/widgets/target_constraints_editor.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/database/database.dart' as ndb;
import 'package:skotiq_ui/skotiq_ui.dart';

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void switchTo(SkotiqBackend backend) => state = backend;
}

Future<int> _insertTargetWithId(
    ndb.SkotiqDatabase db, int id, String name) async {
  // Force the id so the wizard test's hard-coded targetId matches the
  // FK referenced by target_constraints.target_id.
  return await db.into(db.targets).insert(
        ndb.TargetsCompanion(
          id: Value(id),
          name: Value(name),
          ra: const Value(0.0),
          dec: const Value(0.0),
        ),
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ndb.SkotiqDatabase database;

  setUp(() {
    database = ndb.SkotiqDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await database.close();
  });

  Widget host({required Widget child}) {
    return ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(database),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    );
  }

  testWidgets('wizard Step 1 renders the five constraint-type cards',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(900, 1100);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await _insertTargetWithId(database, 99, 'NGC 7000');

    await tester.pumpWidget(host(
      child: const TargetConstraintsEditor(
        targetId: 99,
        targetName: 'NGC 7000',
      ),
    ));
    await tester.pumpAndSettle();

    final addBtn = find.byKey(const ValueKey('add-constraint-wizard-button'));
    expect(addBtn, findsOneWidget);
    await tester.tap(addBtn);
    await tester.pumpAndSettle();

    expect(find.text('What kind of constraint?'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('wizard-kind-timeWindow')), findsOneWidget);
    expect(find.byKey(const ValueKey('wizard-kind-moon')), findsOneWidget);
    expect(find.byKey(const ValueKey('wizard-kind-horizon')), findsOneWidget);
    expect(find.byKey(const ValueKey('wizard-kind-scheduledWindow')),
        findsOneWidget);
    expect(find.text('Time window'), findsOneWidget);
    expect(find.text('Moon illumination'), findsOneWidget);
    // Separation is the one that actually protects the frames; it must be
    // offered alongside the illumination cap, not instead of it.
    expect(find.text('Moon separation'), findsOneWidget);
    expect(find.text('Custom horizon'), findsOneWidget);
    expect(find.text('Scheduled window'), findsOneWidget);
  });

  testWidgets(
      'picking "Time window" advances Step 2 with the 22:00 – 02:00 default',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(900, 1100);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await _insertTargetWithId(database, 99, 'NGC 7000');

    await tester.pumpWidget(host(
      child: const TargetConstraintsEditor(
        targetId: 99,
        targetName: 'NGC 7000',
      ),
    ));
    await tester.pumpAndSettle();

    await tester
        .tap(find.byKey(const ValueKey('add-constraint-wizard-button')));
    await tester.pumpAndSettle();

    // Select the time-window card.
    await tester.tap(find.byKey(const ValueKey('wizard-kind-timeWindow')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('wizard-next')));
    await tester.pumpAndSettle();

    // Step 2 shows the default times.
    expect(find.text('22:00'), findsOneWidget);
    expect(find.text('02:00'), findsOneWidget);
  });

  testWidgets(
      'saving the wizard persists the constraint via TargetConstraintService',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(900, 1100);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(database),
    ]);
    addTearDown(container.dispose);
    await _insertTargetWithId(database, 77, 'M42');

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(
          body: SingleChildScrollView(
            child: TargetConstraintsEditor(
              targetId: 77,
              targetName: 'M42',
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester
        .tap(find.byKey(const ValueKey('add-constraint-wizard-button')));
    await tester.pumpAndSettle();

    // Pick "Moon illumination" (simpler than horizon — no profile
    // prerequisite).
    await tester.tap(find.byKey(const ValueKey('wizard-kind-moon')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('wizard-next')));
    await tester.pumpAndSettle();

    // Step 2 — keep the 30 % default.
    expect(find.textContaining('30 %'), findsAtLeastNWidgets(1));
    await tester.tap(find.byKey(const ValueKey('wizard-next')));
    await tester.pumpAndSettle();

    // Step 3 — review + save. The review headline must name the SAME constraint
    // the Step 1 card did: with a moon-separation sibling in the list, an
    // umbrella 'Moon avoidance' does not say which of the two is being written.
    expect(find.text('Review and save'), findsOneWidget);
    expect(find.text('Moon illumination'), findsOneWidget);
    expect(find.text('Moon avoidance'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('wizard-save')));
    await tester.pumpAndSettle();

    // Now read the database directly and assert the constraint exists.
    final svc = container.read(targetConstraintServiceProvider);
    final rows = await svc.listForTarget(77);
    expect(rows.length, 1);
    expect(rows.first.kind, TargetConstraintKind.moonIlluminationMax);
    expect(rows.first.moonIlluminationMax, closeTo(0.30, 1e-6));
  });

  testWidgets(
      'the wizard can build a moon SEPARATION constraint, not only an '
      'illumination cap', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(900, 1100);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(database),
    ]);
    addTearDown(container.dispose);
    await _insertTargetWithId(database, 78, 'NGC 7000');

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(
          body: SingleChildScrollView(
            child: TargetConstraintsEditor(
              targetId: 78,
              targetName: 'NGC 7000',
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester
        .tap(find.byKey(const ValueKey('add-constraint-wizard-button')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('wizard-kind-moon-separation')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('wizard-next')));
    await tester.pumpAndSettle();

    // Step 2 — keep the 30 degree default.
    expect(find.textContaining('30°'), findsAtLeastNWidgets(1));
    await tester.tap(find.byKey(const ValueKey('wizard-next')));
    await tester.pumpAndSettle();

    // Step 3 — the review says what will actually happen, under the same
    // name the Step 1 card used.
    expect(find.text('Moon separation'), findsOneWidget);
    expect(find.text('Moon avoidance'), findsNothing);
    expect(
      find.textContaining('whenever the moon is within 30° of it'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('wizard-save')));
    await tester.pumpAndSettle();

    final svc = container.read(targetConstraintServiceProvider);
    final rows = await svc.listForTarget(78);
    expect(rows.length, 1);
    expect(rows.first.kind, TargetConstraintKind.moonSeparationMin);
    expect(rows.first.moonSeparationMinDeg, closeTo(30.0, 1e-6));
  });

  testWidgets('wizard cannot save a host-A constraint after a host switch',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(900, 1100);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    late _SwappableBackendNotifier notifier;
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(database),
      backendProvider.overrideWith((ref) {
        notifier = _SwappableBackendNotifier(ref, DisconnectedBackend());
        return notifier;
      }),
    ]);
    addTearDown(container.dispose);
    await _insertTargetWithId(database, 88, 'M51');

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(
          body: SingleChildScrollView(
            child: TargetConstraintsEditor(
              targetId: 88,
              targetName: 'M51',
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester
        .tap(find.byKey(const ValueKey('add-constraint-wizard-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('wizard-kind-moon')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('wizard-next')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('wizard-next')));
    await tester.pumpAndSettle();
    expect(find.text('Review and save'), findsOneWidget);

    notifier.switchTo(DisconnectedBackend());
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('wizard-save')));
    await tester.pumpAndSettle();

    final rows =
        await container.read(targetConstraintServiceProvider).listForTarget(88);
    expect(rows, isEmpty);
    expect(find.textContaining('Reopen the constraint editor'), findsOneWidget);
  });

  testWidgets(
      'saving a scheduledWindow constraint via the wizard writes the '
      'absolute UTC range to the database', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(900, 1100);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(database),
    ]);
    addTearDown(container.dispose);
    await _insertTargetWithId(database, 55, 'NGC 891');

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(
          body: SingleChildScrollView(
            child: TargetConstraintsEditor(
              targetId: 55,
              targetName: 'NGC 891',
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester
        .tap(find.byKey(const ValueKey('add-constraint-wizard-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('wizard-kind-scheduledWindow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('wizard-next')));
    await tester.pumpAndSettle();
    // Step 2 — accept defaults.
    await tester.tap(find.byKey(const ValueKey('wizard-next')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('wizard-save')));
    await tester.pumpAndSettle();

    final svc = container.read(targetConstraintServiceProvider);
    final rows = await svc.listForTarget(55);
    expect(rows.length, 1);
    expect(rows.first.kind, TargetConstraintKind.scheduledWindow);
    expect(rows.first.scheduledWindow, isNotNull);
    expect(rows.first.scheduledWindow!.priorityBoost, closeTo(0.5, 1e-6));
    expect(
      rows.first.scheduledWindow!.endUtc
          .isAfter(rows.first.scheduledWindow!.startUtc),
      isTrue,
    );
  });
}
