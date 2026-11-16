import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';

/// A Smart Exposure of [plans] alone in a sequence.
Sequence _smartExposure({required bool rotateFilters}) {
  final smart = SmartExposureNode(
    id: 'smart',
    parentId: 'root',
    rotateFilters: rotateFilters,
    plans: const [
      FilterPlan(filterName: 'L', count: 10, durationSecs: 60),
      FilterPlan(filterName: 'R', count: 10, durationSecs: 60),
    ],
  );
  final root = InstructionSetNode(id: 'root', childIds: [smart.id]);
  return Sequence.create(
    name: 'LR',
    rootNodeId: root.id,
    nodes: {root.id: root, smart.id: smart},
  );
}

void main() {
  test('a rotating Smart Exposure is timed with a filter change per frame, a '
      'draining one with one per filter', () {
    const overhead = SequenceOverheadConfig(
      filterChangeSecs: 10,
      downloadOverheadPerExposureSecs: 0,
    );
    const estimator = SequenceTimeEstimator(overhead: overhead);
    final now = DateTime.utc(2026, 11, 16, 2);
    final rotating = estimator.estimateTotalDuration(
      _smartExposure(rotateFilters: true),
      now,
    );
    final draining = estimator.estimateTotalDuration(
      _smartExposure(rotateFilters: false),
      now,
    );
    // 20 frames of 60 s either way.
    expect(rotating - draining, const Duration(seconds: (20 - 2) * 10));
  });
}
