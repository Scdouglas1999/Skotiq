import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/collaborative_sky/widgets/coimaging_session_card.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  Widget host(Widget child) => MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(body: SingleChildScrollView(child: child)),
      );

  CoImagingParticipant participant(String? name) => CoImagingParticipant(
        sessionId: 's1',
        accountId: 'a-$name',
        displayName: name,
        rigId: 'rig-$name',
        role: 'contribute',
        membershipToken: null,
        framingOffsetIndex: 0,
        framingOffsetRaArcsec: 0,
        framingOffsetDecArcsec: 0,
        contributedFrames: 10,
        contributedIntegrationSeconds: 600,
        active: true,
      );

  CoImagingSession session({
    String status = 'active',
    String? batonHolderDisplayName = 'Ada',
    List<CoImagingParticipant> participants = const [],
  }) =>
      CoImagingSession(
        sessionId: 's1',
        ownerAccountId: 'owner',
        ownerDisplayName: 'Ada',
        targetName: 'NGC 7000',
        centerRaDeg: 314.7,
        centerDecDeg: 44.5,
        sharedTargetId: 42,
        status: status,
        combinedFrames: 240,
        combinedIntegrationSeconds: 7200,
        activeTileId: 99,
        batonHolder: 'owner',
        batonHolderDisplayName: batonHolderDisplayName,
        participants: participants,
      );

  testWidgets('in-progress session shows combined depth + a Join button',
      (tester) async {
    await tester.pumpWidget(host(CoImagingSessionCard(
      session: session(
        participants: [participant('Ada'), participant('Carl')],
      ),
      onJoin: () {},
    )));
    await tester.pumpAndSettle();

    expect(find.text('NGC 7000'), findsOneWidget);
    expect(find.text('Live'), findsOneWidget);
    // Combined integration (7200s -> 2.0h) and frame count are surfaced.
    expect(find.text('2.0h'), findsOneWidget);
    expect(find.text('240'), findsOneWidget);
    // Contributor attribution + active-imager line.
    expect(find.text('Ada & Carl'), findsOneWidget);
    expect(find.text('Live · Ada imaging now'), findsOneWidget);
    expect(find.text('Join session'), findsOneWidget);
  });

  testWidgets('joining state shows a spinner label and no tap-through',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(host(CoImagingSessionCard(
      session: session(),
      joining: true,
      onJoin: () => taps++,
    )));
    await tester.pump();

    expect(find.text('Joining…'), findsOneWidget);
    expect(find.text('Join session'), findsNothing);
  });

  testWidgets('unknown membership shows progress and authorizes no mutation',
      (tester) async {
    var joins = 0;
    var leaves = 0;
    await tester.pumpWidget(host(CoImagingSessionCard(
      session: session(),
      joined: null,
      onJoin: () => joins++,
      onLeave: () => leaves++,
    )));
    await tester.pump();

    expect(find.text('Checking membership…'), findsOneWidget);
    expect(find.text('Join session'), findsNothing);
    expect(find.text('Leave'), findsNothing);
    expect(joins, 0);
    expect(leaves, 0);
  });

  testWidgets('membership error exposes Retry but no Join or Leave',
      (tester) async {
    var retries = 0;
    await tester.pumpWidget(host(CoImagingSessionCard(
      session: session(),
      joined: null,
      membershipErrorMessage: 'The local membership store could not be read.',
      onRetryMembership: () => retries++,
      onJoin: () => fail('unknown membership must not authorize Join'),
      onLeave: () => fail('unknown membership must not authorize Leave'),
    )));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not verify membership'), findsOneWidget);
    expect(find.text('Join session'), findsNothing);
    expect(find.text('Leave'), findsNothing);
    await tester.tap(find.text('Retry'));
    expect(retries, 1);
  });

  testWidgets('a joined session shows the confirmation, never a Join button',
      (tester) async {
    await tester.pumpWidget(host(CoImagingSessionCard(
      session: session(),
      joined: true,
      // The pooling caption is a claim about contribution, not membership, so
      // it now requires sharing consent on record.
      contributing: true,
      onJoin: null,
    )));
    await tester.pumpAndSettle();

    expect(find.text('You are pooling light here'), findsOneWidget);
    expect(find.text('Join session'), findsNothing);
  });

  testWidgets('a closed (complete) session shows Closed and no Join',
      (tester) async {
    await tester.pumpWidget(host(CoImagingSessionCard(
      session: session(status: 'closed'),
      onJoin: () {},
    )));
    await tester.pumpAndSettle();

    // 'Closed' shows in both the status pill and the baton status line.
    expect(find.text('Closed'), findsWidgets);
    expect(find.text('Live'), findsNothing);
    expect(find.text('Join session'), findsNothing);
  });

  testWidgets('tapping Join fires the callback', (tester) async {
    var joined = false;
    await tester.pumpWidget(host(CoImagingSessionCard(
      session: session(),
      onJoin: () => joined = true,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Join session'));
    expect(joined, isTrue);
  });
}
