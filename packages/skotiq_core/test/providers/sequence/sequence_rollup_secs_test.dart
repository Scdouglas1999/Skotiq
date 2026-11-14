// The Saved library card read "QA M35 Plan · 2m" for a plan the Builder
// estimated at "~2h 49m" (qa-rig RIG-18): the stored estimate counted one
// pass of a loop-until-stopped Smart Exposure. It now stores the Builder's
// own rollup. A block that loops until its target's window closes has no
// length a saved plan can store (the Builder bills it by tonight's window, or
// says "until target ends"), so such a plan stores none rather than one
// rotation or its per-filter counts.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';

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

    expect(sequenceRollupSecs(sequence), 0);

    // With counts the plan has a length: 120 frames of 20 s, plus download
    // and filter changes.
    final counted = Sequence.create(
      id: 'seq',
      name: 'M35',
      nodes: {
        root.id: root,
        smart.id: SmartExposureNode(
          id: 'smart',
          parentId: 'root',
          plans: smart.plans,
        ),
      },
      rootNodeId: root.id,
    );
    final secs = sequenceRollupSecs(counted);
    expect(secs, greaterThan(120 * 20));
    expect(
      secs,
      closeTo(
        const SequenceTimeEstimator()
            .nodeDuration(counted.nodes['smart']!)
            .inSeconds,
        1,
      ),
    );
  });

  test('the Saved card reads the same length as the Builder', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = LocalSequenceRepository(
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
