// The target card's LIVE readout must not render whole minutes.
//
// At seven seconds into a 4x3s target a minute-granular readout says "0/4 done -
// 0m / 1m", and at forty seconds "2/4 done - 1m / 1m", while the panel directly
// above it in the same card says "~34s": two halves of one card, two different
// units, one of them reporting real captured photons as zero.
//
// This pins the running readout to the same shared compact duration format the
// planned line beside it uses.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/target_header_card.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../harness/mock_database.dart' show inMemoryDatabaseOverride;

void main() {
  testWidgets('the live readout renders seconds under a minute',
      (tester) async {
    final container =
        ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
    addTearDown(container.dispose);

    // The live shape: one target, four 3-second frames — twelve seconds of
    // integration, which whole minutes can only render as "0m".
    final target = TargetHeaderNode(
      targetName: 'M42-TEST',
      raHours: 5.588,
      decDegrees: -5.39,
    );
    final exposure = ExposureNode(durationSecs: 3, count: 4);
    final editor = container.read(currentSequenceProvider.notifier);
    editor.createSequence(name: 'elapsed units');
    editor.addNode(target);
    editor.addNode(exposure, parentId: target.id);

    // Halfway through the node: two of four frames done (6s of 12s).
    final progress = container.read(sequenceProgressProvider.notifier);
    progress.updateNodeStatus(exposure.id, NodeStatus.running);
    progress.updateNodeProgress(exposure.id, 50, 'Frame 3/4');
    container.read(sequenceExecutionStateProvider.notifier).state =
        SequenceExecutionState.running;

    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1200, 1400);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: SingleChildScrollView(
              child: TargetHeaderCard(
                node: target,
                colors: SkotiqColors.dark,
                nodeStatus: NodeStatus.running,
                isMobile: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('2/4 done'), findsOneWidget);
    expect(
      find.text('0m / 0m'),
      findsNothing,
      reason: 'twelve seconds of integration is not zero minutes',
    );
    expect(find.text('6s / 12s'), findsOneWidget);
  });
}
