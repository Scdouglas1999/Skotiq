// The frame strip: per-frame HFR, the rejected frame marked, the newest
// ringed, tap to show, and the line before the run.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/center/frame_stage.dart';
import 'package:skotiq_app/screens/night_control/center/frame_strip.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../fixtures/night_fixtures.dart';
import 'center_test_support.dart';

void main() {
  testWidgets('each frame shows its HFR; the rejected one is marked',
      (tester) async {
    final handle = tester.ensureSemantics();
    await pumpCenter(
      tester,
      centerOverrides(NightFixtures.running()),
      child: const FrameStrip(),
      size: const Size(1000, FrameStrip.height),
    );
    expect(find.text('2.13'), findsWidgets);
    expect(find.text('#43'), findsOneWidget);

    // #37 (HFR 3.05) was rejected: its label says so and its HFR is in the
    // error tone.
    expect(
      find.bySemanticsLabel(
          RegExp(r'^Frame #37, Ha 180 s, HFR 3\.05, Rejected')),
      findsOneWidget,
    );
    final hfr = tester.widget<Text>(find.text('3.05'));
    expect(hfr.style?.color, SkotiqColors.dark.error);
    final kept = tester.widget<Text>(find.text('2.18'));
    expect(kept.style?.color, isNot(SkotiqColors.dark.error));

    // #43 is the newest.
    expect(
        find.bySemanticsLabel(RegExp(r'^Frame #43.*newest$')), findsOneWidget);
    handle.dispose();
  });

  testWidgets('tapping a frame shows it; tapping it again goes back',
      (tester) async {
    final board = NightFixtures.running();
    final container = await pumpCenter(
      tester,
      centerOverrides(board),
      child: const FrameStrip(),
      size: const Size(1000, FrameStrip.height),
    );
    await tester.tap(find.text('#37'));
    await tester.pump();
    expect(container.read(nightStageSelectionProvider), board.frames[5].id);
    await tester.tap(find.text('#37'));
    await tester.pump();
    expect(container.read(nightStageSelectionProvider), isNull);

    // The newest frame is the live one: tapping it never pins a selection.
    await tester.tap(find.text('#40'));
    await tester.pump();
    await tester.tap(find.text('#43'));
    await tester.pump();
    expect(container.read(nightStageSelectionProvider), isNull);
  });

  testWidgets('before the run: what lands here and the last session',
      (tester) async {
    await pumpCenter(
      tester,
      centerOverrides(
        NightFixtures.ready(),
        lastSession: NightLastSessionVm(
          startedAt: DateTime(2026, 10, 15, 19, 40),
          name: 'M74',
          frames: 84,
          integrationSecs: 4 * 3600 + 12 * 60,
          averageHfr: 2.13,
        ),
      ),
      child: const FrameStrip(),
      size: const Size(1000, FrameStrip.height),
    );
    expect(find.textContaining("Frames from tonight's run land here."),
        findsOneWidget);
    expect(
      find.textContaining('Last session, Oct 15: M74 · 84 frames'),
      findsOneWidget,
    );
    expect(find.textContaining('HFR 2.13'), findsOneWidget);
  });

  testWidgets('before the run with no history it says nothing more',
      (tester) async {
    await pumpCenter(
      tester,
      centerOverrides(NightFixtures.ready()),
      child: const FrameStrip(),
      size: const Size(1000, FrameStrip.height),
    );
    expect(find.textContaining("Frames from tonight's run land here."),
        findsOneWidget);
    expect(find.textContaining('Last session'), findsNothing);
  });
}
