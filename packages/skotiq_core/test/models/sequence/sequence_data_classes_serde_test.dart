// Serde + value-semantics net for the non-SequenceNode data classes declared
// in `lib/src/models/sequence/sequence_models.dart`.
//
// Covers: MosaicPanelInfo, SequenceOverheadConfig, SequenceEstimate,
// AdaptiveExposureConfig, BrightnessTierPreferences,
// ConditionsScoreWeights, ConditionsScore, AdaptiveSwapRuntimeState,
// AdaptiveSwapSnapshot, FilterPlan, PhotometryQualityGates,
// TransparencyBackupPlan, Sequence, SequenceProgress.
//
// FilterBudgetEntry and IntegrationBudget are covered by
// `test/models/integration_budget_test.dart` and are not duplicated here.
//
// The TargetTrigger sealed family lives in
// `target_trigger_serde_test.dart`.
//
// SequenceNode subclasses live in `sequence_node_serde_test.dart`.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  group('MosaicPanelInfo', () {
    const sample = MosaicPanelInfo(
      mosaicName: 'M31 4x2',
      panelIndex: 3,
      totalPanels: 8,
      row: 0,
      column: 3,
    );

    test('to_json_shape_uses_snake_case_keys', () {
      // The wire keys are snake_case (`mosaic_name`, `panel_index`,
      // `total_panels`), not the camelCase a code generator defaults to.
      expect(
        sample.toJson(),
        equals({
          'mosaic_name': 'M31 4x2',
          'panel_index': 3,
          'total_panels': 8,
          'row': 0,
          'column': 3,
        }),
      );
    });

    test('json_round_trip_preserves_all_fields', () {
      final back = MosaicPanelInfo.fromJson(
        jsonDecode(jsonEncode(sample.toJson())) as Map<String, dynamic>,
      );
      expect(back, equals(sample));
    });

    test('copyWith_each_field_independently_mutable', () {
      expect(sample.copyWith(mosaicName: 'X').mosaicName, equals('X'));
      expect(sample.copyWith(panelIndex: 99).panelIndex, equals(99));
      expect(sample.copyWith(totalPanels: 16).totalPanels, equals(16));
      expect(sample.copyWith(row: 5).row, equals(5));
      expect(sample.copyWith(column: 6).column, equals(6));
    });

    test('copyWith_with_no_args_preserves_all_values', () {
      // MosaicPanelInfo uses the plain `?? this.X` pattern for ALL fields
      // (none are nullable).
      expect(sample.copyWith(), equals(sample));
    });

    test('equality_and_hash_match_for_same_payload', () {
      const a = MosaicPanelInfo(
        mosaicName: 'A',
        panelIndex: 0,
        totalPanels: 1,
        row: 0,
        column: 0,
      );
      const b = MosaicPanelInfo(
        mosaicName: 'A',
        panelIndex: 0,
        totalPanels: 1,
        row: 0,
        column: 0,
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(b.copyWith(panelIndex: 1))));
    });

    test('display_label_uses_one_based_index', () {
      expect(sample.displayLabel, equals('Panel 4/8'));
    });
  });

  group('SequenceOverheadConfig', () {
    test('default_constructor_uses_documented_defaults', () {
      const cfg = SequenceOverheadConfig();
      expect(cfg.slewSecs, equals(30.0));
      expect(cfg.autofocusSecs, equals(180.0));
      expect(cfg.filterChangeSecs, equals(10.0));
      expect(cfg.ditherSecs, equals(15.0));
      expect(cfg.meridianFlipSecs, equals(300.0));
      expect(cfg.guideAcquireSecs, equals(30.0));
      expect(cfg.plateSolveSecs, equals(15.0));
      expect(cfg.coolingSecs, equals(600.0));
      expect(cfg.warmingSecs, equals(300.0));
      expect(cfg.downloadOverheadPerExposureSecs, equals(3.0));
      expect(cfg.coverMoveSecs, equals(30.0));
      expect(cfg.centerTargetSecs, equals(45.0));
    });

    test('equality_via_equatable_props', () {
      // This class has NO toJson/fromJson and NO copyWith — it is a pure
      // Equatable values bag.
      const a = SequenceOverheadConfig(slewSecs: 25.0);
      const b = SequenceOverheadConfig(slewSecs: 25.0);
      const c = SequenceOverheadConfig(slewSecs: 30.0);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
    });
  });

  group('SequenceEstimate', () {
    test('total_estimated_includes_overhead', () {
      const e = SequenceEstimate(
        estimatedSecs: 3600,
        overheadSecs: 900,
        singleIterationSecs: 600,
        isUnbounded: false,
      );
      expect(e.totalEstimatedSecs, equals(4500));
    });

    test('format_returns_iter_marker_for_unbounded', () {
      const e = SequenceEstimate(
        estimatedSecs: 600,
        singleIterationSecs: 600,
        isUnbounded: true,
      );
      expect(e.format(), equals('10m/iter (unbounded)'));
    });

    test('format_omits_hours_when_lt_one_hour', () {
      const e = SequenceEstimate(
        estimatedSecs: 1800,
        singleIterationSecs: 1800,
        isUnbounded: false,
      );
      expect(e.format(), equals('30m'));
    });

    test('format_includes_hours_and_minutes_when_gt_one_hour', () {
      const e = SequenceEstimate(
        estimatedSecs: 7200 + 1800,
        singleIterationSecs: 9000,
        isUnbounded: false,
      );
      expect(e.format(), equals('2h 30m'));
    });

    test('format_with_overhead_collapses_to_integration_when_no_overhead', () {
      const e = SequenceEstimate(
        estimatedSecs: 3600,
        singleIterationSecs: 3600,
        isUnbounded: false,
      );
      expect(e.formatWithOverhead(), equals('1h 0m'));
    });

    test('format_with_overhead_includes_total_band', () {
      const e = SequenceEstimate(
        estimatedSecs: 23400, // 6h 30m
        overheadSecs: 9900, // 2h 45m
        singleIterationSecs: 23400,
        isUnbounded: false,
      );
      expect(
        e.formatWithOverhead(),
        equals('Integration: 6h 30m | Est. total: ~9h 15m'),
      );
    });

    test('equality_via_props_distinguishes_until_time', () {
      final now = DateTime.utc(2026, 1, 1);
      final a = SequenceEstimate(
        estimatedSecs: 60,
        singleIterationSecs: 60,
        isUnbounded: false,
        untilTime: now,
      );
      final b = SequenceEstimate(
        estimatedSecs: 60,
        singleIterationSecs: 60,
        isUnbounded: false,
        untilTime: now,
      );
      final c = SequenceEstimate(
        estimatedSecs: 60,
        singleIterationSecs: 60,
        isUnbounded: false,
        untilTime: now.add(const Duration(seconds: 1)),
      );
      expect(a, equals(b));
      expect(a, isNot(equals(c)));
    });
  });

  group('AdaptiveExposureConfig', () {
    const sample = AdaptiveExposureConfig(
      targetSnr: 40.0,
      referenceSkyBrightnessMag: 21.0,
      minExposureSecs: 10.0,
      maxExposureSecs: 300.0,
      perFilterEnabled: {'L': true, 'Ha': false},
      perFilterMinSecs: {'L': 5.0},
      perFilterMaxSecs: {'L': 120.0, 'Ha': 600.0},
      enabled: true,
    );

    test('to_json_shape_uses_snake_case_keys', () {
      // The wire keys are snake_case (`target_snr`,
      // `reference_sky_brightness_mag`, `min_exposure_secs`,
      // `max_exposure_secs`, `per_filter_enabled`, …, `enabled`).
      expect(
        sample.toJson(),
        equals({
          'target_snr': 40.0,
          'reference_sky_brightness_mag': 21.0,
          'min_exposure_secs': 10.0,
          'max_exposure_secs': 300.0,
          'per_filter_enabled': {'L': true, 'Ha': false},
          'per_filter_min_secs': {'L': 5.0},
          'per_filter_max_secs': {'L': 120.0, 'Ha': 600.0},
          'enabled': true,
        }),
      );
    });

    test('json_round_trip_preserves_all_fields_including_maps', () {
      final back = AdaptiveExposureConfig.fromJson(
        jsonDecode(jsonEncode(sample.toJson())) as Map<String, dynamic>,
      );
      expect(back, equals(sample));
    });

    test('from_json_applies_defaults_when_fields_missing', () {
      // Every field carries a fromJson default
      // (`(json['x'] as num?)?.toDouble() ?? <default>`), so a payload
      // missing a field decodes to the documented value rather than null.
      final back = AdaptiveExposureConfig.fromJson(const <String, dynamic>{});
      expect(back.targetSnr, equals(30.0));
      expect(back.referenceSkyBrightnessMag, equals(21.5));
      expect(back.minExposureSecs, equals(5.0));
      expect(back.maxExposureSecs, equals(600.0));
      expect(back.perFilterEnabled, isEmpty);
      expect(back.perFilterMinSecs, isEmpty);
      expect(back.perFilterMaxSecs, isEmpty);
      expect(back.enabled, isTrue);
    });

    test('copyWith_each_field_independently_mutable', () {
      expect(sample.copyWith(targetSnr: 50.0).targetSnr, equals(50.0));
      expect(
        sample
            .copyWith(referenceSkyBrightnessMag: 22.0)
            .referenceSkyBrightnessMag,
        equals(22.0),
      );
      expect(
        sample.copyWith(minExposureSecs: 1.0).minExposureSecs,
        equals(1.0),
      );
      expect(
        sample.copyWith(maxExposureSecs: 9999.0).maxExposureSecs,
        equals(9999.0),
      );
      expect(
        sample.copyWith(perFilterEnabled: const {'R': true}).perFilterEnabled,
        equals(const {'R': true}),
      );
      expect(
        sample.copyWith(perFilterMinSecs: const {'R': 2.0}).perFilterMinSecs,
        equals(const {'R': 2.0}),
      );
      expect(
        sample.copyWith(perFilterMaxSecs: const {'R': 999.0}).perFilterMaxSecs,
        equals(const {'R': 999.0}),
      );
      expect(sample.copyWith(enabled: false).enabled, isFalse);
    });

    test('copyWith_no_args_preserves_all_values', () {
      expect(sample.copyWith(), equals(sample));
    });

    test('equality_uses_map_equals_helper', () {
      // The class defines `_mapEq` because dart's `Map.==` is identity.
      // Two configs with structurally-equal maps must be ==.
      const a = AdaptiveExposureConfig(
        perFilterEnabled: {'L': true},
        perFilterMinSecs: {'L': 5.0},
        perFilterMaxSecs: {'L': 120.0},
      );
      const b = AdaptiveExposureConfig(
        perFilterEnabled: {'L': true},
        perFilterMinSecs: {'L': 5.0},
        perFilterMaxSecs: {'L': 120.0},
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      // Equality is deep over the collection fields, and the hash is built
      // from sorted keys so map order cannot change it.
    });

    test('is_enabled_for_filter_respects_per_filter_override', () {
      const cfg = AdaptiveExposureConfig(
        perFilterEnabled: {'L': true, 'Ha': false},
      );
      expect(cfg.isEnabledForFilter('L'), isTrue);
      expect(cfg.isEnabledForFilter('Ha'), isFalse);
      expect(
        cfg.isEnabledForFilter('R'),
        isFalse,
        reason:
            'unlisted filter when map non-empty falls back to "not enabled"',
      );
    });

    test('min_for_filter_returns_per_filter_value_when_present', () {
      const cfg = AdaptiveExposureConfig(
        minExposureSecs: 5.0,
        perFilterMinSecs: {'L': 1.0},
      );
      expect(cfg.minForFilter('L'), equals(1.0));
      expect(cfg.minForFilter('R'), equals(5.0));
      expect(cfg.minForFilter(null), equals(5.0));
    });

    test('max_for_filter_returns_per_filter_value_when_present', () {
      const cfg = AdaptiveExposureConfig(
        maxExposureSecs: 600.0,
        perFilterMaxSecs: {'L': 120.0},
      );
      expect(cfg.maxForFilter('L'), equals(120.0));
      expect(cfg.maxForFilter('R'), equals(600.0));
    });
  });

  // BrightnessTier enum
  group('BrightnessTier', () {
    test('wire_value_matches_lowercase_name', () {
      expect(BrightnessTier.faint.wireValue, equals('faint'));
      expect(BrightnessTier.medium.wireValue, equals('medium'));
      expect(BrightnessTier.bright.wireValue, equals('bright'));
    });

    test('from_wire_round_trips_each_tier', () {
      expect(BrightnessTier.fromWire('faint'), equals(BrightnessTier.faint));
      expect(BrightnessTier.fromWire('medium'), equals(BrightnessTier.medium));
      expect(BrightnessTier.fromWire('bright'), equals(BrightnessTier.bright));
    });

    test('from_wire_is_case_insensitive', () {
      expect(BrightnessTier.fromWire('FAINT'), equals(BrightnessTier.faint));
      expect(BrightnessTier.fromWire('Medium'), equals(BrightnessTier.medium));
    });

    test('from_wire_returns_null_for_unknown_and_null', () {
      // Unknown values return null so callers can fall back to "auto"
      // rather than silently accepting junk.
      expect(BrightnessTier.fromWire('bogus'), isNull);
      expect(BrightnessTier.fromWire(null), isNull);
    });
  });

  group('BrightnessTierPreferences', () {
    const sample = BrightnessTierPreferences(
      faintMinScore: 80.0,
      mediumMinScore: 55.0,
      brightMinScore: 35.0,
    );

    test('to_json_shape_uses_snake_case_keys', () {
      expect(
        sample.toJson(),
        equals({
          'faint_min_score': 80.0,
          'medium_min_score': 55.0,
          'bright_min_score': 35.0,
        }),
      );
    });

    test('json_round_trip', () {
      final back = BrightnessTierPreferences.fromJson(
        jsonDecode(jsonEncode(sample.toJson())) as Map<String, dynamic>,
      );
      expect(back, equals(sample));
    });

    test('from_json_defaults', () {
      final back = BrightnessTierPreferences.fromJson(
        const <String, dynamic>{},
      );
      expect(back.faintMinScore, equals(70.0));
      expect(back.mediumMinScore, equals(50.0));
      expect(back.brightMinScore, equals(30.0));
    });

    test('floor_for_tier_returns_correct_band', () {
      expect(sample.floorFor(BrightnessTier.faint), equals(80.0));
      expect(sample.floorFor(BrightnessTier.medium), equals(55.0));
      expect(sample.floorFor(BrightnessTier.bright), equals(35.0));
    });

    test('accepts_returns_true_when_score_meets_floor', () {
      expect(sample.accepts(BrightnessTier.bright, 35.0), isTrue);
      expect(sample.accepts(BrightnessTier.bright, 34.999), isFalse);
    });

    test('copyWith_each_field', () {
      expect(sample.copyWith(faintMinScore: 90.0).faintMinScore, equals(90.0));
      expect(
        sample.copyWith(mediumMinScore: 40.0).mediumMinScore,
        equals(40.0),
      );
      expect(
        sample.copyWith(brightMinScore: 20.0).brightMinScore,
        equals(20.0),
      );
      expect(sample.copyWith(), equals(sample));
    });
  });

  group('ConditionsScoreWeights', () {
    const sample = ConditionsScoreWeights(
      transparencyWeight: 0.5,
      seeingWeight: 0.2,
      cloudWeight: 0.2,
      windWeight: 0.1,
    );

    test('to_json_shape_uses_snake_case_keys', () {
      expect(
        sample.toJson(),
        equals({
          'transparency_weight': 0.5,
          'seeing_weight': 0.2,
          'cloud_weight': 0.2,
          'wind_weight': 0.1,
        }),
      );
    });

    test('json_round_trip', () {
      final back = ConditionsScoreWeights.fromJson(
        jsonDecode(jsonEncode(sample.toJson())) as Map<String, dynamic>,
      );
      expect(back, equals(sample));
    });

    test('from_json_defaults', () {
      final back = ConditionsScoreWeights.fromJson(const <String, dynamic>{});
      expect(back.transparencyWeight, equals(0.40));
      expect(back.seeingWeight, equals(0.25));
      expect(back.cloudWeight, equals(0.25));
      expect(back.windWeight, equals(0.10));
    });

    test('sum_and_is_normalised', () {
      expect(sample.sum, closeTo(1.0, 1e-9));
      expect(sample.isNormalised, isTrue);
      expect(
        const ConditionsScoreWeights(
          transparencyWeight: 0.5,
          seeingWeight: 0.5,
        ).isNormalised,
        isFalse,
      );
    });

    test('copyWith', () {
      expect(
        sample.copyWith(transparencyWeight: 0.1).transparencyWeight,
        equals(0.1),
      );
      expect(sample.copyWith(seeingWeight: 0.1).seeingWeight, equals(0.1));
      expect(sample.copyWith(cloudWeight: 0.1).cloudWeight, equals(0.1));
      expect(sample.copyWith(windWeight: 0.0).windWeight, equals(0.0));
      expect(sample.copyWith(), equals(sample));
    });
  });

  group('ConditionsScore', () {
    final generatedAt = DateTime.utc(2026, 5, 25, 12, 0, 0);
    final sample = ConditionsScore(
      score: 82.5,
      transparencyScore: 90.0,
      seeingScore: 70.0,
      cloudScore: 95.0,
      windScore: 60.0,
      weights: const ConditionsScoreWeights(),
      generatedAt: generatedAt,
    );

    test('to_json_uses_snake_case_and_unix_secs_for_generated_at', () {
      // `generatedAt` is serialised as `generated_unix_secs` (an int
      // seconds-since-epoch), NOT ISO 8601. This is a wire-protocol
      // contract — the Rust side (de)serialises the field as i64 via
      // `serde_with`.
      final json = sample.toJson();
      expect(json['score'], equals(82.5));
      expect(json['transparency_score'], equals(90.0));
      expect(json['seeing_score'], equals(70.0));
      expect(json['cloud_score'], equals(95.0));
      expect(json['wind_score'], equals(60.0));
      expect(json['weights'], isA<Map<String, dynamic>>());
      expect(
        json['generated_unix_secs'],
        equals(generatedAt.millisecondsSinceEpoch ~/ 1000),
      );
    });

    test('json_round_trip_preserves_score_and_generated_at', () {
      final back = ConditionsScore.fromJson(
        jsonDecode(jsonEncode(sample.toJson())) as Map<String, dynamic>,
      );
      expect(back, equals(sample));
    });

    test('from_json_falls_back_to_default_weights_when_weights_missing', () {
      // When 'weights' is missing or not a Map, the fallback is
      // `const ConditionsScoreWeights()` (the default instance).
      final back = ConditionsScore.fromJson(const {
        'score': 50.0,
        'generated_unix_secs': 1000,
      });
      expect(back.weights, equals(const ConditionsScoreWeights()));
    });

    test('from_json_parses_unix_secs_as_utc_datetime', () {
      // The fromJson does ` * 1000` and isUtc: true. Verify the
      // bit-exact behaviour because freezed's default JsonConverter
      // would NOT produce this — the conversion must keep a custom
      // converter.
      final back = ConditionsScore.fromJson(const {
        'score': 75.0,
        'generated_unix_secs': 1700000000,
      });
      expect(
        back.generatedAt,
        equals(
          DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000, isUtc: true),
        ),
      );
      expect(back.generatedAt.isUtc, isTrue);
    });

    test('quality_label_buckets', () {
      expect(
        ConditionsScore(score: 91, generatedAt: generatedAt).qualityLabel,
        equals('Pristine'),
      );
      expect(
        ConditionsScore(score: 80, generatedAt: generatedAt).qualityLabel,
        equals('Good'),
      );
      expect(
        ConditionsScore(score: 60, generatedAt: generatedAt).qualityLabel,
        equals('Degraded'),
      );
      expect(
        ConditionsScore(score: 10, generatedAt: generatedAt).qualityLabel,
        equals('Bad'),
      );
    });

    test('equality_via_props', () {
      final a = ConditionsScore(score: 1, generatedAt: generatedAt);
      final b = ConditionsScore(score: 1, generatedAt: generatedAt);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(
        a,
        isNot(equals(ConditionsScore(score: 2, generatedAt: generatedAt))),
      );
    });
  });

  group('AdaptiveSwapRuntimeState', () {
    final sample = AdaptiveSwapRuntimeState(
      currentTargetId: 't1',
      currentTier: 'medium',
      lastDecisionKind: 'continue',
      lastDecisionReason: 'sky still good',
      lastSwapAt: DateTime.utc(2026, 5, 25, 10, 0, 0),
      lastSwapFromTargetId: 't0',
      lastSwapToTargetId: 't1',
      lastObservedScore: 65.0,
      configuredThreshold: 50.0,
      configuredHysteresisSecs: 180.0,
    );

    test('to_json_shape_uses_snake_case_and_unix_secs', () {
      // `lastSwapAt` is serialised as `last_swap_unix_secs` (int seconds,
      // UTC-anchored). When null the field is null in JSON, not omitted.
      final json = sample.toJson();
      expect(json['current_target_id'], equals('t1'));
      expect(json['current_tier'], equals('medium'));
      expect(json['last_decision_kind'], equals('continue'));
      expect(json['last_decision_reason'], equals('sky still good'));
      expect(
        json['last_swap_unix_secs'],
        equals(sample.lastSwapAt!.toUtc().millisecondsSinceEpoch ~/ 1000),
      );
      expect(json['last_swap_from_target_id'], equals('t0'));
      expect(json['last_swap_to_target_id'], equals('t1'));
      expect(json['last_observed_score'], equals(65.0));
      expect(json['configured_threshold'], equals(50.0));
      expect(json['configured_hysteresis_secs'], equals(180.0));
    });

    test('json_round_trip_preserves_unix_seconds_precision', () {
      final back = AdaptiveSwapRuntimeState.fromJson(
        jsonDecode(jsonEncode(sample.toJson())) as Map<String, dynamic>,
      );
      // Note: round-tripping through unix seconds (int) loses sub-second
      // precision. Our sample has zero sub-second, so equality holds.
      expect(back.lastSwapAt, equals(sample.lastSwapAt));
      expect(back, equals(sample));
    });

    test('from_json_defaults_when_minimal_payload', () {
      final back = AdaptiveSwapRuntimeState.fromJson(const <String, dynamic>{});
      expect(back.currentTargetId, isNull);
      expect(back.lastSwapAt, isNull);
      expect(back.configuredHysteresisSecs, equals(180.0));
    });

    test('null_last_swap_serialises_as_null_field', () {
      const empty = AdaptiveSwapRuntimeState();
      final json = empty.toJson();
      expect(json['last_swap_unix_secs'], isNull);
    });

    test('cooldown_remaining_secs_returns_positive_during_hysteresis', () {
      final state = AdaptiveSwapRuntimeState(
        lastSwapAt: DateTime.utc(2026, 5, 25, 12, 0, 0),
        configuredHysteresisSecs: 180.0,
      );
      final now = state.lastSwapAt!.add(const Duration(seconds: 60));
      expect(state.cooldownRemainingSecs(now), closeTo(120.0, 1e-9));
    });

    test('cooldown_remaining_secs_returns_null_after_window', () {
      final state = AdaptiveSwapRuntimeState(
        lastSwapAt: DateTime.utc(2026, 5, 25, 12, 0, 0),
        configuredHysteresisSecs: 60.0,
      );
      final now = state.lastSwapAt!.add(const Duration(seconds: 120));
      expect(state.cooldownRemainingSecs(now), isNull);
    });

    test('cooldown_remaining_secs_returns_null_when_no_previous_swap', () {
      const state = AdaptiveSwapRuntimeState();
      expect(state.cooldownRemainingSecs(DateTime.utc(2026, 1, 1)), isNull);
    });

    test('equality_via_props', () {
      const a = AdaptiveSwapRuntimeState(currentTargetId: 'x');
      const b = AdaptiveSwapRuntimeState(currentTargetId: 'x');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(
        a,
        isNot(equals(const AdaptiveSwapRuntimeState(currentTargetId: 'y'))),
      );
    });
  });

  group('AdaptiveSwapSnapshot', () {
    final generatedAt = DateTime.utc(2026, 5, 25, 12, 0, 0);
    final sample = AdaptiveSwapSnapshot(
      score: ConditionsScore(score: 75.0, generatedAt: generatedAt),
      state: const AdaptiveSwapRuntimeState(currentTargetId: 't1'),
    );

    test('to_json_nests_score_and_state', () {
      final json = sample.toJson();
      expect(json['score'], isA<Map<String, dynamic>>());
      expect(json['state'], isA<Map<String, dynamic>>());
    });

    test('from_json_round_trip', () {
      final back = AdaptiveSwapSnapshot.fromJson(
        jsonDecode(jsonEncode(sample.toJson())) as Map<String, dynamic>,
      );
      expect(back, equals(sample));
    });

    test('from_json_treats_missing_score_as_null', () {
      final back = AdaptiveSwapSnapshot.fromJson(const <String, dynamic>{
        'state': <String, dynamic>{},
      });
      expect(back.score, isNull);
    });

    test('from_json_treats_missing_state_as_default_state', () {
      // `AdaptiveSwapSnapshot.fromJson` defaults `state` to
      // `const AdaptiveSwapRuntimeState()` when the field is missing or not
      // a Map; the Rust side relies on it for the "no telemetry yet" boot
      // state.
      final back = AdaptiveSwapSnapshot.fromJson(const <String, dynamic>{});
      expect(back.state, equals(const AdaptiveSwapRuntimeState()));
      expect(back.score, isNull);
    });
  });

  group('FilterPlan', () {
    const sample = FilterPlan(
      filterName: 'L',
      filterIndex: 0,
      count: 20,
      durationSecs: 60.0,
      gain: 100,
      offset: 10,
      binning: BinningMode.two,
      ditherEvery: 5,
    );

    test('to_json_shape_uses_snake_case_and_pascal_binning', () {
      // `binning` is encoded as a PascalCase string
      // ("One"/"Two"/"Three"/"Four"), NOT the BinningMode enum name
      // ("one"/"two"/...), matching the Rust serde enum. The mapping runs
      // through `_binningModeToRustString` / `_rustStringToBinningMode`.
      expect(
        sample.toJson(),
        equals({
          'filter_name': 'L',
          'filter_index': 0,
          'count': 20,
          'duration_secs': 60.0,
          'gain': 100,
          'offset': 10,
          'binning': 'Two',
          'dither_every': 5,
          // The DepthLock binding travels with the plan and is null until a
          // goal is attached; the key is always written so the Rust side's
          // Option<DepthGoalBinding> deserialises from a complete object.
          'depth_goal': null,
        }),
      );
    });

    test('json_round_trip_preserves_all_fields', () {
      final back = FilterPlan.fromJson(
        jsonDecode(jsonEncode(sample.toJson())) as Map<String, dynamic>,
      );
      expect(back, equals(sample));
    });

    test('json_round_trip_preserves_an_attached_depth_goal', () {
      const bound = FilterPlan(
        filterName: 'L',
        filterIndex: 0,
        count: 20,
        durationSecs: 60.0,
        gain: 100,
        offset: 10,
        binning: BinningMode.two,
        ditherEvery: 5,
        depthGoal: DepthGoalBinding(goalId: 'goal-7', revision: 3),
      );
      expect(bound.toJson()['depth_goal'], <String, dynamic>{
        'goal_id': 'goal-7',
        'revision': 3,
      });
      final back = FilterPlan.fromJson(
        jsonDecode(jsonEncode(bound.toJson())) as Map<String, dynamic>,
      );
      expect(back, equals(bound));
      expect(back.depthGoal?.goalId, 'goal-7');
      expect(back.depthGoal?.revision, 3);
    });

    test('from_json_applies_documented_defaults', () {
      // Missing-field defaults are:
      //   filter_name: '' (empty string), count: 10,
      //   duration_secs: 60.0, binning: BinningMode.one (via the
      //   default branch of `_rustStringToBinningMode`).
      // `filterName` is documented as required, yet fromJson defaults it to
      // '' — the decoder is deliberately more permissive than the
      // constructor.
      final back = FilterPlan.fromJson(const <String, dynamic>{});
      expect(back.filterName, equals(''));
      expect(back.count, equals(10));
      expect(back.durationSecs, equals(60.0));
      expect(back.binning, equals(BinningMode.one));
      expect(back.filterIndex, isNull);
    });

    test('copyWith_filterIndex_sentinel_allows_explicit_null', () {
      // FilterPlan.copyWith uses the `_sentinel` Object marker for
      // filterIndex / gain / offset / ditherEvery, so passing `null`
      // explicitly clears the field rather than keeping the current one.
      final cleared = sample.copyWith(filterIndex: null);
      expect(cleared.filterIndex, isNull);
      expect(
        cleared.gain,
        equals(sample.gain),
        reason: 'unrelated field preserved',
      );
    });

    test('copyWith_no_args_preserves_filterIndex', () {
      // The sentinel default means omitting filterIndex keeps the
      // existing value.
      final copy = sample.copyWith();
      expect(copy.filterIndex, equals(0));
      expect(copy, equals(sample));
    });

    test('copyWith_each_field', () {
      expect(sample.copyWith(filterName: 'R').filterName, equals('R'));
      expect(sample.copyWith(count: 1).count, equals(1));
      expect(sample.copyWith(durationSecs: 1.0).durationSecs, equals(1.0));
      expect(
        sample.copyWith(binning: BinningMode.four).binning,
        equals(BinningMode.four),
      );
      expect(sample.copyWith(gain: null).gain, isNull);
      expect(sample.copyWith(offset: null).offset, isNull);
      expect(sample.copyWith(ditherEvery: null).ditherEvery, isNull);
    });

    test('integration_secs_is_count_times_duration', () {
      expect(sample.integrationSecs, equals(20 * 60.0));
    });

    test('equality_and_hash_match_for_same_payload', () {
      const a = FilterPlan(filterName: 'L', count: 1, durationSecs: 10.0);
      const b = FilterPlan(filterName: 'L', count: 1, durationSecs: 10.0);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(b.copyWith(durationSecs: 11.0))));
    });
  });

  group('PhotometryQualityGates', () {
    const sample = PhotometryQualityGates(
      minSnr: 100.0,
      maxFwhmArcsec: 3.5,
      requireAllRefsVisible: false,
      maxAirmass: 2.0,
    );

    test('to_json_shape_uses_snake_case_keys', () {
      expect(
        sample.toJson(),
        equals({
          'min_snr': 100.0,
          'max_fwhm_arcsec': 3.5,
          'require_all_refs_visible': false,
          'max_airmass': 2.0,
        }),
      );
    });

    test('json_round_trip', () {
      final back = PhotometryQualityGates.fromJson(
        jsonDecode(jsonEncode(sample.toJson())) as Map<String, dynamic>,
      );
      expect(back, equals(sample));
    });

    test('from_json_applies_defaults', () {
      final back = PhotometryQualityGates.fromJson(const <String, dynamic>{});
      expect(back.minSnr, equals(50.0));
      expect(back.maxFwhmArcsec, equals(5.0));
      expect(back.requireAllRefsVisible, isTrue);
      expect(back.maxAirmass, equals(2.5));
    });

    test('copyWith_each_field', () {
      expect(sample.copyWith(minSnr: 200).minSnr, equals(200));
      expect(sample.copyWith(maxFwhmArcsec: 4.0).maxFwhmArcsec, equals(4.0));
      expect(
        sample.copyWith(requireAllRefsVisible: true).requireAllRefsVisible,
        isTrue,
      );
      expect(sample.copyWith(maxAirmass: 3.0).maxAirmass, equals(3.0));
      expect(sample.copyWith(), equals(sample));
    });
  });

  group('TransparencyBackupPlan', () {
    const sample = TransparencyBackupPlan(
      backupFilter: 'Lum',
      backupTargetId: 'tgt-bright',
      description: 'Bright target backup',
    );

    test('to_json_shape_uses_snake_case_keys', () {
      expect(
        sample.toJson(),
        equals({
          'backup_filter': 'Lum',
          'backup_target_id': 'tgt-bright',
          'description': 'Bright target backup',
        }),
      );
    });

    test('json_round_trip', () {
      final back = TransparencyBackupPlan.fromJson(
        jsonDecode(jsonEncode(sample.toJson())) as Map<String, dynamic>,
      );
      expect(back, equals(sample));
    });

    test('from_json_treats_missing_fields_as_null', () {
      final back = TransparencyBackupPlan.fromJson(const <String, dynamic>{});
      expect(back.backupFilter, isNull);
      expect(back.backupTargetId, isNull);
      expect(back.description, isNull);
    });

    test('is_empty_when_both_targets_and_filter_are_null', () {
      expect(const TransparencyBackupPlan().isEmpty, isTrue);
      expect(const TransparencyBackupPlan(backupFilter: 'L').isEmpty, isFalse);
      expect(
        const TransparencyBackupPlan(backupTargetId: 'x').isEmpty,
        isFalse,
      );
    });

    test('copyWith_sentinel_allows_explicit_null_for_each_nullable_field', () {
      // All three fields use sentinel-based copyWith, so a caller can clear
      // any of them with an explicit `null`.
      expect(sample.copyWith(backupFilter: null).backupFilter, isNull);
      expect(sample.copyWith(backupTargetId: null).backupTargetId, isNull);
      expect(sample.copyWith(description: null).description, isNull);
    });

    test('copyWith_no_args_preserves_all_values', () {
      expect(sample.copyWith(), equals(sample));
    });

    test('copyWith_each_field_independently_mutable', () {
      expect(sample.copyWith(backupFilter: 'B').backupFilter, equals('B'));
      expect(sample.copyWith(backupTargetId: 'x').backupTargetId, equals('x'));
      expect(sample.copyWith(description: 'd').description, equals('d'));
    });
  });

  group('Sequence', () {
    Sequence makeSequence() {
      final target = TargetHeaderNode(
        id: 't1',
        targetName: 'M31',
        raHours: 0.712,
        decDegrees: 41.269,
      );
      final exposure = ExposureNode(id: 'e1', durationSecs: 60.0, count: 10);
      // Fixed timestamps so two makeSequence() instances compare equal.
      // Sequence.create defaults createdAt/modifiedAt to DateTime.now(); on a
      // fine-resolution (microsecond) clock two calls produce different
      // timestamps and break value equality. A coarse (millisecond) clock
      // masked this, so it only surfaced on Linux.
      final fixedTs = DateTime.utc(2026, 1, 1);
      return Sequence.create(
        id: 'seq1',
        name: 'Test sequence',
        nodes: {
          target.id: target.copyWith(childIds: [exposure.id]),
          exposure.id: exposure.copyWith(parentId: target.id),
        },
        rootNodeId: target.id,
        createdAt: fixedTs,
        modifiedAt: fixedTs,
      );
    }

    test('total_exposures_sums_enabled_exposure_nodes', () {
      final seq = makeSequence();
      expect(seq.totalExposures, equals(10));
    });

    test('total_integration_secs_uses_estimate', () {
      final seq = makeSequence();
      expect(seq.totalIntegrationSecs, equals(600.0));
    });

    test('children_of_returns_canonical_order', () {
      final seq = makeSequence();
      expect(seq.childrenOf('t1').map((n) => n.id), equals(['e1']));
    });

    test('parent_of_returns_parent_id_for_child', () {
      final seq = makeSequence();
      expect(seq.parentOf('e1'), equals('t1'));
      expect(seq.parentOf('t1'), isNull);
    });

    test('descendants_of_returns_subtree_in_dfs', () {
      final seq = makeSequence();
      expect(seq.descendantsOf('t1'), equals(['e1']));
      expect(seq.descendantsOf('e1'), isEmpty);
      expect(seq.descendantsOf('does-not-exist'), isEmpty);
    });

    test('invariants_returns_no_issues_for_well_formed_sequence', () {
      final seq = makeSequence();
      expect(seq.invariants(), isEmpty);
    });

    test('target_headers_filters_disabled_targets', () {
      final enabled = TargetHeaderNode(
        id: 'a',
        targetName: 'A',
        raHours: 1.0,
        decDegrees: 10.0,
        orderIndex: 0,
      );
      final disabled = TargetHeaderNode(
        id: 'b',
        targetName: 'B',
        isEnabled: false,
        raHours: 2.0,
        decDegrees: 20.0,
        orderIndex: 1,
      );
      final seq = Sequence.create(
        id: 's',
        name: 'n',
        nodes: {enabled.id: enabled, disabled.id: disabled},
      );
      expect(seq.targetHeaders.map((t) => t.id), equals(['a']));
    });

    test('copyWith_each_field_independently_mutable', () {
      final seq = makeSequence();
      expect(seq.copyWith(name: 'new').name, equals('new'));
      expect(seq.copyWith(description: 'd').description, equals('d'));
      expect(seq.copyWith(isTemplate: true).isTemplate, isTrue);
      expect(
        seq.copyWith(estimatedDurationMins: 60).estimatedDurationMins,
        equals(60),
      );
      expect(seq.copyWith(databaseId: 99).databaseId, equals(99));
    });

    test('copyWith_no_args_preserves_all_values', () {
      // Sequence.copyWith uses plain `?? this.X` for all fields. With no
      // sentinel pattern, databaseId, rootNodeId and estimatedDurationMins
      // cannot be cleared through copyWith — passing null reads as "leave
      // alone".
      final seq = makeSequence();
      expect(seq.copyWith(), equals(seq));
    });

    test('equality_via_props_uses_nodes_map_and_excludes_derived_indexes', () {
      // `_childrenByParent` and `_parentById` are `late final` lazy indexes
      // and are NOT in Equatable's props, so two sequences with identical
      // `nodes` maps but freshly-built indexes are still equal. Derived
      // fields must never become equality-relevant.
      final a = makeSequence();
      final b = makeSequence();
      // Force the lazy indexes on one of them.
      a.childrenOf('t1');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('count_descendants_returns_subtree_size', () {
      final seq = makeSequence();
      expect(seq.countDescendants('t1'), equals(1));
      expect(seq.countDescendants('e1'), equals(0));
    });
  });

  group('SequenceProgress', () {
    test('default_constructor_has_idle_state_and_empty_progress', () {
      const p = SequenceProgress();
      expect(p.state, equals(SequenceExecutionState.idle));
      expect(p.totalExposures, equals(0));
      expect(p.completedExposures, equals(0));
      expect(p.nodeStatuses, isEmpty);
      expect(p.nodeProgressPercent, isEmpty);
      expect(p.nodeProgressDetail, isEmpty);
      expect(p.nodeProgressStructuredDetail, isEmpty);
    });

    test('progress_percent_returns_zero_when_no_exposures', () {
      const p = SequenceProgress();
      expect(p.progressPercent, equals(0.0));
    });

    test('progress_percent_is_ratio_of_completed_to_total', () {
      const p = SequenceProgress(totalExposures: 4, completedExposures: 1);
      expect(p.progressPercent, equals(0.25));
    });

    test('copyWith_each_field_independently_mutable', () {
      const p = SequenceProgress();
      expect(
        p.copyWith(state: SequenceExecutionState.running).state,
        equals(SequenceExecutionState.running),
      );
      expect(p.copyWith(currentNodeId: 'x').currentNodeId, equals('x'));
      expect(
        p.copyWith(currentNodeName: 'name').currentNodeName,
        equals('name'),
      );
      expect(
        p.copyWith(currentNodeStatus: NodeStatus.running).currentNodeStatus,
        equals(NodeStatus.running),
      );
      expect(p.copyWith(totalExposures: 10).totalExposures, equals(10));
      expect(p.copyWith(completedExposures: 5).completedExposures, equals(5));
      expect(
        p.copyWith(totalIntegrationSecs: 600).totalIntegrationSecs,
        equals(600),
      );
      expect(
        p.copyWith(completedIntegrationSecs: 60).completedIntegrationSecs,
        equals(60),
      );
      expect(p.copyWith(elapsedSecs: 100).elapsedSecs, equals(100));
      expect(
        p.copyWith(estimatedRemainingSecs: 30).estimatedRemainingSecs,
        equals(30),
      );
      expect(p.copyWith(currentTarget: 'M31').currentTarget, equals('M31'));
      expect(p.copyWith(currentFilter: 'L').currentFilter, equals('L'));
      expect(p.copyWith(message: 'msg').message, equals('msg'));
      expect(
        p.copyWith(nodeStatuses: const {'a': NodeStatus.success}).nodeStatuses,
        equals(const {'a': NodeStatus.success}),
      );
      expect(
        p.copyWith(nodeProgressPercent: const {'a': 50.0}).nodeProgressPercent,
        equals(const {'a': 50.0}),
      );
      expect(
        p.copyWith(nodeProgressDetail: const {'a': 'x'}).nodeProgressDetail,
        equals(const {'a': 'x'}),
      );
    });

    test('copyWith_no_args_preserves_all_values', () {
      // All nullable fields use plain `?? this.X`, so an explicit null
      // cannot clear them through copyWith.
      const p = SequenceProgress(currentNodeId: 'x', totalExposures: 5);
      expect(p.copyWith(), equals(p));
    });

    test('equality_via_props', () {
      const a = SequenceProgress(totalExposures: 5);
      const b = SequenceProgress(totalExposures: 5);
      const c = SequenceProgress(totalExposures: 6);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
    });
  });
}
