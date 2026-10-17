// Widget tests for ScienceStatusBanner. Verifies the three render states
// (idle, busy, error) it produces from a ScienceProcessingStatusTracker.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/widgets/science_status_banner.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../../harness/mock_database.dart' show inMemoryDatabaseOverride;

Widget _harness({
  required Widget child,
  required ScienceProcessingStatusTracker tracker,
}) {
  return ProviderScope(
    overrides: [
      inMemoryDatabaseOverride(),
      scienceProcessingStatusTrackerProvider.overrideWith((_) => tracker),
    ],
    child: MaterialApp(
      theme: ThemeData(
        extensions: const [SkotiqColors.dark],
      ),
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('hides itself when idle and hideWhenIdle is set', (tester) async {
    final tracker = ScienceProcessingStatusTracker();
    addTearDown(tracker.dispose);

    await tester.pumpWidget(_harness(
      tracker: tracker,
      child: const ScienceStatusBanner(hideWhenIdle: true),
    ));
    await tester.pump();

    expect(find.byType(ScienceStatusBanner), findsOneWidget);
    expect(find.text('Science idle'), findsNothing);
    expect(find.byType(Container), findsNothing,
        reason:
            'Banner should collapse to SizedBox.shrink when idle + hide flag.');
  });

  testWidgets('renders the idle line when there is no work in flight',
      (tester) async {
    final tracker = ScienceProcessingStatusTracker();
    addTearDown(tracker.dispose);

    await tester.pumpWidget(_harness(
      tracker: tracker,
      child: const ScienceStatusBanner(),
    ));
    await tester.pump();

    expect(find.text('Science idle'), findsOneWidget);
    expect(find.text('Waiting for the first captured frame'), findsOneWidget);
  });

  testWidgets('renders a busy state with the running stage label',
      (tester) async {
    final tracker = ScienceProcessingStatusTracker();
    addTearDown(tracker.dispose);

    tracker.beginFrame(imagePath: '/tmp/img.fits');
    tracker.beginStage(ScienceStage.plateSolve);

    await tester.pumpWidget(_harness(
      tracker: tracker,
      child: const ScienceStatusBanner(),
    ));
    await tester.pump();

    expect(find.textContaining('Plate solve'), findsWidgets);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('surfaces a recent failure with the truncated note',
      (tester) async {
    final tracker = ScienceProcessingStatusTracker();
    addTearDown(tracker.dispose);

    tracker.beginFrame(imagePath: '/tmp/img.fits');
    tracker.beginStage(ScienceStage.calibration);
    tracker.endStage(ScienceStage.calibration, ScienceStageOutcome.failed,
        note: 'no WCS available');
    tracker.endFrame();

    await tester.pumpWidget(_harness(
      tracker: tracker,
      child: const ScienceStatusBanner(),
    ));
    await tester.pump();

    expect(find.textContaining('failed'), findsWidgets);
    expect(find.textContaining('no WCS'), findsOneWidget);
  });

  testWidgets('provider failure remains visible and retryable when idle hides',
      (tester) async {
    var attempts = 0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          scienceProcessingStatusProvider.overrideWith((ref) {
            attempts++;
            return Stream<ScienceProcessingStatusSnapshot>.error(
              StateError('status stream unavailable'),
            );
          }),
        ],
        child: MaterialApp(
          theme: ThemeData(
            extensions: const [SkotiqColors.dark],
          ),
          home: const Scaffold(
            body: ScienceStatusBanner(hideWhenIdle: true),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Science status unavailable'), findsOneWidget);
    expect(
      find.textContaining('Bad state: status stream unavailable'),
      findsOneWidget,
    );
    expect(attempts, 1);

    await tester.tap(find.widgetWithText(TextButton, 'Retry'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
  });
}
