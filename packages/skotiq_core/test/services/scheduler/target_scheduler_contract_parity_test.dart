// Dart<->Rust CONTRACT parity for the in-sequence TargetScheduler weights.
//
// STEP-3 boundary pin (NO runtime rewrite): the in-sequence TargetSchedulerNode
// preview now consumes the SAME shared planetarium `ScoringWeights` contract
// the planner uses (via `TargetSchedulerNode.scoringWeights`). The actual
// in-sequence scoring runtime is the Rust `scheduling::scoring::ScoringWeights`
// /  `TargetSchedulerConfig`. This test pins the cross-language WIRE CONTRACT —
// field set, defaults, and factor ORDERING — so the Dart node, the shared
// planetarium ScoringWeights, and the Rust serde struct cannot silently drift.
//
// It does NOT exercise the Rust runtime (that needs the native build + on-sky
// validation). It asserts the Dart side matches the values the Rust source
// declares, and parses the Rust source as the source-of-truth for the defaults
// so a future edit to either side trips this canary.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

void main() {
  group('TargetScheduler Dart<->Rust weight contract', () {
    test(
      'node preview weights view IS the shared planetarium ScoringWeights',
      () {
        final node = TargetSchedulerNode();
        final w = node.scoringWeights;
        // The node's five duplicated fields delegate to the one contract.
        expect(w.altitudeWeight, node.altitudeWeight);
        expect(w.moonDistanceWeight, node.moonDistanceWeight);
        expect(w.transitProximityWeight, node.transitProximityWeight);
        expect(w.darknessWeight, node.darknessWeight);
        expect(w.airmassWeight, node.airmassWeight);
      },
    );

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

    test('factor ORDER is pinned (alt, moon, transit, darkness, airmass)', () {
      const w = ScoringWeights();
      final names = w
          .factors(
            altitudeScore: 0,
            moonDistanceScore: 0,
            transitProximityScore: 0,
            darknessScore: 0,
            airmassScore: 0,
          )
          .map((f) => f.name)
          .toList();
      expect(names, [
        'altitude',
        'moonDistance',
        'transitProximity',
        'darkness',
        'airmass',
      ]);
    });

    test('Rust source declares the SAME defaults + field set (canary)', () {
      // Locate the Rust scoring source relative to the monorepo root.
      final candidates = [
        File('../../native/skotiq_native/sequencer/src/scheduling/scoring.rs'),
        File(
          '${Directory.current.path}/../../native/skotiq_native/sequencer/src/scheduling/scoring.rs',
        ),
      ];
      final rust = candidates.firstWhere(
        (f) => f.existsSync(),
        orElse: () => candidates.first,
      );
      if (!rust.existsSync()) {
        // The native tree is not always present in every checkout/CI shard.
        // Skip rather than fail spuriously; the pure-Dart pins above still run.
        return;
      }
      final src = rust.readAsStringSync();

      // Field set + ordering: the snake_case mirror of the Dart fields.
      final fieldOrder = <String>[
        'altitude_weight',
        'moon_distance_weight',
        'transit_proximity_weight',
        'darkness_weight',
        'airmass_weight',
      ];
      var lastIndex = -1;
      for (final field in fieldOrder) {
        final idx = src.indexOf('pub $field: f64');
        expect(
          idx,
          greaterThan(lastIndex),
          reason: 'Rust field "$field" missing or out of contract order',
        );
        lastIndex = idx;
      }

      // Defaults declared in `impl Default for ScoringWeights`.
      const expectedDefaults = {
        'altitude_weight': '0.25',
        'moon_distance_weight': '0.25',
        'transit_proximity_weight': '0.20',
        'darkness_weight': '0.15',
        'airmass_weight': '0.15',
      };
      expectedDefaults.forEach((field, value) {
        expect(
          src.contains('$field: $value'),
          isTrue,
          reason:
              'Rust default for "$field" drifted from the pinned $value; '
              'update BOTH sides + the on-sky note if intentional.',
        );
      });
    });
  });
}
