// The shell's own run bar stands down on Tonight, whose header carries the
// same run controls; everywhere else it stays, so navigating away mid-run
// never strands the run.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/router/app_routes.dart';
import 'package:skotiq_app/widgets/running_sequence_mini_bar.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

Future<void> _pumpBar(WidgetTester tester, String location) async {
  await pumpAppScreen(
    tester,
    RunningSequenceMiniBar(currentLocation: location),
    size: const Size(1000, 400),
    settle: false,
    extraOverrides: [
      sequenceExecutionStateProvider
          .overrideWith((ref) => SequenceExecutionState.running),
    ],
  );
  await tester.pump();
}

void main() {
  test('Tonight carries the run controls; the one-tap flow does not', () {
    bool showsRunControls(String location) =>
        AppRoute.of(location)!.showsItself.contains(ShellOverlay.runControls);
    expect(showsRunControls('/dashboard'), isTrue);
    expect(showsRunControls('/dashboard?tab=guide'), isTrue);
    expect(showsRunControls('/sequencer'), isTrue);
    expect(showsRunControls('/weather'), isFalse);
    expect(showsRunControls('/tonight'), isFalse,
        reason: '/tonight is the one-tap flow, not this screen');
  });

  testWidgets('the mini bar hides on Tonight during a run', (tester) async {
    await _pumpBar(tester, AppRoute.tonight.path);
    expect(find.byTooltip('Skip'), findsNothing);
    expect(find.byTooltip('Pause'), findsNothing);
  });

  testWidgets('the mini bar stays on other screens during a run',
      (tester) async {
    await _pumpBar(tester, '/weather');
    expect(find.byTooltip('Pause'), findsOneWidget,
        reason: 'non-vacuous: the same run shows the bar off Tonight');
  });
}
