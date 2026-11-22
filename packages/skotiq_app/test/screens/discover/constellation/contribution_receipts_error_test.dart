import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/discover/constellation/constellation_ui_providers.dart';
import 'package:skotiq_app/screens/discover/constellation/shared_target_detail_screen.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

import '../../../harness/harness.dart';

void main() {
  const target = SharedTarget(
    targetId: 42,
    name: 'M31',
    raDeg: 10.68,
    decDeg: 41.27,
    integrationSeconds: 3600,
    contributors: 2,
    activeTileId: null,
    radiusDeg: 2,
  );

  testWidgets('receipt failure is visible and retryable', (tester) async {
    var attempts = 0;

    await pumpAppScreen(
      tester,
      const SharedTargetDetailScreen(target: target),
      size: const Size(1280, 1000),
      extraOverrides: [
        isConstellationHostActionEnabledProvider.overrideWithValue(true),
        sharedTargetsProvider.overrideWith((ref) async => const [target]),
        yourContributionSecondsProvider(target).overrideWith((ref) async => 0),
        myContributionsProvider.overrideWith((ref) async {
          attempts++;
          if (attempts == 1) throw Exception('receipt database unavailable');
          return const [];
        }),
      ],
    );

    expect(find.textContaining('Contribution receipts unavailable'),
        findsOneWidget);
    expect(find.text('Retry receipts'), findsOneWidget);
    expect(attempts, 1);

    await tester.tap(find.text('Retry receipts'));
    await tester.pumpAndSettle();

    expect(attempts, 2);
    expect(
        find.textContaining('Contribution receipts unavailable'), findsNothing);
  });

  // The detail screen's "subtract your contribution exactly" promise is backed
  // by a Retract on each receipt that reaches the service.
  testWidgets('Retract on a receipt retracts that tile', (tester) async {
    final service = _MockConstellationService();
    when(() => service.joinedTargets).thenReturn(const []);
    when(() => service.retractTile(any())).thenAnswer(
      (_) async =>
          const RetractionReceipt(retracted: true, totalFramesAfter: 9),
    );

    await pumpAppScreen(
      tester,
      const SharedTargetDetailScreen(target: target),
      size: const Size(1280, 1000),
      extraOverrides: [
        constellationServiceProvider.overrideWithValue(service),
        isConstellationHostActionEnabledProvider.overrideWithValue(true),
        sharedTargetsProvider.overrideWith((ref) async => const [target]),
        yourContributionSecondsProvider(target).overrideWith((ref) async => 0),
        myContributionsProvider.overrideWith(
          (ref) async => const [
            ContributionRecord(
              tileId: 17,
              contributionId: 'c-17',
              contributedFrames: 3,
              contributedIntegrationSeconds: 900,
              lastContributedAt: null,
            ),
          ],
        ),
      ],
    );

    await tester.tap(find.text('Retract').first);
    await tester.pumpAndSettle();
    expect(find.text('Retract this contribution?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Retract'));
    await tester.pumpAndSettle();

    verify(() => service.retractTile(17)).called(1);
  });
}

class _MockConstellationService extends Mock implements ConstellationService {}
