// The Saved library card read "QA M35 Plan · 2m" for a plan the Builder
// estimated at "~2h 49m" (qa-rig RIG-18): the stored estimate counted one
// pass of a loop-until-stopped Smart Exposure. It now stores the Builder's
// own rollup.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/providers/sequence/node_duration_provider.dart';

void main() {
  test('the saved estimate is the Builder rollup of the whole plan', () {
    final smart = SmartExposureNode(
      id: 'smart',
      parentId: 'root',
      loopUntilStopped: true,
      plans: const [
        FilterPlan(filterName: 'L', count: 60, durationSecs: 20),
        FilterPlan(filterName: 'R', count: 60, durationSecs: 20),
      ],
    );
    final root = InstructionSetNode(id: 'root', childIds: const ['smart']);
    final sequence = Sequence.create(
      id: 'seq',
      name: 'M35',
      nodes: {root.id: root, smart.id: smart},
      rootNodeId: root.id,
    );

    final secs = sequenceRollupSecs(sequence);
    // 120 frames of 20 s, plus download and filter changes.
    expect(secs, greaterThan(120 * 20));
    expect(
      secs,
      closeTo(const SequenceTimeEstimator().nodeDuration(smart).inSeconds, 1),
    );
  });

  test('the Saved card reads the same length as the Builder', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = SequenceRepository(
      db.sequencesDao,
      runsDao: db.sequenceRunsDao,
    );
    final smart = SmartExposureNode(
      id: 'smart',
      parentId: 'root',
      loopUntilStopped: true,
      plans: const [
        FilterPlan(filterName: 'L', count: 60, durationSecs: 20),
        FilterPlan(filterName: 'R', count: 60, durationSecs: 20),
      ],
    );
    final root = InstructionSetNode(id: 'root', childIds: const ['smart']);
    final sequence = Sequence.create(
      id: 'seq',
      name: 'M35',
      nodes: {root.id: root, smart.id: smart},
      rootNodeId: root.id,
    );
    await repo.saveSequence(sequence);

    final summary = (await repo.loadSequenceSummaries()).single;
    expect(
      summary.totalIntegrationSecs,
      (sequenceRollupSecs(sequence) / 60).ceil() * 60,
    );
  });
}
