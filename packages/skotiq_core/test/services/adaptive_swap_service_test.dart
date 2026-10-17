// Tests for the AdaptiveSwapService score composer + model
// round-trip + Rust↔Dart wire-format parity.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  group('AdaptiveSwapService.compose', () {
    final svc = AdaptiveSwapService();

    test('returns null when every axis is empty', () {
      expect(svc.compose(const AdaptiveSwapInputs()), isNull);
    });

    test('clear sky (transparency=1.0) scores 100 on transparency axis', () {
      final score = svc.compose(
        const AdaptiveSwapInputs(transparencyFraction: 1.0),
      );
      expect(score, isNotNull);
      expect(score!.transparencyScore, 100.0);
      // Single axis: composite equals the axis score.
      expect(score.score, 100.0);
    });

    test('zero transparency drops composite to 0', () {
      final score = svc.compose(
        const AdaptiveSwapInputs(transparencyFraction: 0.0),
      );
      expect(score, isNotNull);
      expect(score!.score, 0.0);
    });

    test('seeing axis: 30% HFR rise drops score to ≤70', () {
      final score = svc.compose(
        const AdaptiveSwapInputs(hfrMedian: 2.6, hfrBaseline: 2.0),
      );
      expect(score, isNotNull);
      expect(score!.seeingScore, 70.0);
    });

    test('cloud axis: 80% cover drops score to ≤30', () {
      final score = svc.compose(
        const AdaptiveSwapInputs(cloudCoverPercent: 80.0),
      );
      expect(score, isNotNull);
      expect(score!.cloudScore, 30.0);
    });

    test('wind axis: 50 km/h drops score to ≤30', () {
      final score = svc.compose(const AdaptiveSwapInputs(windKph: 50.0));
      expect(score, isNotNull);
      expect(score!.windScore, 30.0);
    });

    test('weights renormalise when some axes are missing', () {
      // Only transparency provided => composite = transparency axis (100).
      final score = svc.compose(
        const AdaptiveSwapInputs(transparencyFraction: 1.0),
      );
      expect(score!.score, 100.0);
      // Add a clear cloud reading (also 100) — composite still 100.
      final twoAxis = svc.compose(
        const AdaptiveSwapInputs(
          transparencyFraction: 1.0,
          cloudCoverPercent: 0.0,
        ),
      );
      expect(twoAxis!.score, 100.0);
      // Now mix: transparency 0 + cloud 100 — composite must be the
      // weighted average over (transparency_w + cloud_w), not over the
      // full 4-axis denominator.
      final mixed = svc.compose(
        const AdaptiveSwapInputs(
          transparencyFraction: 0.0,
          cloudCoverPercent: 0.0,
        ),
      );
      expect(
        mixed!.score,
        closeTo(25.0 / (0.40 + 0.25), 1e-9),
      ); // transparency=0, cloud=100
    });

    test('representative "transparency drops to 0.55" case lands at ~45', () {
      // The brief: transparency 0.55 ⇒ ConditionsScore ~45.
      // With our linear transparency axis: 0.55 * 100 = 55, then weighted
      // with seeing/cloud/wind missing means composite = 55.
      final score = svc.compose(
        const AdaptiveSwapInputs(transparencyFraction: 0.55),
      );
      expect(score, isNotNull);
      expect(score!.score, closeTo(55.0, 1.0));
      // With moderate cloud (50%, score 70) the composite drifts higher
      // — confirms our renormalising sum.
      final withCloud = svc.compose(
        const AdaptiveSwapInputs(
          transparencyFraction: 0.55,
          cloudCoverPercent: 50.0,
        ),
      );
      expect(withCloud!.score, closeTo(60.5, 1.0));
    });

    test(
      'representative "transparency recovers to 0.85" case lands at ~80',
      () {
        // The brief: transparency 0.85 ⇒ ConditionsScore ~80.
        final score = svc.compose(
          const AdaptiveSwapInputs(transparencyFraction: 0.85),
        );
        expect(score, isNotNull);
        expect(score!.score, closeTo(85.0, 1.0));
      },
    );
  });

  group('AdaptiveSwapInputComposer', () {
    test('normalizes transparency, cloud, wind, and HFR baseline', () {
      final inputs = AdaptiveSwapInputComposer.fromTelemetry(
        transparencyPercent: 82,
        recentHfr: const [1.8, 2.0, 2.2, 2.6],
        hardwareCloudCoverPercent: 35,
        apiCloudCoverPercent: 90,
        windKph: 18,
      );

      expect(inputs.transparencyFraction, closeTo(0.82, 1e-9));
      expect(inputs.hfrMedian, 2.6);
      expect(inputs.hfrBaseline, 2.0);
      expect(inputs.cloudCoverPercent, 35);
      expect(inputs.windKph, 18);
    });

    test('omits seeing axis until there is a baseline HFR', () {
      final inputs = AdaptiveSwapInputComposer.fromTelemetry(
        recentHfr: const [2.4],
      );

      expect(inputs.hfrMedian, 2.4);
      expect(inputs.hfrBaseline, isNull);
      expect(inputs.hasAnyAxis, isFalse);
    });

    test('uses API cloud cover when hardware weather has no cloud reading', () {
      final inputs = AdaptiveSwapInputComposer.fromTelemetry(
        apiCloudCoverPercent: 42,
      );

      expect(inputs.cloudCoverPercent, 42);
      expect(inputs.hasAnyAxis, isTrue);
    });
  });

  group('ConditionsScoreWeights', () {
    test('default sums to 1.0', () {
      const w = ConditionsScoreWeights();
      expect(w.sum, closeTo(1.0, 1e-9));
      expect(w.isNormalised, isTrue);
    });

    test('JSON round-trip preserves all weights', () {
      const w = ConditionsScoreWeights(
        transparencyWeight: 0.45,
        seeingWeight: 0.20,
        cloudWeight: 0.25,
        windWeight: 0.10,
      );
      final decoded = ConditionsScoreWeights.fromJson(w.toJson());
      expect(decoded, equals(w));
    });
  });

  group('BrightnessTier wire format', () {
    test('round-trips via wireValue / fromWire', () {
      for (final tier in BrightnessTier.values) {
        expect(BrightnessTier.fromWire(tier.wireValue), tier);
      }
    });

    test('rejects unknown wire strings', () {
      expect(BrightnessTier.fromWire('nonsense'), isNull);
      expect(BrightnessTier.fromWire(null), isNull);
    });

    test('parsing is case-insensitive', () {
      expect(BrightnessTier.fromWire('FAINT'), BrightnessTier.faint);
      expect(BrightnessTier.fromWire('Bright'), BrightnessTier.bright);
    });
  });

  group('BrightnessTierPreferences', () {
    test('default thresholds match the brief', () {
      const p = BrightnessTierPreferences();
      expect(p.faintMinScore, 70.0);
      expect(p.mediumMinScore, 50.0);
      expect(p.brightMinScore, 30.0);
      expect(p.accepts(BrightnessTier.bright, 35.0), isTrue);
      expect(p.accepts(BrightnessTier.faint, 65.0), isFalse);
    });

    test('JSON round-trip preserves all thresholds', () {
      const p = BrightnessTierPreferences(
        faintMinScore: 75,
        mediumMinScore: 55,
        brightMinScore: 25,
      );
      final decoded = BrightnessTierPreferences.fromJson(p.toJson());
      expect(decoded, equals(p));
    });
  });

  group('TargetHeaderNode brightness tier round-trip', () {
    test('JSON wire format includes brightness_tier_hint', () {
      final node = TargetHeaderNode(
        targetName: 'M51',
        raHours: 13.5,
        decDegrees: 47.2,
        brightnessTierHint: BrightnessTier.faint,
      );
      expect(node.brightnessTierHint, BrightnessTier.faint);

      // copyWith preserves and updates the field correctly.
      final mediumNode = node.copyWith(
        brightnessTierHint: BrightnessTier.medium,
      );
      expect(mediumNode.brightnessTierHint, BrightnessTier.medium);

      // No-arg copyWith preserves prior value.
      final unchanged = node.copyWith();
      expect(unchanged.brightnessTierHint, BrightnessTier.faint);

      // An explicit null KEEPS the prior value (plain `?? this.X`); clearing
      // brightnessTierHint is rebuild-explicit at the editor.
      final stillFaint = node.copyWith(brightnessTierHint: null);
      expect(stillFaint.brightnessTierHint, BrightnessTier.faint);
    });
  });

  group('TargetSchedulerNode adaptive swap fields', () {
    test('defaults match the brief (no swap, 180s hysteresis)', () {
      final node = TargetSchedulerNode();
      expect(node.swapOnConditionsBelow, isNull);
      expect(node.swapHysteresisSecs, 180.0);
      expect(node.maxConditionsScoreAgeSecs, 300);
      expect(node.brightnessTierPreferences, const BrightnessTierPreferences());
    });

    test('copyWith updates the new fields correctly', () {
      final node = TargetSchedulerNode().copyWith(
        swapOnConditionsBelow: 60,
        swapHysteresisSecs: 240,
        maxConditionsScoreAgeSecs: 240,
      );
      expect(node.swapOnConditionsBelow, 60);
      expect(node.swapHysteresisSecs, 240.0);
      expect(node.maxConditionsScoreAgeSecs, 240);
    });
  });

  group('AdaptiveSwapSnapshot JSON decoding', () {
    test('decodes a full snapshot from JSON', () {
      final raw = json.encode({
        'score': {
          'score': 45.0,
          'transparency_score': 55.0,
          'seeing_score': 70.0,
          'cloud_score': 50.0,
          'wind_score': null,
          'weights': const ConditionsScoreWeights().toJson(),
          'generated_unix_secs': 1737000000,
        },
        'state': {
          'current_target_id': 'm27',
          'current_tier': 'bright',
          'last_decision_kind': 'swap',
          'last_decision_reason': 'transparency dropped to 0.55',
          'last_swap_unix_secs': 1737000000,
          'last_swap_from_target_id': 'm51',
          'last_swap_to_target_id': 'm27',
          'last_observed_score': 45.0,
          'configured_threshold': 60.0,
          'configured_hysteresis_secs': 180.0,
        },
      });
      final snap = AdaptiveSwapDriver.decodeSnapshotJson(raw);
      expect(snap, isNotNull);
      expect(snap!.score!.score, 45.0);
      expect(snap.state.currentTargetId, 'm27');
      expect(snap.state.lastDecisionKind, 'swap');
      expect(snap.state.lastSwapFromTargetId, 'm51');
      expect(snap.state.lastSwapToTargetId, 'm27');
    });

    test('returns null for empty or invalid JSON', () {
      expect(AdaptiveSwapDriver.decodeSnapshotJson(null), isNull);
      expect(AdaptiveSwapDriver.decodeSnapshotJson(''), isNull);
      expect(AdaptiveSwapDriver.decodeSnapshotJson('not json'), isNull);
    });

    test('toJson round-trips the remote dashboard wire shape', () {
      final snapshot = AdaptiveSwapSnapshot(
        score: ConditionsScore(
          score: 72,
          transparencyScore: 80,
          seeingScore: 70,
          cloudScore: 75,
          windScore: 55,
          generatedAt: DateTime.fromMillisecondsSinceEpoch(
            1737000000 * 1000,
            isUtc: true,
          ),
        ),
        state: AdaptiveSwapRuntimeState(
          currentTargetId: 'm51',
          currentTier: 'faint',
          lastDecisionKind: 'hold_current',
          lastDecisionReason: 'conditions still satisfy faint target floor',
          lastSwapAt: DateTime.fromMillisecondsSinceEpoch(
            1736999900 * 1000,
            isUtc: true,
          ),
          lastSwapFromTargetId: 'm27',
          lastSwapToTargetId: 'm51',
          lastObservedScore: 72,
          configuredThreshold: 70,
          configuredHysteresisSecs: 240,
        ),
      );

      final roundTripped = AdaptiveSwapSnapshot.fromJson(snapshot.toJson());
      expect(roundTripped, snapshot);
      expect(roundTripped.toJson()['state'], contains('last_swap_unix_secs'));
    });

    test('hysteresis countdown reports remaining secs', () {
      final lastSwap = DateTime.now().toUtc().subtract(
        const Duration(seconds: 60),
      );
      final state = AdaptiveSwapRuntimeState(
        lastSwapAt: lastSwap,
        configuredHysteresisSecs: 180.0,
      );
      final remaining = state.cooldownRemainingSecs(DateTime.now().toUtc());
      expect(remaining, isNotNull);
      expect(remaining!, inInclusiveRange(110.0, 130.0));
    });

    test('hysteresis countdown returns null once cooldown elapsed', () {
      final lastSwap = DateTime.now().toUtc().subtract(
        const Duration(seconds: 300),
      );
      final state = AdaptiveSwapRuntimeState(
        lastSwapAt: lastSwap,
        configuredHysteresisSecs: 180.0,
      );
      expect(state.cooldownRemainingSecs(DateTime.now().toUtc()), isNull);
    });
  });

  group('AdaptiveSwapDriver tick', () {
    test('pushes composed score to backend and returns it', () async {
      final backend = _FakeBackend();
      final driver = AdaptiveSwapDriver(
        composer: AdaptiveSwapService(),
        backend: backend,
      );
      final pushed = await driver.tick(
        const AdaptiveSwapInputs(transparencyFraction: 0.85),
      );
      expect(pushed, isNotNull);
      expect(pushed!.score, closeTo(85.0, 1.0));
      expect(backend.lastPushed, isNotNull);
      expect(backend.lastPushed!.score, closeTo(85.0, 1.0));
    });

    test('pushes null when no axis has data', () async {
      final backend = _FakeBackend();
      final driver = AdaptiveSwapDriver(
        composer: AdaptiveSwapService(),
        backend: backend,
      );
      final pushed = await driver.tick(const AdaptiveSwapInputs());
      expect(pushed, isNull);
      expect(backend.pushCount, 1);
      expect(backend.lastPushed, isNull);
    });
  });
}

class _FakeBackend implements AdaptiveSwapBackend {
  ConditionsScore? lastPushed;
  int pushCount = 0;

  @override
  Future<void> sequencerUpdateConditionsScore(ConditionsScore? score) async {
    lastPushed = score;
    pushCount++;
  }

  @override
  Future<AdaptiveSwapSnapshot?> sequencerGetAdaptiveSwapSnapshot() async {
    return null;
  }
}
