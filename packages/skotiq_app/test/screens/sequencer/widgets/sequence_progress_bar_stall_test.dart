// What the progress bar promises while the run is standing still.
//
// A meridian flip whose plate solve fails after frame 4 sends the executor into
// its retry ladder —
//
//   04:10:43.815  ✗ Plate solving and centering FAILED: Plate solve failed
//   04:10:43.815  Retry 2/4 scheduled in 60 seconds...
//   04:11:51.795  Retry 3/4 scheduled in 120 seconds...
//
// — and for two and a half minutes the bar reads `~1m 8s · done ~00:12:13`,
// unchanged at 00:12:53 and again at 00:13:24: a promised finish time that comes
// and goes while no frame is captured. The estimate is fed by completed frames,
// so a run that stops capturing keeps its last one forever.
//
// The input encoded here is the hard one: the run is *nominally* running, its
// status is healthy, and only the passage of time without progress
// distinguishes it from a run that is working.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_progress_bar.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The waveF run: 8 planned frames of 15 s each, 4 captured, flip retrying.
const _waveFRun = SequenceProgress(
  state: SequenceExecutionState.running,
  currentNodeId: 'node-2',
  currentNodeName: 'Take Exposures',
  totalExposures: 8,
  completedExposures: 4,
  totalIntegrationSecs: 120,
  completedIntegrationSecs: 60,
  elapsedSecs: 240,
  estimatedRemainingSecs: 68,
  currentTarget: 'New Target',
);

class _FixedProgressNotifier extends SequenceProgressNotifier {
  _FixedProgressNotifier(SequenceProgress initial) {
    state = initial;
  }
}

Widget _harness(SequenceProgress progress) => ProviderScope(
      overrides: [
        sequenceExecutionStateProvider
            .overrideWith((ref) => SequenceExecutionState.running),
        sequenceProgressProvider
            .overrideWith((ref) => _FixedProgressNotifier(progress)),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Builder(
          builder: (ctx) => Scaffold(
            body: SequenceProgressBar(colors: SkotiqColors.of(ctx)),
          ),
        ),
      ),
    );

void main() {
  testWidgets(
    'a run frozen in a flip retry stops promising a finish time',
    (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1400, 400);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(_harness(_waveFRun));
      await tester.pump(const Duration(milliseconds: 16));

      // While the run is moving, the estimate is offered as usual.
      expect(
        find.textContaining('done ~'),
        findsOneWidget,
        reason: 'a progressing run may offer a finish time',
      );

      // 15 s subs: 2 x 15 s of cadence + 60 s of slack = 90 s of allowed
      // silence. The waveF run was quiet for 150 s before the operator stopped
      // it, and the finish time was still on screen.
      await tester.pump(const Duration(seconds: 150));

      expect(
        find.textContaining('done ~'),
        findsNothing,
        reason: 'a run that has not captured a frame for longer than its own '
            'frame cadence cannot promise when it will finish',
      );
      expect(find.textContaining('no progress for'), findsOneWidget);
    },
  );

  testWidgets(
    'a long sub is not accused of stalling between frames',
    (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1400, 400);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      // 6 x 600 s subs: 20 minutes of silence between frames is normal here, so
      // a stall warning would fire on a healthy run.
      const longSubs = SequenceProgress(
        state: SequenceExecutionState.running,
        currentNodeId: 'node-1',
        totalExposures: 6,
        completedExposures: 1,
        totalIntegrationSecs: 3600,
        completedIntegrationSecs: 600,
        elapsedSecs: 620,
        estimatedRemainingSecs: 3000,
      );

      await tester.pumpWidget(_harness(longSubs));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(minutes: 9));

      expect(find.textContaining('no progress for'), findsNothing);
      expect(find.textContaining('done ~'), findsOneWidget);
    },
  );

  test('the stall threshold scales with the run\'s own frame cadence', () {
    // 8 x 15 s
    expect(
      runStallThreshold(_waveFRun),
      const Duration(seconds: 90),
    );
    // 6 x 600 s
    expect(
      runStallThreshold(const SequenceProgress(
        totalExposures: 6,
        totalIntegrationSecs: 3600,
      )),
      const Duration(seconds: 1260),
    );
    // A run with no planned integration gives us nothing to judge against, and
    // inventing a threshold would be a guess presented as a fact.
    expect(runStallThreshold(const SequenceProgress()), isNull);
  });
}
