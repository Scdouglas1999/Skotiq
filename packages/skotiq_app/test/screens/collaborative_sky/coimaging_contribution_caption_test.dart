import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/collaborative_sky/widgets/coimaging_session_card.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The card used to announce "You are pooling light here" from membership
/// alone, so a rig that declined the sharing-consent sheet was told its photons
/// were being pooled while nothing left the device.
void main() {
  Widget host(Widget child) => MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(body: SingleChildScrollView(child: child)),
      );

  const session = CoImagingSession(
    sessionId: 's1',
    ownerAccountId: 'owner',
    ownerDisplayName: 'Ada',
    targetName: 'NGC 7000',
    centerRaDeg: 314.75,
    centerDecDeg: 44.31,
    sharedTargetId: 42,
    status: 'active',
    combinedFrames: 0,
    combinedIntegrationSeconds: 0,
    activeTileId: null,
    batonHolder: null,
    batonHolderDisplayName: null,
    participants: [],
  );

  testWidgets('joined without sharing consent does not claim pooling',
      (tester) async {
    var enableSharingTaps = 0;
    await tester.pumpWidget(host(CoImagingSessionCard(
      session: session,
      joined: true,
      contributing: false,
      onEnableSharing: () => enableSharingTaps++,
      onLeave: () {},
    )));
    await tester.pumpAndSettle();

    expect(find.text('You are pooling light here'), findsNothing);
    expect(
        find.text('Joined — not contributing (sharing off)'), findsOneWidget);

    await tester.tap(find.text('Turn on sharing'));
    await tester.pumpAndSettle();
    expect(enableSharingTaps, 1);
  });

  testWidgets('joined while consent is still resolving does not claim pooling',
      (tester) async {
    await tester.pumpWidget(host(const CoImagingSessionCard(
      session: session,
      joined: true,
    )));
    await tester.pumpAndSettle();

    expect(find.text('You are pooling light here'), findsNothing);
    expect(find.text('Joined — checking sharing…'), findsOneWidget);
  });

  testWidgets('joined with sharing on still says pooling', (tester) async {
    await tester.pumpWidget(host(CoImagingSessionCard(
      session: session,
      joined: true,
      contributing: true,
      onLeave: () {},
    )));
    await tester.pumpAndSettle();

    expect(find.text('You are pooling light here'), findsOneWidget);
    expect(find.text('Turn on sharing'), findsNothing);
  });
}
