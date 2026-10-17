// The Campaign Rollup card must not describe three populations with one set
// of words.
//
// Observed defect (M13, one session, two 300s lights both rejected in the
// grader): the card showed "Total integration 0.0h" (accepted light frames)
// beside a session row reading "0.17h integration" (the session's own total),
// and "Per-filter progress: No frames captured for this target yet." — flatly
// false — while "Effective imaging 0.0%" was printed for a campaign whose only
// session had never closed, i.e. had nothing to measure.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/widgets/campaign_rollup_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

CampaignRollup _rollup({required DateTime? endTime}) => CampaignRollup(
      targetId: 4,
      targetName: 'M13',
      sessions: [
        CampaignSessionRef(
          sessionId: 5,
          sessionName: 'Night E - M13',
          startTime: DateTime.utc(2026, 7, 31, 23),
          endTime: endTime,
          status: endTime == null ? 'active' : 'completed',
          // Two 300s lights: 600s captured, all of it rejected.
          sessionIntegrationSecs: 600,
          avgHfr: 2.20,
          avgGuidingRms: 0.60,
          avgSeeing: null,
        ),
      ],
      filters: const [],
      firstSessionAt: DateTime.utc(2026, 7, 31, 23),
      lastSessionAt: DateTime.utc(2026, 7, 31, 23),
      totalCapturedIntegrationSecs: 0,
      meanSessionHfr: 2.20,
      meanSessionSeeing: null,
      meanEffectiveImagingFraction: 0.0,
      generatedAt: DateTime.utc(2026, 8, 3),
    );

/// A campaign that reached the populated per-filter table and the goal progress
/// bar — the two widgets the empty-state rollup above never renders. Half the
/// L frames were rejected: 20 accepted of 40 captured.
CampaignRollup _partlyRejectedRollup() => CampaignRollup(
      targetId: 4,
      targetName: 'M13',
      sessions: [
        CampaignSessionRef(
          sessionId: 5,
          sessionName: 'Night E - M13',
          startTime: DateTime.utc(2026, 7, 31, 23),
          endTime: DateTime.utc(2026, 8, 1, 4),
          status: 'completed',
          // 40 x 300s taken.
          sessionIntegrationSecs: 12000,
          avgHfr: 2.20,
          avgGuidingRms: 0.60,
          avgSeeing: null,
        ),
      ],
      filters: const [
        CampaignFilterRollup(
          filter: 'L',
          // 20 of the 40 survived grading.
          capturedFrames: 20,
          capturedIntegrationSecs: 6000,
          goalExposureSecs: 300,
          goalFrames: 50,
          meanCapturedExposureSecs: 300,
        ),
        CampaignFilterRollup(
          filter: 'R',
          capturedFrames: 8,
          capturedIntegrationSecs: 2400,
          goalExposureSecs: null,
          goalFrames: null,
          meanCapturedExposureSecs: 300,
        ),
      ],
      firstSessionAt: DateTime.utc(2026, 7, 31, 23),
      lastSessionAt: DateTime.utc(2026, 7, 31, 23),
      totalCapturedIntegrationSecs: 8400,
      meanSessionHfr: 2.20,
      meanSessionSeeing: null,
      meanEffectiveImagingFraction: 0.66,
      generatedAt: DateTime.utc(2026, 8, 3),
    );

Widget _dialog(CampaignRollup rollup) => ProviderScope(
      overrides: [
        campaignRollupProvider.overrideWith((ref, id) async => rollup),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(body: CampaignRollupDialog(targetId: 4)),
      ),
    );

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .physicalSize = const Size(1400, 2000);
    TestWidgetsFlutterBinding
        .instance.platformDispatcher.views.first.devicePixelRatio = 1;
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .resetPhysicalSize();
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .resetDevicePixelRatio();
  });

  testWidgets(
      'a campaign whose frames were all rejected is not told it has '
      'no frames', (tester) async {
    await tester.pumpWidget(_dialog(_rollup(endTime: null)));
    await tester.pump();

    expect(
      find.text('No frames captured for this target yet.'),
      findsNothing,
      reason: '0.17h was captured; it was rejected, which is a different thing',
    );
    expect(find.textContaining('No accepted frames yet'), findsOneWidget);
    expect(find.textContaining('0.2h captured'), findsWidgets);
  });

  testWidgets('accepted and captured integration are named separately',
      (tester) async {
    await tester.pumpWidget(_dialog(_rollup(endTime: null)));
    await tester.pump();

    expect(find.text('Integration (accepted)'), findsOneWidget);
    expect(find.text('Integration (captured)'), findsOneWidget);
    expect(
      find.text('Total integration'),
      findsNothing,
      reason: 'the unqualified label is what made 0.0h read as "all of it"',
    );
    expect(
      find.textContaining('h integration'),
      findsNothing,
      reason: 'the session row must say what it counts',
    );
    // The card carries a THIRD population: avg_hfr / avg_seeing come from the
    // session rows and count every frame, accepted or not. Leaving them bare
    // beside "Integration (accepted)" invites them to be read as accepted too.
    expect(find.text('Mean HFR (session avg)'), findsOneWidget);
    expect(find.text('Mean seeing (session avg)'), findsOneWidget);
    expect(find.text('Mean HFR'), findsNothing);
  });

  testWidgets('effective imaging is blank until a session closes',
      (tester) async {
    await tester.pumpWidget(_dialog(_rollup(endTime: null)));
    await tester.pump();

    expect(
      find.text('0.0%'),
      findsNothing,
      reason: 'no closed session means nothing to measure, not measured zero',
    );
    expect(find.text('Effective imaging'), findsOneWidget);
  });

  testWidgets('a closed session still gets its measured percentage',
      (tester) async {
    await tester
        .pumpWidget(_dialog(_rollup(endTime: DateTime.utc(2026, 8, 1, 1))));
    await tester.pump();

    expect(find.text('0.0%'), findsOneWidget);
  });

  testWidgets('the per-filter table and the goal bar name the same population',
      (tester) async {
    // 40 frames were taken and 20 accepted. CampaignFilterRollup.capturedFrames
    // and CampaignRollup.totalCapturedIntegrationSecs are BOTH accepted-only,
    // so calling either of them "captured" on a card whose session rows use
    // that word for all 40 rebuilds the contradiction the header tiles were
    // relabelled to remove.
    await tester.pumpWidget(_dialog(_partlyRejectedRollup()));
    await tester.pump();

    expect(find.textContaining('frames captured'), findsNothing);
    expect(find.text('8 frames accepted (no goal)'), findsOneWidget);
    expect(find.text('20/50 frames accepted'), findsOneWidget);

    // The goal bar's number is the accepted total (2.3h), not the 3.3h the
    // session row below it reports as captured.
    expect(find.textContaining('Accepted 2.3h of'), findsOneWidget);
    expect(find.textContaining('Captured 2.3h of'), findsNothing);
    expect(find.textContaining('3.33h captured'), findsOneWidget);
  });
}
