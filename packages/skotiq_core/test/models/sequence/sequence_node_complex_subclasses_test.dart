// Cover for SequenceNode subclasses with non-trivial copyWith semantics,
// configuration round-trips, or special-case behaviour.
//
// Covered here:
//   * TargetHeaderNode (4 nullable fields use plain keep-or-replace;
//     clearing is rebuild-explicit)
//   * LoopNode
//   * ConditionalNode (safetyMonitorId uses plain keep-or-replace)
//   * RecoveryNode (no JSON, but has toRustTriggerConfig sliced by
//                   trigger_type_serialization_test.dart; here we test
//                   the data shape)
//   * ExposureNode (copyWith uses plain `?? this.adaptiveExposure`
//     semantics; the "clear override" path is rebuild-explicit at the
//     editor)
//   * NotificationNode is covered by `notification_node_test.dart`; the
//     complementary copyWith-per-field tests live here.
//   * MeridianFlipNode (plain copyWith; the sticky-override UX heuristic
//     moved to `applyMeridianFlipEdit(...)` in the editor layer and is
//     covered by `skotiq_app`'s widget tests)
//   * TargetSchedulerNode (swapOnConditionsBelow uses plain
//     keep-or-replace; the signature is typed, so there is no
//     ArgumentError path)
//   * SmartExposureNode
//   * LiveStackingNode (authToken / watermarkText use plain
//     keep-or-replace; clearing is rebuild-explicit at the editor)
//   * SciencePhotometryNode (gain/offset use plain keep-or-replace;
//     clearing is rebuild-explicit at the editor; fromRustConfigJson
//     defaults pinned)
//
// The SequenceNode subclasses that are STRUCTURALLY simple (plain `??`
// copyWith for every field) live in
// `sequence_node_simple_subclasses_test.dart` and are not duplicated here.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  group('TargetHeaderNode', () {
    TargetHeaderNode makeM31() => TargetHeaderNode(
      id: 'th-m31',
      targetName: 'M31',
      // Realistic — Andromeda: 0h 42m 44.3s, +41° 16' 9"
      raHours: 0.712303,
      decDegrees: 41.269167,
      rotation: 0.0,
      priority: 1,
      minAltitude: 30.0,
      maxAltitude: 80.0,
      startAfter: DateTime.utc(2026, 9, 1, 22, 0),
      endBefore: DateTime.utc(2026, 9, 2, 5, 0),
      integrationBudget: const IntegrationBudget(totalSecs: 14400),
      startWhen: const AltitudeAboveTrigger(35.0),
      endWhen: const AltitudeBelowTrigger(30.0),
      triggerPollIntervalSecs: 60,
      brightnessTierHint: BrightnessTier.faint,
    );

    test('node_type_and_required_devices_pin', () {
      final n = makeM31();
      expect(n.nodeType, equals('TargetHeader'));
      expect(n.iconName, equals('target'));
      expect(n.category, equals(NodeCategory.target));
      expect(n.requiredDevices, equals({DeviceType.mount}));
    });

    test('copyWith_no_args_preserves_all_nullable_fields', () {
      // copyWith is plain `?? this.X` for every nullable field, so omitting
      // the arg keeps the existing value.
      final n = makeM31();
      final copy = n.copyWith();
      expect(copy.integrationBudget, equals(n.integrationBudget));
      expect(copy.startWhen, equals(n.startWhen));
      expect(copy.endWhen, equals(n.endWhen));
      expect(copy.brightnessTierHint, equals(n.brightnessTierHint));
    });

    test('copyWith_explicit_null_now_keeps_under_plain_semantics', () {
      // Passing `null` is indistinguishable from omitting the arg — both
      // keep the current value. Clearing goes through the rebuild-explicit
      // recipe pinned below.
      final n = makeM31();
      final keep = n.copyWith(
        integrationBudget: null,
        startWhen: null,
        endWhen: null,
        brightnessTierHint: null,
      );
      expect(keep.integrationBudget, equals(n.integrationBudget));
      expect(keep.startWhen, equals(n.startWhen));
      expect(keep.endWhen, equals(n.endWhen));
      expect(keep.brightnessTierHint, equals(n.brightnessTierHint));
    });

    test('nullable_fields_cleared_via_rebuild_explicit', () {
      // The four nullable fields are cleared by constructing a fresh
      // TargetHeaderNode without them. The recipe is pinned here so editor
      // authors can copy it directly.
      final n = makeM31();
      final cleared = TargetHeaderNode(
        id: n.id,
        name: n.name,
        isEnabled: n.isEnabled,
        childIds: n.childIds,
        parentId: n.parentId,
        orderIndex: n.orderIndex,
        comment: n.comment,
        targetName: n.targetName,
        raHours: n.raHours,
        decDegrees: n.decDegrees,
        rotation: n.rotation,
        priority: n.priority,
        minAltitude: n.minAltitude,
        maxAltitude: n.maxAltitude,
        startAfter: n.startAfter,
        endBefore: n.endBefore,
        mosaicPanel: n.mosaicPanel,
        triggerPollIntervalSecs: n.triggerPollIntervalSecs,
        // omit integrationBudget / startWhen / endWhen / brightnessTierHint
      );
      expect(cleared.integrationBudget, isNull);
      expect(cleared.startWhen, isNull);
      expect(cleared.endWhen, isNull);
      expect(cleared.brightnessTierHint, isNull);
    });

    test('copyWith_each_non_sentinel_field_mutates', () {
      final n = makeM31();
      expect(n.copyWith(targetName: 'M42').targetName, equals('M42'));
      expect(n.copyWith(raHours: 5.5).raHours, equals(5.5));
      expect(n.copyWith(decDegrees: -5.4).decDegrees, equals(-5.4));
      expect(n.copyWith(rotation: 90.0).rotation, equals(90.0));
      expect(n.copyWith(priority: 5).priority, equals(5));
      expect(n.copyWith(minAltitude: 25.0).minAltitude, equals(25.0));
      expect(n.copyWith(maxAltitude: 85.0).maxAltitude, equals(85.0));
      expect(
        n.copyWith(triggerPollIntervalSecs: 10).triggerPollIntervalSecs,
        equals(10),
      );
    });

    test('display_name_includes_mosaic_panel_when_present', () {
      final base = TargetHeaderNode(
        targetName: 'M31',
        raHours: 0.712,
        decDegrees: 41.27,
      );
      expect(base.displayName, equals('M31'));
      final mosaic = base.copyWith(
        mosaicPanel: const MosaicPanelInfo(
          mosaicName: 'M31 2x1',
          panelIndex: 0,
          totalPanels: 2,
          row: 0,
          column: 0,
        ),
      );
      expect(mosaic.displayName, equals('M31 (Panel 1/2)'));
    });

    test('has_time_constraints_when_start_or_end_set', () {
      final base = TargetHeaderNode(
        targetName: 'M31',
        raHours: 0.712,
        decDegrees: 41.27,
      );
      expect(base.hasTimeConstraints, isFalse);
      expect(
        base.copyWith(startAfter: DateTime(2026)).hasTimeConstraints,
        isTrue,
      );
      expect(
        base.copyWith(endBefore: DateTime(2026)).hasTimeConstraints,
        isTrue,
      );
    });

    test('has_altitude_constraints_when_min_or_max_set', () {
      final base = TargetHeaderNode(
        targetName: 'M31',
        raHours: 0.712,
        decDegrees: 41.27,
      );
      expect(base.hasAltitudeConstraints, isFalse);
      expect(base.copyWith(minAltitude: 30.0).hasAltitudeConstraints, isTrue);
      expect(base.copyWith(maxAltitude: 80.0).hasAltitudeConstraints, isTrue);
    });

    test('crossing_window_label_renders_label_for_each_trigger', () {
      final n = makeM31();
      expect(
        n.crossingWindowLabel,
        equals(
          'starts when ${n.startWhen!.label} · ends when ${n.endWhen!.label}',
        ),
      );
    });

    test('crossing_window_label_returns_null_without_triggers', () {
      final base = TargetHeaderNode(
        targetName: 'M31',
        raHours: 0.712,
        decDegrees: 41.27,
      );
      expect(base.crossingWindowLabel, isNull);
    });

    test('has_active_integration_budget_reflects_budget_state', () {
      final base = TargetHeaderNode(
        targetName: 'M31',
        raHours: 0.712,
        decDegrees: 41.27,
      );
      expect(base.hasActiveIntegrationBudget, isFalse);
      expect(
        base
            .copyWith(integrationBudget: const IntegrationBudget())
            .hasActiveIntegrationBudget,
        isFalse,
        reason: 'all-zero budget is not active',
      );
      expect(
        base
            .copyWith(integrationBudget: const IntegrationBudget(totalSecs: 60))
            .hasActiveIntegrationBudget,
        isTrue,
      );
    });

    test('equality_via_props_includes_all_fields', () {
      final a = makeM31();
      final b = makeM31();
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      // Different field => not equal.
      expect(a, isNot(equals(b.copyWith(priority: 999))));
      expect(a, isNot(equals(b.copyWith(targetName: 'X'))));
      expect(
        a,
        isNot(equals(b.copyWith(brightnessTierHint: BrightnessTier.bright))),
      );
    });
  });

  group('LoopNode', () {
    test('node_type_and_category_pin', () {
      final n = LoopNode();
      expect(n.nodeType, equals('Loop'));
      expect(n.iconName, equals('repeat'));
      expect(n.category, equals(NodeCategory.logic));
    });

    test('is_unbounded_true_for_forever_and_while_dark', () {
      expect(
        LoopNode(conditionType: LoopConditionType.forever).isUnbounded,
        isTrue,
      );
      expect(
        LoopNode(conditionType: LoopConditionType.whileDark).isUnbounded,
        isTrue,
      );
      expect(
        LoopNode(conditionType: LoopConditionType.count).isUnbounded,
        isFalse,
      );
      expect(
        LoopNode(conditionType: LoopConditionType.integrationTime).isUnbounded,
        isFalse,
        reason:
            'integrationTime is bounded by the target integration value, not by isUnbounded',
      );
    });

    test('copyWith_each_field', () {
      final n = LoopNode();
      expect(
        n.copyWith(conditionType: LoopConditionType.untilTime).conditionType,
        equals(LoopConditionType.untilTime),
      );
      expect(n.copyWith(repeatCount: 5).repeatCount, equals(5));
      final dt = DateTime.utc(2026, 1, 1);
      expect(n.copyWith(repeatUntil: dt).repeatUntil, equals(dt));
      expect(
        n.copyWith(repeatUntilAltitude: 30.0).repeatUntilAltitude,
        equals(30.0),
      );
      expect(
        n.copyWith(integrationTimeTarget: 3600.0).integrationTimeTarget,
        equals(3600.0),
      );
      expect(
        n.copyWith(maxSafetyIterations: 100).maxSafetyIterations,
        equals(100),
      );
      expect(n.copyWith(), equals(n));
    });
  });

  group('ConditionalNode', () {
    test('node_type_pin', () {
      final n = ConditionalNode();
      expect(n.nodeType, equals('Conditional'));
      expect(n.iconName, equals('git-merge'));
      expect(n.category, equals(NodeCategory.logic));
    });

    test('copyWith_safety_monitor_id_keeps_or_replaces', () {
      // ConditionalNode.copyWith uses plain `?? this.X`; clearing requires
      // constructing a fresh ConditionalNode.
      final n = ConditionalNode(safetyMonitorId: 'mon-1');
      expect(n.copyWith().safetyMonitorId, equals('mon-1'));
      // Plain `?? this.X`: null arg keeps current.
      expect(
        n.copyWith(safetyMonitorId: null).safetyMonitorId,
        equals('mon-1'),
      );
      // Non-null replaces.
      expect(
        n.copyWith(safetyMonitorId: 'mon-2').safetyMonitorId,
        equals('mon-2'),
      );
    });

    test('safety_monitor_id_clear_via_rebuild_explicit', () {
      // The rebuild-explicit recipe for clearing the field.
      final n = ConditionalNode(id: 'c', safetyMonitorId: 'mon-1');
      final cleared = ConditionalNode(
        id: n.id,
        name: n.name,
        isEnabled: n.isEnabled,
        childIds: n.childIds,
        parentId: n.parentId,
        orderIndex: n.orderIndex,
        comment: n.comment,
        conditionType: n.conditionType,
        thresholdValue: n.thresholdValue,
        thresholdTime: n.thresholdTime,
      );
      expect(cleared.safetyMonitorId, isNull);
    });

    test('copyWith_each_non_sentinel_field', () {
      final n = ConditionalNode();
      expect(
        n.copyWith(conditionType: ConditionalType.altitudeAbove).conditionType,
        equals(ConditionalType.altitudeAbove),
      );
      expect(n.copyWith(thresholdValue: 30.0).thresholdValue, equals(30.0));
      final dt = DateTime.utc(2026, 1, 1);
      expect(n.copyWith(thresholdTime: dt).thresholdTime, equals(dt));
    });

    test('equality_via_props_includes_safety_monitor_id', () {
      final a = ConditionalNode(id: 'c', safetyMonitorId: 'm');
      final b = ConditionalNode(id: 'c', safetyMonitorId: 'm');
      expect(a, equals(b));
      expect(a, isNot(equals(b.copyWith(safetyMonitorId: 'other'))));
    });
  });

  group('RecoveryNode', () {
    test('node_type_pin', () {
      final n = RecoveryNode();
      expect(n.nodeType, equals('Recovery'));
      expect(n.iconName, equals('shield-check'));
      expect(n.category, equals(NodeCategory.logic));
    });

    test('default_values_match_documented_defaults', () {
      final n = RecoveryNode();
      expect(n.recoveryAction, equals(RecoveryActionType.retry));
      expect(n.maxRetries, equals(3));
      expect(n.triggerType, isNull);
      expect(n.triggerThreshold, isNull);
      expect(n.hfrThresholdPercent, equals(20.0));
      expect(n.hfrConsecutiveFrames, equals(3));
      expect(n.triggerEveryNFrames, equals(25));
      expect(n.focusDriftWindowSize, equals(10));
      expect(n.focusDriftMinIncreasingCount, equals(5));
      expect(n.focusDriftMinTotalIncrease, equals(0.5));
      expect(n.guidingFailedDurationSecs, equals(30.0));
      expect(n.cloudMinutesBefore, equals(10.0));
      expect(n.cloudCoverageThresholdPercent, equals(70.0));
      expect(n.cloudOpeningMinDurationSecs, equals(300.0));
      expect(n.cloudCoverMaxPercent, equals(80.0));
      expect(n.cloudCoverDurationSecs, equals(60.0));
      expect(n.transparencyBelowThreshold, equals(0.7));
      expect(n.transparencyDurationSecs, equals(60.0));
    });

    test('copyWith_every_field', () {
      final n = RecoveryNode();
      expect(
        n
            .copyWith(recoveryAction: RecoveryActionType.parkAndAbort)
            .recoveryAction,
        equals(RecoveryActionType.parkAndAbort),
      );
      expect(n.copyWith(maxRetries: 10).maxRetries, equals(10));
      expect(
        n.copyWith(triggerType: TriggerType.hfrDegraded).triggerType,
        equals(TriggerType.hfrDegraded),
      );
      expect(n.copyWith(triggerThreshold: 4.5).triggerThreshold, equals(4.5));
      expect(
        n.copyWith(hfrThresholdPercent: 50.0).hfrThresholdPercent,
        equals(50.0),
      );
      expect(
        n.copyWith(hfrConsecutiveFrames: 7).hfrConsecutiveFrames,
        equals(7),
      );
      expect(
        n.copyWith(triggerEveryNFrames: 50).triggerEveryNFrames,
        equals(50),
      );
      expect(
        n.copyWith(focusDriftWindowSize: 30).focusDriftWindowSize,
        equals(30),
      );
      expect(
        n
            .copyWith(focusDriftMinIncreasingCount: 8)
            .focusDriftMinIncreasingCount,
        equals(8),
      );
      expect(
        n.copyWith(focusDriftMinTotalIncrease: 0.9).focusDriftMinTotalIncrease,
        equals(0.9),
      );
      expect(
        n.copyWith(guidingFailedDurationSecs: 45.0).guidingFailedDurationSecs,
        equals(45.0),
      );
      expect(
        n.copyWith(cloudMinutesBefore: 15.0).cloudMinutesBefore,
        equals(15.0),
      );
      expect(
        n
            .copyWith(cloudCoverageThresholdPercent: 60.0)
            .cloudCoverageThresholdPercent,
        equals(60.0),
      );
      expect(
        n
            .copyWith(cloudOpeningMinDurationSecs: 100.0)
            .cloudOpeningMinDurationSecs,
        equals(100.0),
      );
      expect(
        n.copyWith(cloudCoverMaxPercent: 90.0).cloudCoverMaxPercent,
        equals(90.0),
      );
      expect(
        n.copyWith(cloudCoverDurationSecs: 30.0).cloudCoverDurationSecs,
        equals(30.0),
      );
      expect(
        n.copyWith(transparencyBelowThreshold: 0.5).transparencyBelowThreshold,
        equals(0.5),
      );
      expect(
        n.copyWith(transparencyDurationSecs: 90.0).transparencyDurationSecs,
        equals(90.0),
      );
      expect(n.copyWith(), equals(n));
    });

    test('to_rust_trigger_config_returns_null_when_trigger_type_null', () {
      // "No triggerType configured" maps to a null payload — distinct from
      // "triggerType set but no threshold", which uses the Rust default. The
      // Rust side reads the JSON as Option<TriggerType>.
      final n = RecoveryNode();
      expect(n.toRustTriggerConfig(), isNull);
    });

    test('to_rust_trigger_config_emits_unit_string_for_unit_variants', () {
      // Some trigger types serialise as a BARE STRING (Rust unit variants),
      // others as `{"Variant": {payload}}`. The dispatcher's switch returns
      // dynamic to accommodate both shapes.
      final n = RecoveryNode(triggerType: TriggerType.weatherUnsafe);
      expect(n.toRustTriggerConfig(), equals('WeatherUnsafe'));
      final n2 = RecoveryNode(triggerType: TriggerType.filterChange);
      expect(n2.toRustTriggerConfig(), equals('FilterChange'));
      final n3 = RecoveryNode(triggerType: TriggerType.mountTrackingLost);
      expect(n3.toRustTriggerConfig(), equals('MountTrackingLost'));
    });

    test('to_rust_trigger_config_emits_struct_object_for_payload_variants', () {
      final n = RecoveryNode(
        triggerType: TriggerType.transparencyDropped,
        transparencyBelowThreshold: 0.5,
        transparencyDurationSecs: 120.0,
      );
      final encoded = n.toRustTriggerConfig() as Map<String, dynamic>;
      final payload = encoded['TransparencyDropped'] as Map<String, dynamic>;
      expect(payload['below_threshold'], equals(0.5));
      expect(payload['duration_secs'], equals(120.0));
    });

    test('equality_distinguishes_trigger_type', () {
      final a = RecoveryNode(id: 'r', triggerType: TriggerType.hfrDegraded);
      final b = RecoveryNode(id: 'r', triggerType: TriggerType.hfrDegraded);
      expect(a, equals(b));
      expect(a, isNot(equals(b.copyWith(triggerType: TriggerType.focusDrift))));
    });
  });

  group('ExposureNode', () {
    test('node_type_and_required_devices_pin', () {
      final n = ExposureNode();
      expect(n.nodeType, equals('TakeExposure'));
      expect(n.iconName, equals('camera'));
      expect(n.requiredDevices, equals({DeviceType.camera}));
    });

    test('default_values_match_documented_defaults', () {
      final n = ExposureNode();
      expect(n.durationSecs, equals(60.0));
      expect(n.count, equals(10));
      expect(n.frameType, equals(FrameType.light));
      expect(n.filter, isNull);
      expect(n.filterIndex, isNull);
      expect(n.gain, isNull);
      expect(n.offset, isNull);
      expect(n.binning, equals(BinningMode.one));
      expect(n.ditherEvery, equals(3));
      expect(n.triggers, isEmpty);
      expect(n.adaptiveExposure, isNull);
    });

    test('total_duration_secs_is_count_times_duration', () {
      final n = ExposureNode(durationSecs: 300.0, count: 12);
      expect(n.totalDurationSecs, equals(3600.0));
    });

    test('copyWith_adaptive_exposure_uses_plain_keep_or_replace', () {
      // copyWith follows the plain `?? this.adaptiveExposure` rule:
      //   * omitted  → keep current
      //   * non-null → install per-node override
      //   * null     → also keeps current (cannot clear via copyWith)
      // The "clear back to inherit-global" path is rebuild-explicit at the
      // editor layer; see _AdaptiveExposureSectionState._clearOverride. Both
      // halves of the contract are pinned here.
      final n = ExposureNode(adaptiveExposure: const AdaptiveExposureConfig());
      // Omitted → keep
      expect(n.copyWith().adaptiveExposure, isNotNull);
      // Explicit null → still keeps (plain `??` semantics)
      expect(n.copyWith(adaptiveExposure: null).adaptiveExposure, isNotNull);
      // Non-null → replaces
      const replacement = AdaptiveExposureConfig(targetSnr: 250);
      expect(
        n.copyWith(adaptiveExposure: replacement).adaptiveExposure,
        equals(replacement),
      );
    });

    test('adaptive_exposure_clear_via_rebuild_explicit', () {
      // The only way to clear an explicit per-node adaptiveExposure override
      // is to construct a fresh ExposureNode without it (the rebuild-explicit
      // pattern). This test pins the recipe so editor authors can copy it
      // directly.
      final n = ExposureNode(
        id: 'e1',
        adaptiveExposure: const AdaptiveExposureConfig(),
      );
      final cleared = ExposureNode(
        id: n.id,
        name: n.name,
        isEnabled: n.isEnabled,
        childIds: n.childIds,
        parentId: n.parentId,
        orderIndex: n.orderIndex,
        comment: n.comment,
        durationSecs: n.durationSecs,
        count: n.count,
        frameType: n.frameType,
        filter: n.filter,
        filterIndex: n.filterIndex,
        gain: n.gain,
        offset: n.offset,
        binning: n.binning,
        ditherEvery: n.ditherEvery,
        triggers: n.triggers,
      );
      expect(cleared.adaptiveExposure, isNull);
      // All other fields equal.
      expect(cleared.copyWith(adaptiveExposure: n.adaptiveExposure), equals(n));
    });

    test('copyWith_each_field', () {
      final n = ExposureNode();
      expect(n.copyWith(durationSecs: 120.0).durationSecs, equals(120.0));
      expect(n.copyWith(count: 5).count, equals(5));
      expect(
        n.copyWith(frameType: FrameType.dark).frameType,
        equals(FrameType.dark),
      );
      expect(n.copyWith(filter: 'L').filter, equals('L'));
      expect(n.copyWith(filterIndex: 2).filterIndex, equals(2));
      expect(n.copyWith(gain: 100).gain, equals(100));
      expect(n.copyWith(offset: 30).offset, equals(30));
      expect(
        n.copyWith(binning: BinningMode.two).binning,
        equals(BinningMode.two),
      );
      expect(n.copyWith(ditherEvery: 3).ditherEvery, equals(3));
      expect(
        n
            .copyWith(
              triggers: [
                {'kind': 'hfr', 'threshold': 5.0},
              ],
            )
            .triggers,
        equals([
          {'kind': 'hfr', 'threshold': 5.0},
        ]),
      );
      const ae = AdaptiveExposureConfig(targetSnr: 100);
      expect(n.copyWith(adaptiveExposure: ae).adaptiveExposure, equals(ae));
    });

    test('copyWith_no_args_preserves_existing_adaptive_exposure', () {
      // copyWith() with no args is a pure keep-all.
      const ae = AdaptiveExposureConfig(targetSnr: 99);
      final n = ExposureNode(adaptiveExposure: ae);
      expect(n.copyWith().adaptiveExposure, equals(ae));
    });

    test('equality_via_props_includes_triggers_list', () {
      final a = ExposureNode(
        id: 'e',
        triggers: const [
          {'kind': 'hfr', 'threshold': 5.0},
        ],
      );
      final b = ExposureNode(
        id: 'e',
        triggers: const [
          {'kind': 'hfr', 'threshold': 5.0},
        ],
      );
      expect(a, equals(b));
      expect(
        a,
        isNot(
          equals(
            b.copyWith(
              triggers: const [
                {'kind': 'hfr', 'threshold': 7.0},
              ],
            ),
          ),
        ),
      );
    });
  });

  // NotificationNode (complementary to notification_node_test.dart)
  group('NotificationNode', () {
    test('node_type_pin', () {
      final n = NotificationNode();
      expect(n.nodeType, equals('Notification'));
      expect(n.iconName, equals('bell'));
      expect(n.category, equals(NodeCategory.instruction));
    });

    test('copyWith_each_field', () {
      final n = NotificationNode();
      expect(n.copyWith(title: 'T').title, equals('T'));
      expect(n.copyWith(message: 'M').message, equals('M'));
      expect(
        n.copyWith(level: NotificationLevel.warning).level,
        equals(NotificationLevel.warning),
      );
      expect(n.copyWith(), equals(n));
    });

    test('copyWith_explicit_transports_keep_or_replace', () {
      // NotificationNode.copyWith uses plain `?? this.explicitTransports`
      // semantics (omitted / null keep; non-null replaces). Clearing back to
      // the matrix default is rebuild-explicit — covered by
      // notification_node_test.dart::"clears explicitTransports via
      // rebuild-explicit".
      final n = NotificationNode(
        explicitTransports: const [NotificationTransportKind.discord],
      );
      // Omitted keeps.
      expect(
        n.copyWith().explicitTransports,
        equals(const [NotificationTransportKind.discord]),
      );
      // Explicit null keeps too (plain `?? this.X` rule).
      expect(
        n.copyWith(explicitTransports: null).explicitTransports,
        equals(const [NotificationTransportKind.discord]),
      );
      // Non-null replaces.
      expect(
        n
            .copyWith(
              explicitTransports: const [NotificationTransportKind.telegram],
            )
            .explicitTransports,
        equals(const [NotificationTransportKind.telegram]),
      );
    });
  });

  // MeridianFlipNode
  //
  // The sticky-override UX heuristic ("touching any config field implicitly
  // flips useGlobalDefaults off") lives in the editor-layer helper
  // `applyMeridianFlipEdit(...)` in
  // `skotiq_app/.../widgets/meridian_flip_edit_helper.dart`, with its own
  // tests. The tests here pin the data model itself: a vanilla `copyWith` with
  // no hidden side effects.
  group('MeridianFlipNode', () {
    test('node_type_category_and_required_devices_pin', () {
      final n = MeridianFlipNode();
      expect(n.nodeType, equals('MeridianFlip'));
      expect(n.iconName, equals('refresh-cw'));
      expect(n.requiredDevices, equals({DeviceType.mount}));
      // A meridian flip is a parallel hour-angle / pier-side watchdog, not an
      // ordered instruction — it is classified as a trigger so every
      // category-switch renderer paints the warning color + watchdog
      // affordance. Execution dispatch matches by concrete type, not category.
      expect(n.category, equals(NodeCategory.trigger));
    });

    test('default_use_global_defaults_is_true', () {
      final n = MeridianFlipNode();
      expect(n.useGlobalDefaults, isTrue);
    });

    test('copyWith_is_plain_field_replace_no_implicit_flag_flip', () {
      // copyWith is a vanilla field-replace: the UX heuristic that flips
      // useGlobalDefaults when a config field is touched lives in the editor
      // helper, so any per-node override comes through an explicit
      // `useGlobalDefaults: false` arg.
      final n = MeridianFlipNode();
      expect(n.useGlobalDefaults, isTrue);
      // Touching config fields leaves the flag alone.
      expect(
        n
            .copyWith(triggerMethod: MeridianTriggerMethod.hourAngleThreshold)
            .useGlobalDefaults,
        isTrue,
      );
      expect(n.copyWith(minutesPastMeridian: 10.0).useGlobalDefaults, isTrue);
      expect(n.copyWith(minutesBeforeLimit: 15.0).useGlobalDefaults, isTrue);
      expect(n.copyWith(hourAngleThreshold: 1.0).useGlobalDefaults, isTrue);
      expect(n.copyWith(pauseGuiding: false).useGlobalDefaults, isTrue);
      expect(n.copyWith(autoCenter: false).useGlobalDefaults, isTrue);
      expect(n.copyWith(refocusAfter: true).useGlobalDefaults, isTrue);
      expect(n.copyWith(settleTime: 5.0).useGlobalDefaults, isTrue);
      expect(n.copyWith(resumeGuiding: false).useGlobalDefaults, isTrue);
      expect(n.copyWith(maxRetries: 5).useGlobalDefaults, isTrue);
      expect(
        n
            .copyWith(failureAction: FlipFailureAction.abortAndPark)
            .useGlobalDefaults,
        isTrue,
      );
    });

    test('copyWith_structural_fields_preserve_use_global_defaults', () {
      final n = MeridianFlipNode();
      expect(n.copyWith(name: 'X').useGlobalDefaults, isTrue);
      expect(n.copyWith(parentId: 'p').useGlobalDefaults, isTrue);
      expect(n.copyWith(orderIndex: 5).useGlobalDefaults, isTrue);
      expect(n.copyWith(comment: 'c').useGlobalDefaults, isTrue);
      expect(n.copyWith(isEnabled: false).useGlobalDefaults, isTrue);
    });

    test('explicit_use_global_defaults_arg_replaces_field', () {
      // The explicit arg path is how the editor's "Use global defaults"
      // toggle and the JSON-load path drive useGlobalDefaults.
      final n = MeridianFlipNode();
      final off = n.copyWith(useGlobalDefaults: false);
      expect(off.useGlobalDefaults, isFalse);
      final back = off.copyWith(useGlobalDefaults: true);
      expect(back.useGlobalDefaults, isTrue);
    });

    test('copyWith_no_args_preserves_all_fields', () {
      final n = MeridianFlipNode(
        useGlobalDefaults: false,
        triggerMethod: MeridianTriggerMethod.hourAngleThreshold,
        minutesPastMeridian: 7.0,
      );
      final copy = n.copyWith();
      expect(copy.useGlobalDefaults, isFalse);
      expect(
        copy.triggerMethod,
        equals(MeridianTriggerMethod.hourAngleThreshold),
      );
      expect(copy.minutesPastMeridian, equals(7.0));
    });

    test('equality_via_props_includes_use_global_defaults', () {
      final a = MeridianFlipNode(id: 'm', useGlobalDefaults: false);
      final b = MeridianFlipNode(id: 'm', useGlobalDefaults: false);
      expect(a, equals(b));
      // changing useGlobalDefaults via the explicit arg path keeps
      // other fields equal but the flag differs.
      expect(a, isNot(equals(b.copyWith(useGlobalDefaults: true))));
    });
  });

  group('TargetSchedulerNode', () {
    test('node_type_and_required_devices_pin', () {
      final n = TargetSchedulerNode();
      expect(n.nodeType, equals('TargetScheduler'));
      expect(n.iconName, equals('scheduler'));
      expect(n.category, equals(NodeCategory.logic));
      expect(n.requiredDevices, equals({DeviceType.mount}));
    });

    test('weights_normalised_band_is_lenient_around_one', () {
      final n = TargetSchedulerNode();
      // Defaults sum to 1.00 exactly.
      expect(n.weightsSum, equals(1.00));
      expect(n.weightsNormalised, isTrue);
      // 0.95 still inside the band
      final lo = n.copyWith(altitudeWeight: 0.20);
      expect(lo.weightsSum, closeTo(0.95, 1e-9));
      expect(lo.weightsNormalised, isTrue);
      // 0.90 outside the band
      final out = n.copyWith(altitudeWeight: 0.15);
      expect(out.weightsNormalised, isFalse);
    });

    test('normalised_weights_returns_sum_of_one', () {
      final n = TargetSchedulerNode(
        altitudeWeight: 2.0,
        moonDistanceWeight: 2.0,
        transitProximityWeight: 1.0,
        darknessWeight: 1.0,
        airmassWeight: 4.0,
      );
      final normed = n.normalisedWeights();
      expect(normed.weightsSum, closeTo(1.0, 1e-9));
    });

    test('copyWith_swap_on_conditions_below_keeps_or_replaces', () {
      // TargetSchedulerNode.copyWith uses plain
      // `?? this.swapOnConditionsBelow` semantics. Omitted or null keeps;
      // non-null replaces. Clearing is rebuild-explicit at the editor
      // (covered below).
      final n = TargetSchedulerNode(swapOnConditionsBelow: 60.0);
      expect(n.copyWith().swapOnConditionsBelow, equals(60.0));
      expect(
        n.copyWith(swapOnConditionsBelow: null).swapOnConditionsBelow,
        equals(60.0),
      );
      expect(
        n.copyWith(swapOnConditionsBelow: 40.0).swapOnConditionsBelow,
        equals(40.0),
      );
    });

    test('swap_on_conditions_below_cleared_via_rebuild_explicit', () {
      // The rebuild-explicit recipe used by the editor's adaptive-swap toggle
      // when the user disables the feature.
      final n = TargetSchedulerNode(swapOnConditionsBelow: 60.0);
      final cleared = TargetSchedulerNode(
        id: n.id,
        name: n.name,
        isEnabled: n.isEnabled,
        childIds: n.childIds,
        parentId: n.parentId,
        orderIndex: n.orderIndex,
        comment: n.comment,
        altitudeWeight: n.altitudeWeight,
        moonDistanceWeight: n.moonDistanceWeight,
        transitProximityWeight: n.transitProximityWeight,
        darknessWeight: n.darknessWeight,
        airmassWeight: n.airmassWeight,
        minScoreToRun: n.minScoreToRun,
        recomputeEveryNExposures: n.recomputeEveryNExposures,
        finishIterationOnSwitch: n.finishIterationOnSwitch,
        swapHysteresisSecs: n.swapHysteresisSecs,
        brightnessTierPreferences: n.brightnessTierPreferences,
        maxConditionsScoreAgeSecs: n.maxConditionsScoreAgeSecs,
      );
      expect(cleared.swapOnConditionsBelow, isNull);
    });

    test('copyWith_each_field', () {
      final n = TargetSchedulerNode();
      expect(n.copyWith(altitudeWeight: 0.3).altitudeWeight, equals(0.3));
      expect(
        n.copyWith(moonDistanceWeight: 0.3).moonDistanceWeight,
        equals(0.3),
      );
      expect(
        n.copyWith(transitProximityWeight: 0.3).transitProximityWeight,
        equals(0.3),
      );
      expect(n.copyWith(darknessWeight: 0.1).darknessWeight, equals(0.1));
      expect(n.copyWith(airmassWeight: 0.1).airmassWeight, equals(0.1));
      expect(n.copyWith(minScoreToRun: 50.0).minScoreToRun, equals(50.0));
      expect(
        n.copyWith(recomputeEveryNExposures: 10).recomputeEveryNExposures,
        equals(10),
      );
      expect(
        n.copyWith(finishIterationOnSwitch: false).finishIterationOnSwitch,
        isFalse,
      );
      expect(
        n.copyWith(swapHysteresisSecs: 60.0).swapHysteresisSecs,
        equals(60.0),
      );
      const prefs = BrightnessTierPreferences(faintMinScore: 99.0);
      expect(
        n.copyWith(brightnessTierPreferences: prefs).brightnessTierPreferences,
        equals(prefs),
      );
      expect(
        n.copyWith(maxConditionsScoreAgeSecs: 600).maxConditionsScoreAgeSecs,
        equals(600),
      );
      expect(n.copyWith(), equals(n));
    });

    // Phase B (scheduler-activation): the azimuth horizon mask carried into
    // the in-sequence scheduler from the operator's site profile.
    test(
      'horizon_profile_copyWith_keeps_or_replaces_and_participates_in_props',
      () {
        const horizon = HorizonProfile(
          name: 'Site',
          samples: [HorizonSample(0.0, 20.0), HorizonSample(180.0, 30.0)],
        );
        final n = TargetSchedulerNode(horizonProfile: horizon);
        // copyWith with no arg keeps; null keeps; non-null replaces.
        expect(n.copyWith().horizonProfile, equals(horizon));
        expect(
          n.copyWith(horizonProfile: null).horizonProfile,
          equals(horizon),
        );
        const other = HorizonProfile(
          name: 'Other',
          samples: [HorizonSample(0.0, 10.0)],
        );
        expect(n.copyWith(horizonProfile: other).horizonProfile, equals(other));
        // Equatable: the horizon participates so two nodes differing only by
        // their mask are not equal.
        expect(
          TargetSchedulerNode(id: 'x'),
          isNot(equals(TargetSchedulerNode(id: 'x', horizonProfile: horizon))),
        );
        // Default is null (flat floor).
        expect(TargetSchedulerNode().horizonProfile, isNull);
      },
    );
  });

  group('SmartExposureNode', () {
    test('node_type_and_required_devices_pin', () {
      final n = SmartExposureNode();
      expect(n.nodeType, equals('SmartExposure'));
      expect(n.iconName, equals('layers'));
      expect(
        n.requiredDevices,
        equals({DeviceType.camera, DeviceType.filterWheel}),
      );
    });

    test('total_integration_secs_sums_filter_plans', () {
      final n = SmartExposureNode(
        plans: const [
          FilterPlan(filterName: 'L', count: 10, durationSecs: 60.0),
          FilterPlan(filterName: 'R', count: 5, durationSecs: 120.0),
        ],
      );
      expect(n.totalIntegrationSecs, equals(10 * 60.0 + 5 * 120.0));
    });

    test('distinct_filter_count_and_duplicate_detection', () {
      final unique = SmartExposureNode(
        plans: const [
          FilterPlan(filterName: 'L'),
          FilterPlan(filterName: 'R'),
        ],
      );
      expect(unique.distinctFilterCount, equals(2));
      expect(unique.hasDuplicateFilter, isFalse);

      final dupe = SmartExposureNode(
        plans: const [
          FilterPlan(filterName: 'L', durationSecs: 30),
          FilterPlan(filterName: 'L', durationSecs: 60),
        ],
      );
      expect(dupe.distinctFilterCount, equals(1));
      expect(dupe.hasDuplicateFilter, isTrue);
    });

    test('copyWith_each_field', () {
      final n = SmartExposureNode();
      const plans = [FilterPlan(filterName: 'L')];
      expect(n.copyWith(plans: plans).plans, equals(plans));
      expect(n.copyWith(rotateFilters: false).rotateFilters, isFalse);
      expect(
        n.copyWith(ditherOnFilterChange: true).ditherOnFilterChange,
        isTrue,
      );
      expect(
        n.copyWith(integrationBudgetSecs: 1000.0).integrationBudgetSecs,
        equals(1000.0),
      );
      expect(n.copyWith(batchSize: 5).batchSize, equals(5));
      expect(n.copyWith(loopUntilStopped: true).loopUntilStopped, isTrue);
      expect(n.copyWith(), equals(n));
    });

    test('loop_until_stopped_default_false_and_in_props', () {
      final n = SmartExposureNode();
      expect(n.loopUntilStopped, isFalse);
      // props must include loopUntilStopped so two nodes differing only by it
      // are not considered equal.
      final looped = n.copyWith(loopUntilStopped: true);
      expect(looped == n, isFalse);
      expect(looped.props.contains(true), isTrue);
    });

    test('equality_includes_plans_list_order', () {
      final a = SmartExposureNode(
        id: 's',
        plans: const [
          FilterPlan(filterName: 'L'),
          FilterPlan(filterName: 'R'),
        ],
      );
      final b = SmartExposureNode(
        id: 's',
        plans: const [
          FilterPlan(filterName: 'L'),
          FilterPlan(filterName: 'R'),
        ],
      );
      expect(a, equals(b));
      final reordered = SmartExposureNode(
        id: 's',
        plans: const [
          FilterPlan(filterName: 'R'),
          FilterPlan(filterName: 'L'),
        ],
      );
      expect(a, isNot(equals(reordered)));
    });
  });

  group('LiveStackingNode', () {
    test('node_type_and_required_devices_pin', () {
      final n = LiveStackingNode();
      expect(n.nodeType, equals('LiveStacking'));
      expect(n.iconName, equals('cast_connected'));
      expect(n.requiredDevices, isEmpty);
    });

    test('is_public_when_auth_token_null_or_empty', () {
      expect(LiveStackingNode().isPublic, isTrue);
      expect(LiveStackingNode(authToken: '').isPublic, isTrue);
      expect(LiveStackingNode(authToken: 'secret').isPublic, isFalse);
    });

    test('has_watermark_when_text_is_non_empty', () {
      expect(LiveStackingNode().hasWatermark, isFalse);
      expect(LiveStackingNode(watermarkText: '').hasWatermark, isFalse);
      expect(LiveStackingNode(watermarkText: '  ').hasWatermark, isFalse);
      expect(LiveStackingNode(watermarkText: 'M42').hasWatermark, isTrue);
    });

    test('copyWith_auth_token_and_watermark_keep_or_replace', () {
      // Plain `?? this.X` for both fields. Omitted or null keeps; non-null
      // replaces. Clearing back to "public + no watermark" is
      // rebuild-explicit at the editor.
      final n = LiveStackingNode(authToken: 'secret', watermarkText: 'M42');
      expect(n.copyWith().authToken, equals('secret'));
      expect(n.copyWith().watermarkText, equals('M42'));
      // Explicit null keeps under plain semantics.
      expect(n.copyWith(authToken: null).authToken, equals('secret'));
      expect(n.copyWith(watermarkText: null).watermarkText, equals('M42'));
      // Non-null replaces.
      expect(n.copyWith(authToken: 'new').authToken, equals('new'));
    });

    test('auth_token_and_watermark_cleared_via_rebuild_explicit', () {
      // The rebuild-explicit recipe used by the editor's empty-text-submit
      // handlers for both fields.
      final n = LiveStackingNode(authToken: 'secret', watermarkText: 'M42');
      final cleared = LiveStackingNode(
        id: n.id,
        name: n.name,
        isEnabled: n.isEnabled,
        childIds: n.childIds,
        parentId: n.parentId,
        orderIndex: n.orderIndex,
        comment: n.comment,
        mode: n.mode,
        stackMethod: n.stackMethod,
        maxFramesToStack: n.maxFramesToStack,
        broadcastEnabled: n.broadcastEnabled,
        broadcastPort: n.broadcastPort,
        broadcastPath: n.broadcastPath,
        thumbnailWidth: n.thumbnailWidth,
        thumbnailHeight: n.thumbnailHeight,
        // omit authToken + watermarkText
      );
      expect(cleared.authToken, isNull);
      expect(cleared.watermarkText, isNull);
    });

    test('copyWith_each_field', () {
      final n = LiveStackingNode();
      expect(
        n.copyWith(mode: LiveStackingMode.recordAndBroadcast).mode,
        equals(LiveStackingMode.recordAndBroadcast),
      );
      expect(
        n.copyWith(stackMethod: LiveStackingMethod.sigma).stackMethod,
        equals(LiveStackingMethod.sigma),
      );
      expect(n.copyWith(maxFramesToStack: 500).maxFramesToStack, equals(500));
      expect(n.copyWith(broadcastEnabled: false).broadcastEnabled, isFalse);
      expect(n.copyWith(broadcastPort: 9000).broadcastPort, equals(9000));
      expect(n.copyWith(broadcastPath: '/live').broadcastPath, equals('/live'));
      expect(n.copyWith(thumbnailWidth: 800).thumbnailWidth, equals(800));
      expect(n.copyWith(thumbnailHeight: 600).thumbnailHeight, equals(600));
      expect(n.copyWith(), equals(n));
    });
  });

  // LiveStackingMode / LiveStackingMethod enums
  group('LiveStackingMode enum', () {
    test('storage_key_matches_snake_case_rust_form', () {
      expect(
        LiveStackingMode.broadcastOnly.storageKey,
        equals('broadcast_only'),
      );
      expect(
        LiveStackingMode.recordAndBroadcast.storageKey,
        equals('record_and_broadcast'),
      );
    });

    test('from_storage_key_round_trip', () {
      expect(
        LiveStackingMode.fromStorageKey('broadcast_only'),
        equals(LiveStackingMode.broadcastOnly),
      );
      expect(
        LiveStackingMode.fromStorageKey('record_and_broadcast'),
        equals(LiveStackingMode.recordAndBroadcast),
      );
    });

    test('from_storage_key_unknown_defaults_to_broadcast_only', () {
      // from_storage_key falls back to broadcastOnly for unknown / null
      // keys, which hides storage-format corruption. The test pins the
      // current behaviour; tightening it to a FormatException (as
      // FilterBudgetEntry does) is a deliberate behaviour change.
      expect(
        LiveStackingMode.fromStorageKey('bogus'),
        equals(LiveStackingMode.broadcastOnly),
      );
      expect(
        LiveStackingMode.fromStorageKey(null),
        equals(LiveStackingMode.broadcastOnly),
      );
    });
  });

  group('LiveStackingMethod enum', () {
    test('storage_key_matches_snake_case_rust_form', () {
      expect(LiveStackingMethod.average.storageKey, equals('average'));
      expect(LiveStackingMethod.medianRej.storageKey, equals('median_rej'));
      expect(LiveStackingMethod.sigma.storageKey, equals('sigma'));
    });

    test('from_storage_key_round_trip', () {
      expect(
        LiveStackingMethod.fromStorageKey('average'),
        equals(LiveStackingMethod.average),
      );
      expect(
        LiveStackingMethod.fromStorageKey('median_rej'),
        equals(LiveStackingMethod.medianRej),
      );
      expect(
        LiveStackingMethod.fromStorageKey('sigma'),
        equals(LiveStackingMethod.sigma),
      );
    });

    test('from_storage_key_unknown_defaults_to_average', () {
      // Like LiveStackingMode, an unknown key falls back to `average`, which
      // hides storage-format corruption. The fallback is pinned so a change
      // to it is deliberate.
      expect(
        LiveStackingMethod.fromStorageKey('bogus'),
        equals(LiveStackingMethod.average),
      );
      expect(
        LiveStackingMethod.fromStorageKey(null),
        equals(LiveStackingMethod.average),
      );
    });
  });

  group('SciencePhotometryNode', () {
    SciencePhotometryNode sample() => SciencePhotometryNode(
      id: 'sp1',
      targetDesignation: 'V0376 Per',
      referenceStars: const ['ref1', 'ref2', 'ref3'],
      maxCadenceGapSecs: 3.5,
      filter: 'V',
      exposureSecs: 30.0,
      count: 120,
      reduceLive: true,
      applyDifferential: true,
      quality: const PhotometryQualityGates(minSnr: 100.0),
      gain: 100,
      offset: 30,
      binning: BinningMode.two,
    );

    test('node_type_and_required_devices_pin', () {
      final n = sample();
      expect(n.nodeType, equals('SciencePhotometry'));
      expect(n.iconName, equals('analytics'));
      expect(
        n.requiredDevices,
        equals({DeviceType.camera, DeviceType.filterWheel}),
      );
    });

    test('is_photometric_filter_recognises_standard_bands', () {
      expect(sample().isPhotometricFilter, isTrue);
      expect(sample().copyWith(filter: 'Bogus').isPhotometricFilter, isFalse);
    });

    test('has_impossible_cadence_negative_gap', () {
      expect(sample().hasImpossibleCadence, isFalse);
      expect(
        sample().copyWith(maxCadenceGapSecs: -1.0).hasImpossibleCadence,
        isTrue,
      );
    });

    test('to_rust_config_json_uses_snake_case_and_pascal_binning', () {
      // Mirrors the Rust SciencePhotometryConfig shape: snake_case keys,
      // BinningMode as a PascalCase string, references serialised as a
      // List<String> — the same BinningMode mapping FilterPlan uses.
      final json = sample().toRustConfigJson();
      expect(json['target_designation'], equals('V0376 Per'));
      expect(json['reference_stars'], equals(['ref1', 'ref2', 'ref3']));
      expect(json['max_cadence_gap_secs'], equals(3.5));
      expect(json['filter'], equals('V'));
      expect(json['exposure_secs'], equals(30.0));
      expect(json['count'], equals(120));
      expect(json['reduce_live'], isTrue);
      expect(json['apply_differential'], isTrue);
      expect(json['quality'], isA<Map<String, dynamic>>());
      expect(json['gain'], equals(100));
      expect(json['offset'], equals(30));
      expect(json['binning'], equals('Two'));
    });

    test('from_rust_config_json_round_trips_payload_fields', () {
      final n = sample();
      final encoded = jsonEncode(n.toRustConfigJson());
      final back = SciencePhotometryNode.fromRustConfigJson(
        jsonDecode(encoded) as Map<String, dynamic>,
        id: n.id,
        name: n.name,
        isEnabled: n.isEnabled,
        childIds: n.childIds,
        parentId: n.parentId,
        orderIndex: n.orderIndex,
        comment: n.comment,
      );
      expect(back, equals(n));
    });

    test('from_rust_config_json_applies_documented_defaults', () {
      // from_rust_config_json applies missing-field defaults:
      // target_designation '', reference_stars [], max_cadence_gap_secs 2.0,
      // filter 'Clear', exposure_secs 60.0, count 60, reduce_live true,
      // apply_differential true, quality PhotometryQualityGates().
      final back = SciencePhotometryNode.fromRustConfigJson(
        const <String, dynamic>{},
      );
      expect(back.targetDesignation, equals(''));
      expect(back.referenceStars, isEmpty);
      expect(back.maxCadenceGapSecs, equals(2.0));
      expect(back.filter, equals('Clear'));
      expect(back.exposureSecs, equals(60.0));
      expect(back.count, equals(60));
      expect(back.reduceLive, isTrue);
      expect(back.applyDifferential, isTrue);
      expect(back.quality, equals(const PhotometryQualityGates()));
      expect(back.binning, equals(BinningMode.one));
    });

    test('copyWith_each_field', () {
      final n = sample();
      expect(n.copyWith(targetDesignation: 'X').targetDesignation, equals('X'));
      expect(
        n.copyWith(referenceStars: const ['only']).referenceStars,
        equals(const ['only']),
      );
      expect(n.copyWith(maxCadenceGapSecs: 5.0).maxCadenceGapSecs, equals(5.0));
      expect(n.copyWith(filter: 'B').filter, equals('B'));
      expect(n.copyWith(exposureSecs: 90.0).exposureSecs, equals(90.0));
      expect(n.copyWith(count: 10).count, equals(10));
      expect(n.copyWith(reduceLive: false).reduceLive, isFalse);
      expect(n.copyWith(applyDifferential: false).applyDifferential, isFalse);
      const q = PhotometryQualityGates(minSnr: 200.0);
      expect(n.copyWith(quality: q).quality, equals(q));
      expect(
        n.copyWith(binning: BinningMode.four).binning,
        equals(BinningMode.four),
      );
    });

    test('copyWith_gain_and_offset_keep_or_replace', () {
      // Plain `?? this.X` for gain and offset. Omitted or null keeps;
      // non-null replaces. Clearing is rebuild-explicit at
      // science_photometry_properties.dart's empty-text-input handler.
      final n = sample();
      expect(n.copyWith().gain, equals(100));
      expect(n.copyWith().offset, equals(30));
      // Explicit null keeps.
      expect(n.copyWith(gain: null).gain, equals(100));
      expect(n.copyWith(offset: null).offset, equals(30));
      // Non-null replaces.
      expect(n.copyWith(gain: 200).gain, equals(200));
      expect(n.copyWith(offset: 60).offset, equals(60));
    });

    test('gain_and_offset_cleared_via_rebuild_explicit', () {
      // The rebuild-explicit recipe pinned for the editor.
      final n = sample();
      final cleared = SciencePhotometryNode(
        id: n.id,
        name: n.name,
        isEnabled: n.isEnabled,
        childIds: n.childIds,
        parentId: n.parentId,
        orderIndex: n.orderIndex,
        comment: n.comment,
        targetDesignation: n.targetDesignation,
        referenceStars: n.referenceStars,
        maxCadenceGapSecs: n.maxCadenceGapSecs,
        filter: n.filter,
        exposureSecs: n.exposureSecs,
        count: n.count,
        reduceLive: n.reduceLive,
        applyDifferential: n.applyDifferential,
        quality: n.quality,
        binning: n.binning,
        // gain / offset omitted
      );
      expect(cleared.gain, isNull);
      expect(cleared.offset, isNull);
    });

    test('equality_via_props_includes_reference_stars_order', () {
      final a = sample();
      final b = sample();
      expect(a, equals(b));
      expect(
        a,
        isNot(
          equals(a.copyWith(referenceStars: const ['ref2', 'ref1', 'ref3'])),
        ),
      );
    });
  });
}
