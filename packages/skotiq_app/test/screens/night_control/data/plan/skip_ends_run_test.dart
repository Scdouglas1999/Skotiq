// A Skip on the plan's last imaging step ends the night: the run goes
// straight to its closing steps, and a park moves the mount. Every Skip
// control asks first then; a Skip that leaves imaging to do, or one a loop may
// bring back, goes ahead at once.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_plan_inputs.dart';
import 'package:skotiq_app/screens/night_control/data/plan/plan_steps_provider.dart';
import 'package:skotiq_app/screens/sequencer/widgets/mobile_playback_bar.dart';
import 'package:skotiq_app/services/command_action_result.dart';
import 'package:skotiq_app/services/run_control/run_control.dart';
import 'package:skotiq_app/services/sequence_action_service.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The shape of the one-tap plan ("Image tonight"): cool and unpark, the
/// target's block ending in its Smart Exposure (with its meridian flip
/// trigger), then warm and park.
Sequence _plan({LoopNode? root}) => Sequence.create(
      name: 'M74 Plan',
      rootNodeId: 'root',
      nodes: {
        'root': root ??
            InstructionSetNode(
              id: 'root',
              name: 'M74 Plan',
              childIds: const ['cool', 'unpark', 'm74', 'warm', 'park'],
            ),
        'cool': CoolCameraNode(id: 'cool', parentId: 'root', orderIndex: 0),
        'unpark': UnparkNode(id: 'unpark', parentId: 'root', orderIndex: 1),
        'm74': TargetHeaderNode(
          id: 'm74',
          name: 'M74',
          targetName: 'M74',
          raHours: 1.61,
          decDegrees: 15.78,
          parentId: 'root',
          orderIndex: 2,
          childIds: const ['af', 'lights', 'flip'],
        ),
        'af': AutofocusNode(id: 'af', parentId: 'm74', orderIndex: 0),
        'lights':
            SmartExposureNode(id: 'lights', parentId: 'm74', orderIndex: 1),
        'flip': MeridianFlipNode(id: 'flip', parentId: 'm74', orderIndex: 2),
        'warm': WarmCameraNode(id: 'warm', parentId: 'root', orderIndex: 3),
        'park': ParkNode(id: 'park', parentId: 'root', orderIndex: 4),
      },
    );

LoopNode _rootLoop(int count) => LoopNode(
      id: 'root',
      conditionType: LoopConditionType.count,
      repeatCount: count,
      childIds: const ['cool', 'unpark', 'm74', 'warm', 'park'],
    );

NightPlanEntry _step(NightPlanTree tree, String id) =>
    tree.steps[tree.stepIndexOf(id)];

class _Actions extends Fake implements SequenceActionService {
  int skips = 0;
  @override
  Future<CommandActionResult> skip({bool showFeedback = true}) async {
    skips++;
    return CommandActionResult.ok;
  }
}

void main() {
  test('the last imaging step before warm and park ends the night', () {
    final tree = buildNightPlanTree(_plan());
    expect(
      closingStepsAfterSkip(tree, _step(tree, 'lights'))?.map((s) => s.node.id),
      ['warm', 'park'],
    );
    final once = buildNightPlanTree(_plan(root: _rootLoop(1)));
    expect(closingStepsAfterSkip(once, _step(once, 'lights')), isNotNull);
  });

  test('a step with imaging after it, or one that may run again, does not', () {
    final tree = buildNightPlanTree(_plan());
    expect(closingStepsAfterSkip(tree, _step(tree, 'af')), isNull);
    final looped = buildNightPlanTree(_plan(root: _rootLoop(2)));
    expect(closingStepsAfterSkip(looped, _step(looped, 'lights')), isNull);
  });

  test('skipping a closing step is not asked about', () {
    final tree = buildNightPlanTree(_plan());
    expect(closingStepsAfterSkip(tree, _step(tree, 'warm')), isNull);
    expect(closingStepsAfterSkip(tree, _step(tree, 'park')), isNull);
  });

  testWidgets('the phone Skip asks before ending the night', (tester) async {
    final tree = buildNightPlanTree(_plan());
    final actions = _Actions();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          nightPlanTreeProvider.overrideWithValue(tree),
          nightActiveStepProvider.overrideWithValue(_step(tree, 'lights')),
          sequenceActionServiceProvider.overrideWithValue(actions),
          sequencerRunTransportProvider.overrideWithValue(
            const RunTransport(
              phase: NightRunPhase.running,
              pauseResume: RunControl.enabled(),
              skip: RunControl.enabled(),
              stop: RunControl.enabled(),
            ),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: Builder(
              builder: (context) =>
                  MobilePlaybackBar(colors: context.skotiqColors),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Skip'));
    await tester.pumpAndSettle();
    expect(find.text('Skip the last imaging step?'), findsOneWidget);
    expect(actions.skips, 0);

    await tester.tap(find.text('Skip and end the night'));
    await tester.pumpAndSettle();
    expect(actions.skips, 1);
  });
}
