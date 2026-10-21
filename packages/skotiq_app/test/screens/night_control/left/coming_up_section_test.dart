// "Coming up" during a run and "The night" before one: each row's words
// come from its kind and fields, the next timed event says how far off it
// is, and estimated times carry "≈".
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/left/coming_up_section.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';

import '../fixtures/night_fixtures.dart';
import 'night_widget_test_support.dart';

Future<void> _pump(WidgetTester tester, NightHarness harness) => harness.pump(
      tester,
      const SizedBox(width: 272, child: NightComingUpSection()),
      size: const Size(272, 758),
    );

void main() {
  testWidgets('during a run: Coming up', (tester) async {
    await _pump(tester, NightHarness(board: NightFixtures.running()));
    expect(find.text('Coming up'), findsOneWidget);
    expect(find.text('after #45'), findsOneWidget);
    expect(find.text('6 frames or 1 °C change'), findsOneWidget);
    expect(find.text('01:58 · in 2 h 06 m'), findsOneWidget);
    expect(find.text('≈03:40 · NGC 891'), findsOneWidget);
    expect(find.text('05:44'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('before a run: The night', (tester) async {
    await _pump(tester, NightHarness(board: NightFixtures.ready()));
    expect(find.text('The night'), findsOneWidget);
    expect(find.text('18:18 · passed'), findsOneWidget);
    expect(find.text('19:48 · in 1 h 12 m'), findsOneWidget);
    expect(find.text('Moon 44%'), findsOneWidget);
    expect(find.text('sets 23:09'), findsOneWidget);
    expect(find.text('01:58'), findsOneWidget);
  });

  testWidgets('other cadences and an unset moon', (tester) async {
    await _pump(
      tester,
      NightHarness(
        board: NightFixtures.ready(),
        upcoming: const <UpcomingItemVm>[
          UpcomingItemVm(kind: UpcomingKind.dither, everyFrames: 3),
          UpcomingItemVm(
            kind: UpcomingKind.autofocus,
            every: Duration(hours: 1),
          ),
          UpcomingItemVm(kind: UpcomingKind.moon, moonIlluminationPct: 98),
        ],
      ),
    );
    expect(find.text('every 3 frames'), findsOneWidget);
    expect(find.text('every 1 h'), findsOneWidget);
    expect(find.text('Moon 98%'), findsOneWidget);
    expect(find.text('no moonset tonight'), findsOneWidget);
  });

  testWidgets('the next autofocus, the target sinking and the plan end',
      (tester) async {
    await _pump(
      tester,
      NightHarness(
        board: NightFixtures.running(),
        upcoming: <UpcomingItemVm>[
          const UpcomingItemVm(
            kind: UpcomingKind.autofocus,
            afterFrame: 52,
            tempDeltaC: 1,
          ),
          UpcomingItemVm(
            kind: UpcomingKind.targetLow,
            at: DateTime(2026, 10, 20, 3, 12),
            subject: 'NGC 891',
            limitDeg: 30,
          ),
          UpcomingItemVm(
            kind: UpcomingKind.planEnd,
            at: DateTime(2026, 10, 20, 4, 30),
          ),
        ],
      ),
    );
    expect(find.text('after #52 or 1 °C change'), findsOneWidget);
    expect(find.text('NGC 891 below 30°'), findsOneWidget);
    expect(find.textContaining('03:12'), findsOneWidget);
    expect(find.text('Plan ends'), findsOneWidget);
    expect(find.text('≈04:30'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('nothing coming up says so', (tester) async {
    await _pump(
      tester,
      NightHarness(
        board: NightFixtures.running(),
        upcoming: const <UpcomingItemVm>[],
      ),
    );
    expect(find.text('Nothing scheduled'), findsOneWidget);
  });
}
