// The TargetScheduler step's weights as the app writes them. The run's
// defaults are checked against the same node's wire golden by
// target_scheduler_default_weights.rs in the sequencer crate.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_astro/skotiq_astro.dart';

void main() {
  group('TargetScheduler Dart<->Rust weight contract', () {
    test('the step preview scores with the step\'s own weights', () {
      final w = TargetSchedulerNode(
        altitudeWeight: 0.1,
        moonDistanceWeight: 0.2,
        transitProximityWeight: 0.3,
        darknessWeight: 0.15,
        airmassWeight: 0.25,
      ).scoringWeights;
      expect(w.altitudeWeight, 0.1);
      expect(w.moonDistanceWeight, 0.2);
      expect(w.transitProximityWeight, 0.3);
      expect(w.darknessWeight, 0.15);
      expect(w.airmassWeight, 0.25);
    });

    test('Dart defaults match the pinned cross-language defaults', () {
      final node = TargetSchedulerNode();
      // These five magic numbers are the wire contract shared by:
      //  - planetarium ScoringWeights() defaults
      //  - Rust scoring::ScoringWeights::default()
      //  - Rust TargetSchedulerConfig serde defaults
      expect(node.altitudeWeight, 0.25);
      expect(node.moonDistanceWeight, 0.25);
      expect(node.transitProximityWeight, 0.20);
      expect(node.darknessWeight, 0.15);
      expect(node.airmassWeight, 0.15);
      expect(node.minScoreToRun, 30.0);

      const planetarium = ScoringWeights();
      expect(node.altitudeWeight, planetarium.altitudeWeight);
      expect(node.moonDistanceWeight, planetarium.moonDistanceWeight);
      expect(node.transitProximityWeight, planetarium.transitProximityWeight);
      expect(node.darknessWeight, planetarium.darknessWeight);
      expect(node.airmassWeight, planetarium.airmassWeight);
    });
  });
}
