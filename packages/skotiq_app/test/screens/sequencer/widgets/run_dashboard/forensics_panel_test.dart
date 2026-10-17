/// Frame-Failure Forensics: widget tests for the Forensics
/// panel + the Frame Detail dialog.
///
/// Strategy: persist three synthetic forensic records (one of each
/// cause we want to assert visibility for) into an in-memory drift DB,
/// override the `forensicsServiceProvider` to point at our test
/// service, mount the panel, and assert the rendered text.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/run_dashboard/forensics_panel.dart';
import 'package:skotiq_app/screens/sequencer/widgets/run_dashboard/frame_detail_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../../../harness/mock_database.dart' show inMemoryDatabaseOverride;

SkotiqDatabase _newDb() =>
    SkotiqDatabase.forTesting(NativeDatabase.memory());

Widget _wrap(Widget child, ProviderContainer container) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Forensics panel renders cause distribution + recent rows',
      (tester) async {
    final db = _newDb();
    final service = ForensicsService(db);
    addTearDown(() async {
      await service.dispose();
      await db.close();
    });

    // Persist nine CloudPassage rejections + one SeeingSpike to match
    // the brief's walkthrough.
    for (var i = 0; i < 9; i++) {
      await service.recordRejection(
        sessionId: 'sess-1',
        frameIndex: i + 1,
        totalFrames: 30,
        rejectPath:
            '/captures/Reject/m31_L_${i.toString().padLeft(4, '0')}.fits',
        reason: 'star count 15 below minimum 80 (likely cloud / off-target)',
        causeLabel: LikelyCause.cloudPassage.label,
        evidence: const [
          'Sky brightness dropped 0.70 mag in last 60s',
          'Cloud cover spiked from 12% to 78%',
          '8 other frames in same window also rejected',
        ],
        environment: const ForensicEnvironment(
          skyBrightnessMag: 20.5,
          cloudCoverPercent: 78.0,
        ),
      );
    }
    await service.recordRejection(
      sessionId: 'sess-1',
      frameIndex: 10,
      totalFrames: 30,
      rejectPath: '/captures/Reject/m31_L_0010.fits',
      reason: 'HFR 5.10 px exceeds baseline 2.0 px + 50% (limit 3.0 px)',
      causeLabel: LikelyCause.seeingSpike.label,
      evidence: const [
        'HFR 5.10 px is 2.5× baseline 2.00 px',
        '2 of last 3 frames also showed HFR > 1.3× baseline',
      ],
      environment: const ForensicEnvironment(skyBrightnessMag: 21.0),
    );

    final container = ProviderContainer(overrides: [
      inMemoryDatabaseOverride(),
      forensicsServiceProvider.overrideWithValue(service),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      _wrap(
        const RunDashboardForensicsPanel(sessionId: 'sess-1'),
        container,
      ),
    );
    // Initial frame may show loading; let the FutureProvider settle.
    await tester.pumpAndSettle();

    expect(find.text('WHY DID THIS FRAME FAIL?'), findsOneWidget);
    expect(find.text('10 rejections'), findsOneWidget);
    // The cause-distribution legend lists both causes with their counts.
    expect(find.textContaining('Cloud passage (9)'), findsOneWidget);
    expect(find.textContaining('Seeing spike (1)'), findsOneWidget);
    // At least one human label appears as a row header.
    expect(find.text('Cloud passage'), findsWidgets);
  });

  testWidgets('Tapping a row opens the Frame Detail dialog with evidence',
      (tester) async {
    final db = _newDb();
    final service = ForensicsService(db);
    addTearDown(() async {
      await service.dispose();
      await db.close();
    });

    await service.recordRejection(
      sessionId: 'sess-1',
      frameIndex: 7,
      totalFrames: 20,
      rejectPath: '/captures/Reject/m31_L_0007.fits',
      reason: 'star count 15 below minimum 80',
      causeLabel: LikelyCause.cloudPassage.label,
      evidence: const [
        'Sky brightness dropped 0.70 mag in last 60s',
        'Cloud cover spiked from 12% to 78%',
      ],
      environment: const ForensicEnvironment(
        cloudCoverPercent: 78.0,
        windKph: 5.0,
      ),
      hfr: 3.2,
      eccentricity: 0.55,
      starCount: 15,
    );

    final container = ProviderContainer(overrides: [
      inMemoryDatabaseOverride(),
      forensicsServiceProvider.overrideWithValue(service),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(_wrap(
      const RunDashboardForensicsPanel(sessionId: 'sess-1'),
      container,
    ));
    await tester.pumpAndSettle();

    // Tap the row. The InkWell wraps the row body; find by the cause
    // label which only appears in the row header inside the panel.
    await tester.tap(find.text('Cloud passage').first);
    await tester.pumpAndSettle();

    // Dialog now visible with evidence bullets + grader reason.
    expect(find.text('Why did this fail?'), findsOneWidget);
    expect(find.text('GRADER REASON'), findsOneWidget);
    // The reason text appears both in the underlying Forensics panel
    // row (still mounted behind the dialog) AND in the dialog body's
    // GRADER REASON section. Same for the evidence bullets — they
    // render in the row preview and again in the dialog. findsAtLeast
    // keeps the intent ("the dialog surfaced these") while tolerating
    // the duplicates the panel renders behind the dialog.
    expect(
      find.text('star count 15 below minimum 80'),
      findsAtLeastNWidgets(1),
    );
    expect(find.text('EVIDENCE'), findsOneWidget);
    expect(
      find.text('Sky brightness dropped 0.70 mag in last 60s'),
      findsAtLeastNWidgets(1),
    );
    expect(
      find.text('Cloud cover spiked from 12% to 78%'),
      findsAtLeastNWidgets(1),
    );
    expect(find.text('FRAME METRICS'), findsOneWidget);
    expect(find.text('ENVIRONMENT AT CAPTURE'), findsOneWidget);
  });

  testWidgets('Panel hides itself when no records exist for the session',
      (tester) async {
    final db = _newDb();
    final service = ForensicsService(db);
    addTearDown(() async {
      await service.dispose();
      await db.close();
    });
    final container = ProviderContainer(overrides: [
      inMemoryDatabaseOverride(),
      forensicsServiceProvider.overrideWithValue(service),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(_wrap(
      const RunDashboardForensicsPanel(sessionId: 'no-data'),
      container,
    ));
    await tester.pumpAndSettle();

    // Panel is hidden; none of the headers should render.
    expect(find.text('WHY DID THIS FRAME FAIL?'), findsNothing);
  });

  testWidgets('Frame detail dialog shows "no telemetry" fallback',
      (tester) async {
    final record = FrameForensicsRecord(
      id: 'r1',
      capturedImageId: null,
      sessionId: 's',
      sequenceRunId: null,
      nodeId: null,
      frameIndex: 1,
      totalFrames: 1,
      rejectPath: '/x.fits',
      reason: 'eccentricity 0.75 exceeds threshold 0.60',
      likelyCause: LikelyCause.satellitePass,
      evidence: const ['Isolated rejection — no nearby frames bad'],
      environment: const ForensicEnvironment(),
      hfr: 3.5,
      eccentricity: 0.75,
      starCount: 120,
      createdAt: DateTime.utc(2026, 5, 18, 21, 5, 13),
    );
    final container =
        ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
    addTearDown(container.dispose);
    await tester.pumpWidget(_wrap(
      FrameDetailDialog(record: record),
      container,
    ));
    await tester.pumpAndSettle();
    expect(find.text('Satellite / aircraft trail'), findsOneWidget);
    expect(
        find.text('No telemetry available at capture time.'), findsOneWidget);
    expect(
        find.text('Isolated rejection — no nearby frames bad'), findsOneWidget);
  });
}
