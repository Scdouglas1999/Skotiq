// After a run that captured 4 of 4 frames, the exposure node's progress card
// must not read "Exposure: No Filter — 0 / 4 frames" with all four boxes empty,
// directly above a strip of the four captured thumbnails. The live per-frame
// detail is cleared on the success path, so a card that depends on it falls back
// to frame 0 — while a run STOPPED at 2 frames still reads "2 / 4", which makes
// the reset look specific to success.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/node_progress_panels.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Future<void> _pumpPanel(
  WidgetTester tester, {
  required NodeStatus status,
  String? progressDetail,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(
        body: Builder(
          builder: (context) => getProgressPanelForNode(
            node: ExposureNode(
              id: 'exp',
              durationSecs: 15,
              count: 4,
              filter: 'R',
            ),
            colors: SkotiqColors.of(context),
            progressPercent: status == NodeStatus.success ? 100 : 50,
            progressDetail: progressDetail,
            nodeStatus: status,
          ),
        ),
      ),
    ),
  );
}

void main() {
  // The input a real run produces: the card is handed the LAST progress line a
  // successful run wrote — "Completed 4/4", from `ExposureCompleted` — while
  // the node's status has not reached it. A parser that only knows the
  // "Frame n/m" wording renders "0 / 4 frames" above four thumbnails.
  testWidgets('a run that captured every frame never reads 0 / N',
      (tester) async {
    await _pumpPanel(
      tester,
      status: NodeStatus.running,
      progressDetail: 'Completed 4/4',
    );

    expect(find.text('4 / 4 frames'), findsOneWidget);
    expect(find.text('0 / 4 frames'), findsNothing);
  });

  testWidgets('a node between frames counts the frames already captured',
      (tester) async {
    await _pumpPanel(
      tester,
      status: NodeStatus.running,
      progressDetail: 'Completed 2/4',
    );

    expect(find.text('2 / 4 frames'), findsOneWidget);
  });

  testWidgets('a completed node reports every frame it captured',
      (tester) async {
    // The success path clears the per-frame detail — the state a
    // detail-derived count reads as 0 / 4.
    await _pumpPanel(tester, status: NodeStatus.success);

    expect(find.text('4 / 4 frames'), findsOneWidget);
    expect(find.text('0 / 4 frames'), findsNothing);
  });

  testWidgets('a running node still reports the frame in flight',
      (tester) async {
    await _pumpPanel(
      tester,
      status: NodeStatus.running,
      progressDetail: 'Frame 2/4',
    );

    expect(find.text('2 / 4 frames'), findsOneWidget);
  });
}
