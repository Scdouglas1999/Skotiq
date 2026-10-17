// What the exposure node's card says once its frames are on disk, driven
// through the real SequenceTree rather than the panel widget.
//
// Keying "this node finished" off `nodeStatus == NodeStatus.success` passes a
// test that pumps exactly that, and still reads zero in the running app: the
// per-node progress entries are GONE by the time the operator reads the card, so
// a 4x15s run whose Session Report says "Frames accepted 4/4" leaves the node
// reading "Exposure: No Filter - 0 / 4 frames" with four empty boxes above four
// R-labelled thumbnails. A run STOPPED at frame 1 still reads "1 / 4", which
// makes the zeroing look specific to the success path.
//
// So the input these tests encode is the real one: the card is still on screen
// (the panel deliberately persists for 20s after the node stops running) while
// the progress maps no longer hold anything for it.
//
// The card's other half is the filter: the node carries none of its own, but the
// run images through R and says so everywhere else — telemetry strip,
// thumbnails, FITS filenames, session report — so this header must not be the
// one place saying "No Filter", two rows under a target rollup reading
// "R 180s".

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequencer_density.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../harness/mock_database.dart' show inMemoryDatabaseOverride;

/// The node under test: four 15s frames, no filter chosen in the builder.
ExposureNode _exposure() => ExposureNode(durationSecs: 15, count: 4);

Future<void> _pumpTree(
  WidgetTester tester,
  ProviderContainer container,
  SequenceNode node,
) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(900, 900);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  container.read(currentSequenceProvider.notifier).createSequence(name: 'run');
  container.read(currentSequenceProvider.notifier).addNode(node);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(
          body: SequenceTree(colors: SkotiqColors.dark),
        ),
      ),
    ),
  );
  // liveValidationProvider debounces with a 500ms one-shot Timer on mutation.
  await tester.pump(const Duration(milliseconds: 600));
}

/// Drive the node through a complete four-frame run: running, frame 4 of 4
/// captured through filter R.
void _runAllFrames(ProviderContainer container, String nodeId) {
  final progress = container.read(sequenceProgressProvider.notifier);
  progress.updateNodeStatus(nodeId, NodeStatus.running);
  progress.updateProgress(currentFilter: 'R');
  progress.updateNodeStructuredProgress(
    nodeId,
    100,
    const ExposureInstructionProgressDetail(
        frame: 4, total: 4, durationSecs: 15),
  );
}

void main() {
  testWidgets(
    'the card keeps its frame count after the run clears the progress maps',
    (tester) async {
      final container = ProviderContainer(overrides: [
        inMemoryDatabaseOverride(),
        // These tests assert the comfortable card's inline content (frame
        // counters, filter line); the ledger row intentionally omits it.
        sequencerDensityProvider
            .overrideWith((ref) => SequencerDensity.comfortable),
      ]);
      addTearDown(container.dispose);

      final node = _exposure();
      await _pumpTree(tester, container, node);
      _runAllFrames(container, node.id);
      await tester.pump();

      // Sanity: while the run is live the card reports the frame in flight.
      expect(find.text('4 / 4 frames'), findsOneWidget);

      // The success path: the run's per-node entries disappear while the card
      // is still on screen inside its 20s persistence window.
      container.read(sequenceProgressProvider.notifier).reset();
      await tester.pump();

      expect(
        find.text('0 / 4 frames'),
        findsNothing,
        reason: 'a node that captured every frame must not report zero',
      );
      expect(find.text('4 / 4 frames'), findsOneWidget);
    },
  );

  testWidgets(
    'the card names the filter the run used when the node names none',
    (tester) async {
      final container = ProviderContainer(overrides: [
        inMemoryDatabaseOverride(),
        // These tests assert the comfortable card's inline content (frame
        // counters, filter line); the ledger row intentionally omits it.
        sequencerDensityProvider
            .overrideWith((ref) => SequencerDensity.comfortable),
      ]);
      addTearDown(container.dispose);

      final node = _exposure();
      expect(node.filter, isNull);

      await _pumpTree(tester, container, node);
      _runAllFrames(container, node.id);
      await tester.pump();

      expect(find.text('Exposure: No Filter'), findsNothing);
      expect(find.text('Exposure: R (current)'), findsOneWidget);
    },
  );

  testWidgets(
    'with no filter anywhere the card says the node has none set',
    (tester) async {
      final container = ProviderContainer(overrides: [
        inMemoryDatabaseOverride(),
        // These tests assert the comfortable card's inline content (frame
        // counters, filter line); the ledger row intentionally omits it.
        sequencerDensityProvider
            .overrideWith((ref) => SequencerDensity.comfortable),
      ]);
      addTearDown(container.dispose);

      final node = _exposure();
      await _pumpTree(tester, container, node);
      final progress = container.read(sequenceProgressProvider.notifier);
      progress.updateNodeStatus(node.id, NodeStatus.running);
      progress.updateNodeStructuredProgress(
        node.id,
        25,
        const ExposureInstructionProgressDetail(
            frame: 1, total: 4, durationSecs: 15),
      );
      await tester.pump();

      expect(find.text('Exposure: No filter set'), findsOneWidget);
    },
  );

  testWidgets(
    "a node's own filter still wins over the run's",
    (tester) async {
      final container = ProviderContainer(overrides: [
        inMemoryDatabaseOverride(),
        // These tests assert the comfortable card's inline content (frame
        // counters, filter line); the ledger row intentionally omits it.
        sequencerDensityProvider
            .overrideWith((ref) => SequencerDensity.comfortable),
      ]);
      addTearDown(container.dispose);

      final node = ExposureNode(durationSecs: 15, count: 4, filter: 'Ha');
      await _pumpTree(tester, container, node);
      _runAllFrames(container, node.id);
      await tester.pump();

      expect(find.text('Exposure: Ha'), findsOneWidget);
    },
  );
}
