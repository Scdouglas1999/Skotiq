// While the one-tap chain is still choosing or planning, the screen offers a
// way out. A first tap on a fresh linked client sat on "Planning the night…"
// for over a minute with nothing to press.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/tonight/one_tap_tonight_controller.dart';
import 'package:skotiq_app/screens/tonight/tonight_screen.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Future<void> _pump(
  WidgetTester tester,
  OneTapPhase phase,
  VoidCallback onCancel,
) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: TonightBodyView(
            colors: SkotiqColors.dark,
            state: OneTapTonightState(phase: phase),
            activeRun: null,
            targetAsync: const AsyncData<TargetSuggestion?>(null),
            onGo: () async {},
            onCancel: onCancel,
            onReset: () {},
            onRefreshPick: () {},
            morningSessionAsync: const AsyncData<int?>(null),
            onRefreshMorningReport: () {},
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('planning offers Cancel, and Cancel reaches the controller',
      (tester) async {
    var canceled = 0;
    await _pump(tester, OneTapPhase.planning, () => canceled++);

    expect(find.text('Planning the night…'), findsOneWidget);
    await tester.tap(find.widgetWithText(SkotiqButton, 'Cancel'));
    expect(canceled, 1);
  });

  testWidgets('a starting run offers no Cancel', (tester) async {
    await _pump(tester, OneTapPhase.starting, () {});

    expect(find.text('Starting run…'), findsOneWidget);
    expect(find.widgetWithText(SkotiqButton, 'Cancel'), findsNothing);
  });

  testWidgets('an idle screen offers no Cancel', (tester) async {
    await _pump(tester, OneTapPhase.idle, () {});

    expect(find.widgetWithText(SkotiqButton, 'Cancel'), findsNothing);
  });
}
