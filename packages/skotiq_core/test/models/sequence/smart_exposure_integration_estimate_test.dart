// Smart Exposure must count towards a sequence's integration estimate.
//
// The library card renders `sequences.estimated_duration_mins`, which
// `SequenceRepository` writes as `(sequence.totalIntegrationSecs / 60).ceil()`.
// `Sequence._estimateNodeIntegration` had an `ExposureNode` branch and no
// `SmartExposureNode` branch, so a sequence of one 10x60s Take Exposures plus
// one 10x60s Smart Exposure — 20 frames, 20 minutes — was stored and shown as
// "10m": exactly the plain-exposure half.
//
// These tests pin both ends: the model arithmetic, and the persisted column /
// `SequenceSummary` the card actually reads.

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

const _rootId = 'root';
const _exposureId = 'exposure';
const _smartId = 'smart';

/// Root instruction set over [children], or over [wrapper] when one is given
/// (the children are then [wrapper]'s, not the root's).
Sequence _sequenceOf(List<SequenceNode> children, {SequenceNode? wrapper}) {
  final root = InstructionSetNode(
    id: _rootId,
    name: 'Sequence',
    childIds: wrapper != null
        ? [wrapper.id]
        : [for (final node in children) node.id],
  );
  return Sequence.create(
    name: 'Test Sequence',
    nodes: {
      for (final node in [root, if (wrapper != null) wrapper, ...children])
        node.id: node,
    },
    rootNodeId: _rootId,
  );
}

ExposureNode _takeExposures() => ExposureNode(
  id: _exposureId,
  name: 'Take Exposures',
  count: 10,
  durationSecs: 60,
  parentId: _rootId,
);

SmartExposureNode _smartExposure({
  double integrationBudgetSecs = 0,
  bool loopUntilStopped = false,
  String parentId = _rootId,
}) => SmartExposureNode(
  id: _smartId,
  name: 'Smart Exposure',
  parentId: parentId,
  integrationBudgetSecs: integrationBudgetSecs,
  loopUntilStopped: loopUntilStopped,
  plans: const [FilterPlan(filterName: 'L', count: 10, durationSecs: 60)],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Sequence.totalIntegrationSecs with Smart Exposure', () {
    test('counts Smart Exposure plans alongside Take Exposures', () {
      final sequence = _sequenceOf([_takeExposures(), _smartExposure()]);

      // 10x60s TakeExposure + 10x60s SmartExposure = 20 frames, 1200s.
      expect(sequence.totalExposures, 20);
      expect(sequence.totalIntegrationSecs, 1200);
    });

    test('a count loop multiplies the Smart Exposure it wraps', () {
      final smart = _smartExposure(parentId: 'loop');
      final loop = LoopNode(
        id: 'loop',
        name: 'Capture Loop',
        conditionType: LoopConditionType.count,
        repeatCount: 3,
        childIds: [smart.id],
        parentId: _rootId,
      );
      final sequence = _sequenceOf([smart], wrapper: loop);

      expect(sequence.totalExposures, 30);
      expect(sequence.totalIntegrationSecs, 1800);
    });

    test('a disabled Smart Exposure contributes nothing', () {
      final sequence = _sequenceOf([
        _takeExposures(),
        _smartExposure().copyWith(isEnabled: false),
      ]);

      expect(sequence.totalIntegrationSecs, 600);
    });

    test('the integration budget caps the estimate', () {
      // The executor stops the node once accumulated integration reaches the
      // budget (smart_exposure.rs `integration_budget_exceeded`), so quoting
      // the full 600s of plans would be a number the run never reaches.
      final sequence = _sequenceOf([
        _smartExposure(integrationBudgetSecs: 300),
      ]);

      expect(sequence.totalIntegrationSecs, 300);
    });

    test('loop-until-stopped with a budget estimates the budget', () {
      // In this mode the executor ignores the per-plan counts entirely.
      final sequence = _sequenceOf([
        _smartExposure(loopUntilStopped: true, integrationBudgetSecs: 900),
      ]);

      expect(sequence.totalIntegrationSecs, 900);
      expect(sequence.estimateIntegrationSecs().isUnbounded, isFalse);
    });

    test('loop-until-stopped without a budget is unbounded, not 600s', () {
      // Only the surrounding target window can end it, so the sequence is
      // unbounded and the estimate is one rotation, matching how the
      // unbounded loop kinds report.
      final sequence = _sequenceOf([_smartExposure(loopUntilStopped: true)]);

      final estimate = sequence.estimateIntegrationSecs();
      expect(estimate.isUnbounded, isTrue);
      expect(estimate.estimatedSecs, 60);
    });

    test('the no-root-node fallback counts Smart Exposure too', () {
      final sequence = Sequence.create(
        name: 'Flat',
        nodes: {_exposureId: _takeExposures(), _smartId: _smartExposure()},
      );

      expect(sequence.rootNodeId, isNull);
      expect(sequence.totalIntegrationSecs, 1200);
    });
  });

  group('persisted duration the library card renders', () {
    late SkotiqDatabase database;
    late SequenceRepository repository;

    setUp(() {
      database = SkotiqDatabase.forTesting(NativeDatabase.memory());
      repository = SequenceRepository(database.sequencesDao);
    });

    tearDown(() async {
      await database.close();
    });

    test(
      'saving 10x60s TakeExposure + 10x60s SmartExposure stores 20m, not 10m',
      () async {
        final id = await repository.saveSequence(
          _sequenceOf([_takeExposures(), _smartExposure()]),
        );

        final row = await database.sequencesDao.getSequenceById(id);
        expect(row!.estimatedDurationMins, 20);

        final summaries = await repository.loadSequenceSummaries();
        final summary = summaries.singleWhere((s) => s.id == id);
        expect(summary.exposureCount, 2);
        // What the card's duration chip formats.
        expect(summary.totalIntegrationSecs, 1200);
      },
    );
  });
}
