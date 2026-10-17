// Pillar C ("Constellation") — follow-the-night card affordances.
//
// The card must surface the right baton control for its state:
//   * heldByMe   -> "Release" (+ "Plan tonight"), never "Take the baton",
//   * ready free  -> "Take the baton" (+ "Plan tonight"),
//   * not ready   -> no claim/release, but still "Plan tonight" (you can always
//                    queue a dark field into the planner).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/constellation/widgets/follow_the_night_card.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  Widget host(Widget child) => MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(body: SingleChildScrollView(child: child)),
      );

  FollowTheNightSuggestion suggestion({
    required bool heldByMe,
    required String? holder,
    required bool altitudeOk,
  }) =>
      FollowTheNightSuggestion(
        targetId: 7,
        targetName: 'Orion',
        raDeg: 83.6,
        decDeg: -5.4,
        swarmIntegrationSeconds: 7200,
        heldByMe: heldByMe,
        handoff: HandoffClaim(
          targetId: 7,
          activeTileId: 1234,
          holder: holder,
          altitudeOk: altitudeOk,
          claimToken: null,
          expiresAt: null,
        ),
      );

  testWidgets('a held card shows Release + Plan tonight, never Take the baton',
      (tester) async {
    var released = false;
    await tester.pumpWidget(host(FollowTheNightCard(
      suggestion: suggestion(heldByMe: true, holder: 'me', altitudeOk: true),
      onClaim: null,
      onRelease: () => released = true,
      onPlanTonight: () {},
    )));
    await tester.pumpAndSettle();

    expect(find.text('Release'), findsOneWidget);
    expect(find.text('Plan tonight'), findsOneWidget);
    expect(find.text('Take the baton'), findsNothing);

    await tester.tap(find.text('Release'));
    expect(released, isTrue);
  });

  testWidgets('a ready free card shows Take the baton + Plan tonight',
      (tester) async {
    await tester.pumpWidget(host(FollowTheNightCard(
      suggestion: suggestion(heldByMe: false, holder: null, altitudeOk: true),
      onClaim: () {},
      onRelease: null,
      onPlanTonight: () {},
    )));
    await tester.pumpAndSettle();

    expect(find.text('Take the baton'), findsOneWidget);
    expect(find.text('Plan tonight'), findsOneWidget);
    expect(find.text('Release'), findsNothing);
  });

  testWidgets('a not-ready card still offers Plan tonight', (tester) async {
    await tester.pumpWidget(host(FollowTheNightCard(
      suggestion:
          suggestion(heldByMe: false, holder: 'other', altitudeOk: false),
      onClaim: null,
      onRelease: null,
      onPlanTonight: () {},
    )));
    await tester.pumpAndSettle();

    expect(find.text('Plan tonight'), findsOneWidget);
    expect(find.text('Take the baton'), findsNothing);
    expect(find.text('Release'), findsNothing);
  });
}
