// The shell's own run bar stands down on Tonight, whose header carries the
// same run controls; everywhere else it stays, so navigating away mid-run
// never strands the run.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/night_control_screen.dart';
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
  test('Tonight is the dashboard route, with or without a query', () {
    expect(isTonightLocation('/dashboard'), isTrue);
    expect(isTonightLocation('/dashboard?tab=guide'), isTrue);
    expect(isTonightLocation('/sequencer'), isFalse);
    expect(isTonightLocation('/tonight'), isFalse,
        reason: '/tonight is the one-tap flow, not this screen');
  });

  testWidgets('the mini bar hides on Tonight during a run', (tester) async {
    await _pumpBar(tester, kTonightRoutePath);
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
