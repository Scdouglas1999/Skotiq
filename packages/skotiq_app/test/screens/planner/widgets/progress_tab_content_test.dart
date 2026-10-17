// Verifies the Plan Tonight → Progress tab body. The widget under test is
// [ProgressTabContent], which renders the per-target progress / ETA /
// last-imaged-at rows produced by allTargetProgressProvider.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:skotiq_app/screens/planner/widgets/progress_tab_content.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../../harness/mock_database.dart' show inMemoryDatabaseOverride;

TargetProgress _progress({
  required int id,
  required String name,
  required int captured,
  required int goal,
  int? etaNights,
  double pace = 1.0,
  DateTime? lastImagedAt,
  List<FilterProgress> perFilter = const [],
}) {
  final integrationGoal = Duration(seconds: goal * 60);
  final integrationCaptured = Duration(seconds: captured * 60);
  return TargetProgress(
    targetId: id,
    targetName: name,
    perFilter: perFilter,
    totalGoalFrames: goal,
    totalCapturedFrames: captured,
    totalIntegrationGoal: integrationGoal,
    totalIntegrationCaptured: integrationCaptured,
    percentComplete: goal == 0 ? 0.0 : (captured / goal).clamp(0.0, 1.0),
    avgFramesPerNight: pace,
    estimatedNightsRemaining: etaNights,
    lastImagedAt: lastImagedAt,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('empty state renders when there is no imaging history',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          allTargetProgressProvider.overrideWith(
            (ref) async => <int, TargetProgress>{},
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: ProgressTabContent()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('No imaging history yet'), findsOneWidget);
    expect(
      find.textContaining('Capture frames in a sequence'),
      findsOneWidget,
    );
  });

  testWidgets('populated state lists targets with their progress + ETA labels',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final progressMap = <int, TargetProgress>{
      1: _progress(
        id: 1,
        name: 'NGC 7000',
        captured: 30,
        goal: 60,
        etaNights: 2,
        lastImagedAt: DateTime.now().subtract(const Duration(days: 1)),
      ),
      2: _progress(
        id: 2,
        name: 'M31',
        captured: 10,
        goal: 80,
        etaNights: 6,
        lastImagedAt: DateTime.now().subtract(const Duration(days: 3)),
      ),
      3: _progress(
        id: 3,
        name: 'Untouched',
        captured: 0,
        goal: 40,
        etaNights: null, // no captures yet → no ETA signal
        lastImagedAt: null,
      ),
    };

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          allTargetProgressProvider.overrideWith((ref) async => progressMap),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: ProgressTabContent()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('NGC 7000'), findsOneWidget);
    expect(find.text('M31'), findsOneWidget);
    expect(find.text('Untouched'), findsOneWidget);
    // Untouched targets surface the em-dash ETA token.
    expect(find.text('—'), findsAtLeastNWidgets(1));
    // ETA chips for the two targets with captures.
    expect(find.text('2 nights'), findsOneWidget);
    expect(find.text('6 nights'), findsOneWidget);
  });

  testWidgets('sorting by ETA orders nulls last and ascending otherwise',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final progressMap = <int, TargetProgress>{
      1: _progress(
          id: 1, name: 'NGC 7000', captured: 30, goal: 60, etaNights: 4),
      2: _progress(id: 2, name: 'M31', captured: 10, goal: 80, etaNights: 1),
      3: _progress(
          id: 3, name: 'Untouched', captured: 0, goal: 40, etaNights: null),
    };

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          allTargetProgressProvider.overrideWith((ref) async => progressMap),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: ProgressTabContent()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    // Switch the sort drop-down to ETA.
    await tester.tap(find.text('Sort: % complete').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sort: ETA').last);
    await tester.pumpAndSettle();

    // Read the rendered target names in render order. Because every row is
    // wrapped in a ValueKey, we can find each by key and ask the framework
    // for its on-screen y-coordinate to assert ordering.
    final m31Y =
        tester.getTopLeft(find.byKey(const ValueKey('progress-row-2'))).dy;
    final ngcY =
        tester.getTopLeft(find.byKey(const ValueKey('progress-row-1'))).dy;
    final untouchedY =
        tester.getTopLeft(find.byKey(const ValueKey('progress-row-3'))).dy;

    // ETA 1 (M31) sorts above ETA 4 (NGC 7000); both sort above ETA null
    // (Untouched).
    expect(m31Y, lessThan(ngcY));
    expect(ngcY, lessThan(untouchedY));
  });
}
