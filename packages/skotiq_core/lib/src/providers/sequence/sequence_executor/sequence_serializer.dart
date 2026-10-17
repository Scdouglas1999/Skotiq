import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/imaging/imaging_models.dart';
import '../../../models/sequence/sequence_models.dart';
import '../../../models/settings/app_settings.dart' show SafetyFailMode;
import '../../profiles_provider.dart' show activeEquipmentProfileProvider;
import '../../focuser_backlash_provider.dart'
    show measuredFocuserBacklashStepsProvider;
import '../../meridian_flip_provider.dart';
import '../../settings_provider.dart';
import '../sequencer_defaults.dart';

/// Translates the Dart sequence model into the JSON the Rust executor loads.
///
/// The ONE place a [Sequence] becomes native config: `SequenceNode` is sealed,
/// so every node type must appear in [_nodeToConfig]'s switch and adding a node
/// type forces this translation to be updated rather than silently dropping the
/// node on the wire.
///
/// It owns nothing about a run. Everything it needs from the executor arrives
/// through the constructor: [Ref] for the settings / profile / defaults it
/// reads, and [warn] for the operator-facing warnings a lookup failure must
/// surface into the run record rather than only into a log file.
class SequenceSerializer {
  SequenceSerializer({
    required Ref ref,
    required void Function(String message) warn,
  }) : _ref = ref,
       _warn = warn;

  final Ref _ref;
  final void Function(String message) _warn;

  String sequenceToJson(Sequence sequence) {
    final appSettings = _ref.read(appSettingsProvider).valueOrNull;
    final autoFocusOnFilterChange =
        appSettings?.autoFocusOnFilterChange ?? false;
    final autoFocusEveryMinutes = appSettings?.autoFocusEveryMinutes ?? 0;
    final autofocusSettings = _ref.read(autofocusSettingsProvider);

    final nodeDefinitions = <Map<String, dynamic>>[];

    // Track which FilterChangeNodes need a synthetic AutofocusNode appended
    // to their children. Why: when the user enables "Auto focus on filter
    // change" globally and a FilterChangeNode does not already have an
    // AutofocusNode following it in the sibling chain, we splice one in so
    // the executor runs AF after the filter is in place. Per-sequence
    // structure (an explicit AF node already present) always wins; we only
    // inject when no AF would otherwise run.
    final autoFocusInjectionParents = <String>{};

    void collectAfInjections(SequenceNode node) {
      for (var i = 0; i < node.childIds.length; i++) {
        final childId = node.childIds[i];
        final child = sequence.nodes[childId];
        if (child == null) continue;
        if (child is FilterChangeNode && autoFocusOnFilterChange) {
          // Look at the next sibling (if any) — if it's an AutofocusNode the
          // user already arranged for focus to follow the filter change.
          final nextChildId = i + 1 < node.childIds.length
              ? node.childIds[i + 1]
              : null;
          final nextSibling = nextChildId == null
              ? null
              : sequence.nodes[nextChildId];
          final alreadyFollowedByAf = nextSibling is AutofocusNode;
          if (!alreadyFollowedByAf) {
            autoFocusInjectionParents.add(node.id);
          }
        }
        collectAfInjections(child);
      }
    }

    if (sequence.rootNode != null) {
      collectAfInjections(sequence.rootNode!);
    }

    // Map of "after this FilterChange node id" -> synthetic AF node id, so we
    // can rewrite parent child lists deterministically. The synthetic id is
    // derived from the FilterChange id to keep checkpoint replay stable.
    final injectedAfNodes = <String, Map<String, dynamic>>{};

    void processNode(SequenceNode node) {
      final Map<String, dynamic> nodeType = _nodeToConfig(node);

      // If this node is a parent that contains FilterChange children needing
      // injection, rewrite its `children` list to splice an AF node id in
      // immediately after each affected FilterChange.
      final originalChildIds = node.childIds;
      final List<String> effectiveChildIds;
      if (autoFocusOnFilterChange &&
          autoFocusInjectionParents.contains(node.id)) {
        effectiveChildIds = <String>[];
        for (var i = 0; i < originalChildIds.length; i++) {
          final childId = originalChildIds[i];
          effectiveChildIds.add(childId);
          final child = sequence.nodes[childId];
          if (child is! FilterChangeNode) continue;
          final nextSiblingId = i + 1 < originalChildIds.length
              ? originalChildIds[i + 1]
              : null;
          final nextSibling = nextSiblingId == null
              ? null
              : sequence.nodes[nextSiblingId];
          if (nextSibling is AutofocusNode) continue;
          final syntheticId = 'af-auto-${child.id}';
          effectiveChildIds.add(syntheticId);
          injectedAfNodes[syntheticId] = {
            'id': syntheticId,
            'name': 'Autofocus (auto, post filter change)',
            'node_type': autofocusRuntimeConfig(
              autofocusSettings,
              maxDurationSecs: 600,
            ),
            'enabled': true,
            'children': const <String>[],
          };
        }
      } else {
        effectiveChildIds = originalChildIds;
      }

      nodeDefinitions.add({
        'id': node.id,
        'name': node.name,
        'node_type': nodeType,
        'enabled': node.isEnabled,
        'children': effectiveChildIds,
      });

      for (final childId in originalChildIds) {
        final child = sequence.nodes[childId];
        if (child != null) {
          processNode(child);
        }
      }
    }

    if (sequence.rootNode != null) {
      processNode(sequence.rootNode!);
    }

    // Append synthetic AF nodes after the real node list so the executor can
    // resolve their child ids when walking the tree.
    nodeDefinitions.addAll(injectedAfNodes.values);

    // Metadata propagates the AF-interval cadence to the Rust executor so
    // future trigger configuration can honor the user's preference. We
    // serialise even when zero so the executor sees an explicit "off"
    // signal rather than an absent key.
    final metadata = <String, String>{
      'autofocus_every_minutes': autoFocusEveryMinutes.toString(),
      'autofocus_on_filter_change': autoFocusOnFilterChange.toString(),
    };

    return jsonEncode({
      'id': sequence.id,
      'name': sequence.name,
      'description': sequence.description,
      'nodes': nodeDefinitions,
      'root_node_id': sequence.rootNodeId,
      'metadata': metadata,
    });
  }

  Map<String, dynamic> autofocusRuntimeConfig(
    AutofocusSettings settings, {
    AutofocusNode? nodeOverrides,
    required double maxDurationSecs,
  }) {
    final useGlobalBasics = nodeOverrides == null;
    final method = useGlobalBasics
        ? switch (settings.curveFitting.trim().toLowerCase()) {
            'hyperbolic' => 'Hyperbolic',
            'parabolic' || 'quadratic' => 'Quadratic',
            _ => 'VCurve',
          }
        : _autofocusMethodToString(nodeOverrides.method);
    final backlashEnabled = !settings.backlashCompMethod
        .trim()
        .toLowerCase()
        .contains('none');

    return {
      'type': 'Autofocus',
      'method': method,
      'step_size': useGlobalBasics ? settings.stepSize : nodeOverrides.stepSize,
      'steps_out': useGlobalBasics
          ? settings.initialOffsetSteps
          : nodeOverrides.stepsOut,
      'exposure_duration': useGlobalBasics
          ? settings.exposureTime
          : nodeOverrides.exposureDuration,
      'filter': settings.autofocusFilterName.trim().isEmpty
          ? null
          : settings.autofocusFilterName.trim(),
      'filter_settings': settings.filterSettings.map(
        (filterName, config) => MapEntry(filterName, {
          'af_exposure_time': config.afExposureTime,
          'af_filter_name': config.afFilterName,
          'binning': _autofocusBinningToString(config.binning),
          'gain': config.gain,
          'offset': config.offset,
        }),
      ),
      'binning': _autofocusBinningToString(settings.binning),
      'number_of_attempts': settings.numberOfAttempts,
      'exposures_per_point': useGlobalBasics
          ? settings.exposuresPerPoint
          : nodeOverrides.exposuresPerPoint,
      'r_squared_threshold': settings.rSquaredThreshold,
      'failure_hfr_tolerance_ratio': settings.failureHfrToleranceRatio,
      'outer_crop_ratio': settings.outerCropRatio,
      'inner_crop_ratio': settings.innerCropRatio,
      'use_brightest_n_stars': settings.useBrightestNStars,
      'focuser_settle_time_ms': settings.focuserSettleTimeMs,
      'backlash_compensation': backlashEnabled ? settings.backlashIn : 0,
      'backlash_out_compensation': backlashEnabled ? settings.backlashOut : 0,
      // NOT gated on `backlashEnabled`. That selector governs the overshoot
      // moves during the sweep; this figure sizes only the FINAL run-up onto
      // best focus, which happens either way because focus has to be reached
      // from the side the curve was measured from. See the doc comment on
      // `measured_backlash_in` in
      // `native/skotiq_native/sequencer/src/lib.rs`: a figure the operator
      // typed into `backlash_compensation` still outranks this one.
      'measured_backlash_in': _ref.read(measuredFocuserBacklashStepsProvider),
      'disable_guiding_during_af': settings.disableGuidingDuringAf,
      'max_duration_secs': maxDurationSecs,
    };
  }

  String _autofocusBinningToString(int binning) => switch (binning) {
    2 => 'Two',
    3 => 'Three',
    4 => 'Four',
    _ => 'One',
  };

  /// Look up filter index from profile by name (case-insensitive).
  ///
  /// Returns `null` when:
  ///   * [filterName] is null/empty,
  ///   * the active equipment profile has no filter list, or
  ///   * the name isn't found in the profile.
  ///
  /// In the latter two cases (and only those), emits a warning to the
  /// logger AND the live sequence stats blob so the user can see in the
  /// post-session report exactly which exposures fell back to literal
  /// filter names. The warning is rate-limited via
  /// [SequenceRunStats.recordWarning] which suppresses exact-duplicate
  /// consecutive entries.
  int? _lookupFilterIndex(String? filterName) {
    if (filterName == null || filterName.isEmpty) return null;
    final profile = _ref.read(activeEquipmentProfileProvider);
    if (profile == null) {
      _surfaceFilterLookupWarning(
        'Filter wheel profile not active; node will use filter name '
        '"$filterName" literally without a wheel index. Connect a filter '
        'wheel + activate its profile to enable index-based filter selection.',
      );
      return null;
    }
    final filterNames = profile.filterNames;
    if (filterNames.isEmpty) {
      _surfaceFilterLookupWarning(
        'Active profile has no filter list configured; node will use '
        'filter name "$filterName" literally. Configure the filter wheel '
        'slot names in the equipment profile.',
      );
      return null;
    }
    for (int i = 0; i < filterNames.length; i++) {
      if (filterNames[i].toLowerCase() == filterName.toLowerCase()) {
        return i;
      }
    }
    _surfaceFilterLookupWarning(
      'Filter "$filterName" not found in active profile '
      '(available: ${filterNames.join(", ")}); node will use the literal '
      'name without a wheel index.',
    );
    return null;
  }

  /// Emit a filter-lookup warning to both the logger and (if a run is
  /// live) the run stats. Centralized so the wording stays consistent
  /// across the three lookup failure modes.
  void _surfaceFilterLookupWarning(String message) => _warn(message);

  /// Convert a Dart node to native config format.
  ///
  /// `SequenceNode` is sealed: every subtype must appear below or the
  /// compiler will reject the switch. Adding a new node type forces this
  /// site to be updated.
  Map<String, dynamic> _nodeToConfig(SequenceNode node) {
    switch (node) {
      case ExposureNode n:
        final defaults = _ref.read(sequencerDefaultsProvider);
        final appSettings = _ref.read(appSettingsProvider).valueOrNull;
        final ditherEvery =
            n.ditherEvery ??
            ((appSettings?.ditherEnabled ?? true)
                ? appSettings?.ditherEveryFrames
                : null);
        // Auto-populate filter_index from profile if not set
        final filterIndex = n.filterIndex ?? _lookupFilterIndex(n.filter);
        return {
          'type': 'TakeExposure',
          'duration_secs': n.durationSecs,
          'count': n.count,
          // FITS IMAGETYP-style frame type. Omitting this stamped every
          // sequencer capture "Light" — sequenced darks/flats/bias were
          // mislabeled on disk, star-graded (and rejected), and dithered.
          'frame_type': _frameTypeToWire(n.frameType),
          'filter': n.filter,
          'filter_index': filterIndex,
          'gain': n.gain,
          'offset': n.offset,
          'binning': _binningToString(n.binning),
          'dither_every': ditherEvery,
          'dither_pixels': defaults.ditherPixels,
          'dither_settle_pixels': defaults.ditherSettlePixels,
          'dither_settle_time': defaults.ditherSettleTime,
          'dither_settle_timeout': defaults.ditherSettleTimeout,
          'dither_ra_only': defaults.ditherRaOnly,
          'save_to': null,
          'triggers': n.triggers,
          // Per-node sky-brightness adaptive exposure
          // override. `null` => use the global default pushed via
          // `sequencerUpdateDefaultAdaptiveExposure`. The Rust JSON
          // schema uses `serde(default)` so omitting the key is fine,
          // but emitting it explicitly keeps the wire shape visible
          // and the downstream tests reproducible.
          'adaptive_exposure': n.adaptiveExposure?.toJson(),
        };
      case SlewNode n:
        return {
          'type': 'SlewToTarget',
          'use_target_coords': n.useTargetCoords,
          'custom_ra': n.customRa,
          'custom_dec': n.customDec,
        };
      case CenterNode n:
        return {
          'type': 'CenterTarget',
          'use_target_coords': n.useTargetCoords,
          // The properties panel exposes custom RA/Dec when
          // use_target_coords is off; omitting them made the executor fall
          // back to "center on wherever the mount currently points" —
          // silently ignoring the user's coordinates.
          'custom_ra': n.customRa,
          'custom_dec': n.customDec,
          'accuracy_arcsec': n.accuracyArcsec,
          'max_attempts': n.maxAttempts,
          // Emit the node's real solve-exposure duration instead of a hard
          // 3.0s literal so the runtime uses the value the user configured
          // (and the timeline estimate, which now reads the same field,
          // agrees with execution).
          'exposure_duration': n.exposureDuration,
          'filter': null,
        };
      case AutofocusNode n:
        final appSettings = _ref.read(appSettingsProvider).valueOrNull;
        if (n.useSettingsDefaults && appSettings == null) {
          throw StateError(
            'Cannot serialize autofocus node "${n.name}" with settings '
            'defaults before AppSettings has loaded.',
          );
        }
        final settings = _ref.read(autofocusSettingsProvider);
        return autofocusRuntimeConfig(
          settings,
          nodeOverrides: n.useSettingsDefaults ? null : n,
          maxDurationSecs: n.maxDurationSecs,
        );
      case DitherNode n:
        return {
          'type': 'Dither',
          'pixels': n.pixels,
          'settle_pixels': n.settlePixels,
          'settle_time': n.settleTime,
          'settle_timeout': n.settleTimeout,
          'ra_only': n.raOnly,
          // Rust DitherPattern enum is serialized as PascalCase variant names.
          'pattern': switch (n.pattern) {
            DitherPattern.random => 'Random',
            DitherPattern.grid => 'Grid',
          },
          'grid_size': n.gridSize,
        };
      case StartGuidingNode n:
        return {
          'type': 'StartGuiding',
          'settle_pixels': n.settlePixels,
          'settle_time': n.settleTime,
          'settle_timeout': n.settleTimeout,
          'auto_select_star': n.autoSelectStar,
        };
      case StopGuidingNode _:
        return {'type': 'StopGuiding'};
      case FilterChangeNode n:
        // Auto-populate filter_index from profile if not set
        final filterIndex =
            n.filterPosition ?? _lookupFilterIndex(n.filterName);
        return {
          'type': 'ChangeFilter',
          'filter_name': n.filterName,
          'filter_index': filterIndex,
        };
      case CoolCameraNode n:
        return {
          'type': 'CoolCamera',
          'target_temp': n.targetTemp,
          'duration_mins': n.durationMins,
        };
      case WarmCameraNode n:
        return {
          'type': 'WarmCamera',
          'rate_per_min': n.ratePerMin,
          'target_temp': n.targetTemp,
        };
      case RotatorNode n:
        return {
          'type': 'MoveRotator',
          'target_angle': n.targetAngle,
          'relative': n.relative,
        };
      case ParkNode _:
        return {'type': 'Park'};
      case UnparkNode _:
        return {'type': 'Unpark'};
      case WaitTimeNode n:
        return {
          'type': 'WaitForTime',
          // Engine contract is Unix SECONDS (execute_wait_time compares
          // against Utc::now().timestamp()). Milliseconds here made the
          // node wait ~55,000 years — i.e. hang the sequence forever.
          'wait_until': n.waitUntil == null
              ? null
              : n.waitUntil!.millisecondsSinceEpoch ~/ 1000,
          'wait_for_twilight': n.waitForTwilight != null
              ? _twilightToString(n.waitForTwilight!)
              : null,
        };
      case DelayNode n:
        return {'type': 'Delay', 'seconds': n.seconds};
      case NotificationNode n:
        return {
          'type': 'Notification',
          'title': n.title,
          'message': n.message,
          'level': _notificationLevelToString(n.level),
          // Pass the per-node transport override through
          // to the Rust executor as a Custom-event `data` field so the
          // Dart-side notification router can honour it.
          if (n.explicitTransports != null)
            'explicit_transports': n.explicitTransports!
                .map((t) => t.storageKey)
                .toList(),
        };
      case ScriptNode n:
        return {
          'type': 'RunScript',
          'script_path': n.scriptPath,
          'arguments': n.arguments,
          'timeout_secs': n.timeoutSecs,
        };
      case TargetHeaderNode n:
        return {
          'type': 'TargetHeader',
          'target_name': n.targetName,
          'ra_hours': n.raHours,
          'dec_degrees': n.decDegrees,
          'rotation': n.rotation,
          'min_altitude': n.minAltitude,
          'max_altitude': n.maxAltitude,
          'priority': n.priority,
          // Unix SECONDS — the scheduler's runnable gate and
          // legacy_to_triggers both compare against Utc::now().timestamp().
          // Milliseconds made start_after unreachable (target never ran /
          // waited forever) and end_before a no-op.
          'start_after': n.startAfter == null
              ? null
              : n.startAfter!.millisecondsSinceEpoch ~/ 1000,
          'end_before': n.endBefore == null
              ? null
              : n.endBefore!.millisecondsSinceEpoch ~/ 1000,
          'mosaic_panel': n.mosaicPanel?.toJson(),
          // Adaptive swap brightness tier hint. Lowercase wire
          // string ('faint'/'medium'/'bright'); `null` => scheduler
          // infers (defaults to medium inside the decision engine).
          'brightness_tier_hint': n.brightnessTierHint?.wireValue,
          // Explicit start/end crossings + integration budget. These were
          // configurable in the editor but never reached the executor —
          // Rust's `#[serde(default)]` masked the omission, so startWhen /
          // endWhen / the budget silently did nothing at runtime. The Dart
          // toJson() codecs mirror the Rust serde shapes exactly
          // (pinned by target_trigger_serde_test.dart).
          'start_when': n.startWhen?.toJson(),
          'end_when': n.endWhen?.toJson(),
          'trigger_poll_interval_secs': n.triggerPollIntervalSecs,
          'integration_budget': n.integrationBudget?.toJson(),
        };
      case InstructionSetNode _:
        // InstructionSet maps to a Loop with count=1 on the backend
        return {
          'type': 'Loop',
          'iterations': 1,
          'condition': 'Count',
          'condition_value': 1,
        };
      case LoopNode n:
        dynamic conditionValue;
        switch (n.conditionType) {
          case LoopConditionType.count:
            conditionValue = n.repeatCount;
            break;
          case LoopConditionType.untilTime:
            // Unix SECONDS — loop_node.rs compares condition_value against
            // Utc::now().timestamp(). Milliseconds made an until-time loop
            // never terminate (imaging straight through sunrise).
            conditionValue = n.repeatUntil == null
                ? null
                : n.repeatUntil!.millisecondsSinceEpoch ~/ 1000;
            break;
          case LoopConditionType.untilAltitude:
          case LoopConditionType.altitudeAbove:
            conditionValue = n.repeatUntilAltitude;
            break;
          case LoopConditionType.integrationTime:
            // The engine reads `condition_value` as the target integration
            // in SECONDS (loop_node.rs IntegrationTime arm), so it must carry
            // `integrationTimeTarget`, NOT the repeat count.
            conditionValue = n.integrationTimeTarget;
            break;
          case LoopConditionType.forever:
          case LoopConditionType.whileDark:
            conditionValue = null;
            break;
        }
        return {
          'type': 'Loop',
          'iterations': n.repeatCount,
          'condition': _loopConditionToString(n.conditionType),
          'condition_value': conditionValue,
        };
      case ParallelNode n:
        return {'type': 'Parallel', 'required_successes': n.requiredSuccesses};
      case ConditionalNode n:
        dynamic conditionValue;
        switch (n.conditionType) {
          case ConditionalType.always:
          case ConditionalType.weatherSafe:
          case ConditionalType.safetyMonitorSafe:
            conditionValue = null;
            break;
          case ConditionalType.altitudeAbove:
          case ConditionalType.guidingRmsBelow:
          case ConditionalType.hfrBelow:
          case ConditionalType.moonSeparationAbove:
            conditionValue = n.thresholdValue;
            break;
          case ConditionalType.timeAfter:
            // Unix SECONDS — ConditionalCheck::TimeAfter compares against
            // Utc::now().timestamp(). Milliseconds meant the condition was
            // never true, so the branch's children silently never ran.
            conditionValue = n.thresholdTime == null
                ? null
                : n.thresholdTime!.millisecondsSinceEpoch ~/ 1000;
            break;
        }
        // Audit C2: mirror the Rust `ConditionalConfig.safety_monitor_id`
        // field. Only emit it for the SafetyMonitorSafe variant so the
        // wire format stays unchanged for unrelated conditions (the Rust
        // dispatch ignores the field for other variants anyway, but
        // serialising it would be misleading). `#[serde(default)]` on
        // the Rust side keeps legacy sequences without the key parseable.
        final Map<String, dynamic> conditionalConfig = {
          'type': 'Conditional',
          'condition': {
            'type': _conditionalTypeToString(n.conditionType),
            'value': conditionValue,
          },
        };
        if (n.conditionType == ConditionalType.safetyMonitorSafe &&
            n.safetyMonitorId != null) {
          conditionalConfig['safety_monitor_id'] = n.safetyMonitorId;
        }
        return conditionalConfig;
      case RecoveryNode n:
        // Send the user-configured trigger to Rust. The
        // previous hardcoded `'trigger': null` meant the recovery node
        // matched ANY error, regardless of the UI selection — making the
        // trigger-type dropdown a placebo. `toRustTriggerConfig()` mirrors
        // the Rust serde-tagged `Option<TriggerType>` shape.
        return {
          'type': 'Recovery',
          'trigger': n.toRustTriggerConfig(),
          'recovery_action': _recoveryActionToRust(
            n.recoveryAction,
            n.maxRetries,
          ),
          'max_retries': n.maxRetries,
        };
      case MeridianFlipNode n:
        return _buildMeridianFlipConfig(n);
      case OpenDomeNode n:
        return {'type': 'OpenDome', 'shutter_only': n.shutterOnly};
      case CloseDomeNode n:
        return {'type': 'CloseDome', 'shutter_only': n.shutterOnly};
      case ParkDomeNode n:
        return {'type': 'ParkDome', 'shutter_only': n.shutterOnly};
      case PolarAlignmentNode n:
        return {
          'type': 'PolarAlignment',
          'step_size': n.rotationStep,
          'exposure_time': n.exposureDuration,
          'solve_timeout': 60.0, // Default timeout
          'manual_rotation': n.manualSlew,
          'rotate_east': n.isNorth, // Use isNorth as direction hint
          'gain': n.gain,
          'offset': n.offset,
          'binning': n.binning,
          // Required by PolarAlignConfig. Omitting them
          // hard-failed the whole sequence load ("missing field
          // `start_from_current`") for any sequence containing a Polar
          // Alignment node, and silently discarded the node's
          // start-from-current / hemisphere settings.
          'start_from_current': n.startFromCurrent,
          'is_north': n.isNorth,
          'auto_complete_threshold': 30.0, // engine default; no per-node UI
        };
      case OpenCoverNode n:
        return {'type': 'OpenCover', 'timeout_secs': n.timeoutSecs};
      case CloseCoverNode n:
        return {'type': 'CloseCover', 'timeout_secs': n.timeoutSecs};
      case CalibratorOnNode n:
        return {
          'type': 'CalibratorOn',
          'brightness': n.brightness,
          'timeout_secs': n.timeoutSecs,
        };
      case CalibratorOffNode n:
        return {'type': 'CalibratorOff', 'timeout_secs': n.timeoutSecs};
      // TargetScheduler dynamic target picker.
      case TargetSchedulerNode n:
        return {
          'type': 'TargetScheduler',
          'altitude_weight': n.altitudeWeight,
          'moon_distance_weight': n.moonDistanceWeight,
          'transit_proximity_weight': n.transitProximityWeight,
          'darkness_weight': n.darknessWeight,
          'airmass_weight': n.airmassWeight,
          'min_score_to_run': n.minScoreToRun,
          'recompute_every_n_exposures': n.recomputeEveryNExposures,
          'finish_iteration_on_switch': n.finishIterationOnSwitch,
          // Hard moon-avoidance gate (degrees). null => no hard gate.
          'min_moon_separation_deg': n.minMoonSeparationDeg,
          // Adaptive sky-conditions swap. `null` swap threshold
          // disables the feature for this scheduler instance.
          'swap_on_conditions_below': n.swapOnConditionsBelow,
          'swap_hysteresis_secs': n.swapHysteresisSecs,
          'brightness_tier_preferences': n.brightnessTierPreferences.toJson(),
          'max_conditions_score_age_secs': n.maxConditionsScoreAgeSecs,
          // Azimuth-dependent site-horizon mask. The Rust `horizon_profile`
          // config takes the samples-only shape; null => no mask (flat floor).
          'horizon_profile': n.horizonProfile == null
              ? null
              : {
                  'samples': n.horizonProfile!.samples
                      .map((s) => s.toJson())
                      .toList(),
                },
        };
      // Science: SciencePhotometry — cadence-enforced photometric capture.
      case SciencePhotometryNode n:
        return {'type': 'SciencePhotometry', ...n.toRustConfigJson()};
      // SmartExposure multi-filter container instruction.
      case SmartExposureNode n:
        // Auto-resolve the filter index from the active equipment profile
        // when the row was authored without one — matches the
        // auto-population that ExposureNode and FilterChangeNode already
        // do. Persisting the resolved index makes the executor's
        // ChangeFilter step robust to filter-name typos at runtime.
        final resolvedPlans = n.plans
            .map(
              (p) => {
                'filter_name': p.filterName,
                'filter_index':
                    p.filterIndex ?? _lookupFilterIndex(p.filterName),
                'count': p.count,
                'duration_secs': p.durationSecs,
                'gain': p.gain,
                'offset': p.offset,
                'binning': _binningToString(p.binning),
                'dither_every': p.ditherEvery,
                // Rust `FilterPlan::depth_goal` is `#[serde(default)]`: an
                // unbound plan sends nothing rather than an explicit null,
                // so pre-feature documents and executors stay identical.
                if (p.depthGoal case final binding?)
                  'depth_goal': {
                    'goal_id': binding.goalId,
                    'revision': binding.revision,
                  },
              },
            )
            .toList(growable: false);
        return {
          'type': 'SmartExposure',
          'plans': resolvedPlans,
          'rotate_filters': n.rotateFilters,
          'dither_on_filter_change': n.ditherOnFilterChange,
          'integration_budget_secs': n.integrationBudgetSecs,
          'batch_size': n.batchSize,
          'loop_until_stopped': n.loopUntilStopped,
        };
      // Audit §11 — plugin-contributed instruction. We forward the
      // plugin id, node-type id, opaque config JSON, optional display
      // name, and optional per-node timeout verbatim. The Rust executor
      // does NOT introspect `config_json`; when execution reaches this
      // node it emits `PluginNodeRequested`, which the Dart-side
      // `pluginNodeDispatcherProvider` routes through
      // `PluginNodeExecutor` (in skotiq_plugins).
      case PluginInstructionNode n:
        return {
          'type': 'PluginNode',
          'plugin_id': n.pluginId,
          'node_type_id': n.nodeTypeId,
          'config_json': n.configJson,
          'display_name': n.name,
          'timeout_secs': n.timeoutSecs,
        };
      // LiveStacking — broadcast / EAA node. The Rust
      // side serialises field names in snake_case so we mirror that
      // here. `auth_token` and `watermark_text` are emitted as `null`
      // (vs. omitted) for round-trip fidelity with the Rust
      // `#[serde(default)] Option<String>` fields.
      case LiveStackingNode n:
        return {
          'type': 'LiveStacking',
          'mode': n.mode.storageKey,
          'stack_method': n.stackMethod.storageKey,
          'max_frames_to_stack': n.maxFramesToStack,
          'broadcast_enabled': n.broadcastEnabled,
          'broadcast_port': n.broadcastPort,
          'broadcast_path': n.broadcastPath,
          'auth_token': n.authToken,
          'watermark_text': n.watermarkText,
          'thumbnail_width': n.thumbnailWidth,
          'thumbnail_height': n.thumbnailHeight,
        };
    }
  }

  /// Build the Rust `MeridianFlipConfig` JSON from the operator's GLOBAL
  /// meridian-flip settings, with no node involved.
  ///
  /// This is what the trigger-driven flip runs on: the standard
  /// `meridian_flip` trigger is seeded in Rust with
  /// `MeridianFlipConfig::default()`, so without this push the Settings →
  /// Meridian Flip panel does not reach the flip that fires on an unattended
  /// night.
  ///
  /// Shares [_buildMeridianFlipConfig]'s field list by delegating to it with a
  /// synthetic all-global node, so the two wire payloads can never drift.
  Map<String, dynamic> buildGlobalMeridianFlipConfigJson() =>
      _buildMeridianFlipConfig(MeridianFlipNode(useGlobalDefaults: true));

  /// Build the Rust-side MeridianFlipConfig JSON for a [MeridianFlipNode].
  ///
  /// The Rust struct [`MeridianFlipConfig`](native/.../lib.rs:875) carries no
  /// `#[serde(default)]` on most fields, so the JSON MUST include every
  /// required field. Two sources drive the final config:
  ///
  /// 1. `node.useGlobalDefaults == true` — the effective
  ///    `globalMeridianFlipSettingsProvider` snapshot is the source of truth,
  ///    so the settings in Sequencer Settings -> Meridian Flip drive node
  ///    behaviour at execution time.
  /// 2. `node.useGlobalDefaults == false` — the per-node fields take priority.
  ///    The global retry-delays / tracking wait minutes still flow through
  ///    because the node model doesn't carry them and the Rust struct requires
  ///    both.
  ///
  /// Enum names are emitted PascalCase to match Rust's
  /// `#[derive(Deserialize)]` default form.
  Map<String, dynamic> _buildMeridianFlipConfig(MeridianFlipNode node) {
    final global = _ref.read(effectiveMeridianFlipSettingsProvider);
    final useGlobal = node.useGlobalDefaults;
    // The post-flip guide re-lock settles using the user's global guiding
    // settle settings (the same knobs a Start Guiding node uses), so a tuned
    // settle is honoured after a flip. Null (settings not loaded) leaves these
    // keys off the JSON so the Rust MeridianFlipConfig serde defaults apply.
    final appSettings = _ref.read(appSettingsProvider).valueOrNull;

    final triggerMethod = useGlobal ? global.triggerMethod : node.triggerMethod;
    final minutesPastMeridian = useGlobal
        ? global.minutesPastMeridian
        : node.minutesPastMeridian;
    final minutesBeforeLimit = useGlobal
        ? global.minutesBeforeLimit
        : node.minutesBeforeLimit;
    final hourAngleThreshold = useGlobal
        ? global.hourAngleThreshold
        : node.hourAngleThreshold;
    final pauseGuiding = useGlobal
        ? global.pauseGuidingBeforeFlip
        : node.pauseGuiding;
    final autoCenter = useGlobal ? global.recenterAfterFlip : node.autoCenter;
    final refocusAfter = useGlobal
        ? global.refocusAfterFlip
        : node.refocusAfter;
    final settleTime = useGlobal ? global.settleTimeSeconds : node.settleTime;
    final resumeGuiding = useGlobal
        ? global.resumeGuidingAfterFlip
        : node.resumeGuiding;
    final maxRetries = useGlobal ? global.maxRetries : node.maxRetries;
    final failureAction = useGlobal ? global.failureAction : node.failureAction;

    return {
      'type': 'MeridianFlip',
      'trigger_method': _meridianTriggerMethodToString(triggerMethod),
      'minutes_past_meridian': minutesPastMeridian,
      'minutes_before_limit': minutesBeforeLimit,
      'hour_angle_threshold': hourAngleThreshold,
      // Why: only the global model carries tracking-limit wait minutes and
      // retry delays — the per-node fields never existed. These are required
      // by MeridianFlipConfig regardless of useGlobalDefaults.
      'tracking_limit_wait_minutes': global.trackingLimitWaitMinutes,
      'pause_guiding': pauseGuiding,
      'auto_center': autoCenter,
      'refocus_after': refocusAfter,
      'settle_time': settleTime,
      'resume_guiding': resumeGuiding,
      'max_retries': maxRetries,
      'retry_delays_secs': global.retryDelaysSeconds,
      'failure_action': _flipFailureActionToString(failureAction),
      // Post-flip guider re-lock settle, sourced from the user's guiding settle
      // settings so it matches a normal Start Guiding. Omitted when settings
      // aren't loaded yet (Rust serde defaults 1.5px/10s/60s then apply).
      if (appSettings != null) ...{
        'guider_settle_pixels': appSettings.settleThreshold,
        'guider_settle_time': appSettings.settleTime.toDouble(),
        'guider_settle_timeout': appSettings.settleTimeout.toDouble(),
      },
    };
  }

  /// Rust expects PascalCase enum names; Dart's `.name` is camelCase. Map
  /// explicitly so this conversion never silently regresses.
  String _meridianTriggerMethodToString(MeridianTriggerMethod method) {
    switch (method) {
      case MeridianTriggerMethod.minutesPastMeridian:
        return 'MinutesPastMeridian';
      case MeridianTriggerMethod.minutesBeforeLimit:
        return 'MinutesBeforeLimit';
      case MeridianTriggerMethod.hourAngleThreshold:
        return 'HourAngleThreshold';
      case MeridianTriggerMethod.onTrackingLimitHit:
        return 'OnTrackingLimitHit';
    }
  }

  String _flipFailureActionToString(FlipFailureAction action) {
    switch (action) {
      case FlipFailureAction.pauseAndAlert:
        return 'PauseAndAlert';
      case FlipFailureAction.abortAndPark:
        return 'AbortAndPark';
    }
  }

  /// Wire form of [FrameType] for the Rust `ExposureConfig.frame_type`
  /// field — PascalCase because it lands verbatim in the FITS `IMAGETYP`
  /// keyword via `FrameContext.frame_type`.
  String _frameTypeToWire(FrameType type) => switch (type) {
    FrameType.light => 'Light',
    FrameType.dark => 'Dark',
    FrameType.flat => 'Flat',
    FrameType.bias => 'Bias',
    FrameType.darkFlat => 'DarkFlat',
    FrameType.snapshot => 'Snapshot',
  };

  String _binningToString(BinningMode binning) {
    switch (binning) {
      case BinningMode.one:
        return 'One';
      case BinningMode.two:
        return 'Two';
      case BinningMode.three:
        return 'Three';
      case BinningMode.four:
        return 'Four';
    }
  }

  String _autofocusMethodToString(AutofocusMethod method) {
    switch (method) {
      case AutofocusMethod.vCurve:
        return 'VCurve';
      case AutofocusMethod.hyperbolic:
        return 'Hyperbolic';
      case AutofocusMethod.quadratic:
        return 'Quadratic';
    }
  }

  String _twilightToString(TwilightType type) {
    switch (type) {
      case TwilightType.civil:
        return 'Civil';
      case TwilightType.nautical:
        return 'Nautical';
      case TwilightType.astronomical:
        return 'Astronomical';
    }
  }

  String _notificationLevelToString(NotificationLevel level) {
    switch (level) {
      case NotificationLevel.info:
        return 'Info';
      case NotificationLevel.warning:
        return 'Warning';
      case NotificationLevel.error:
        return 'Error';
      case NotificationLevel.success:
        return 'Success';
    }
  }

  String safetyFailModeToBackendString(SafetyFailMode mode) => switch (mode) {
    SafetyFailMode.failOpen => 'fail_open',
    SafetyFailMode.warnOnly => 'warn_only',
    SafetyFailMode.failClosed => 'fail_closed',
  };

  String _loopConditionToString(LoopConditionType type) {
    switch (type) {
      case LoopConditionType.count:
        return 'Count';
      case LoopConditionType.untilTime:
        return 'UntilTime';
      case LoopConditionType.untilAltitude:
        return 'AltitudeBelow';
      case LoopConditionType.altitudeAbove:
        return 'AltitudeAbove';
      case LoopConditionType.integrationTime:
        return 'IntegrationTime';
      case LoopConditionType.forever:
        return 'Forever';
      case LoopConditionType.whileDark:
        return 'WhileDark';
    }
  }

  String _conditionalTypeToString(ConditionalType type) {
    switch (type) {
      case ConditionalType.always:
        return 'Always';
      case ConditionalType.altitudeAbove:
        return 'AltitudeAbove';
      case ConditionalType.timeAfter:
        return 'TimeAfter';
      case ConditionalType.guidingRmsBelow:
        return 'GuidingRmsBelow';
      case ConditionalType.hfrBelow:
        return 'HfrBelow';
      case ConditionalType.weatherSafe:
        return 'WeatherSafe';
      case ConditionalType.moonSeparationAbove:
        return 'MoonSeparationAbove';
      case ConditionalType.safetyMonitorSafe:
        return 'SafetyMonitorSafe';
    }
  }

  /// Serialise a [RecoveryActionType] into the shape Rust's serde
  /// `RecoveryAction` enum expects.
  ///
  /// Most variants are Rust UNIT variants and serialise to a bare string
  /// (externally-tagged serde default). `Retry` is the exception: it is a Rust
  /// STRUCT variant `Retry { max_attempts: u32 }`, so serde requires the
  /// externally-tagged object form `{"Retry": {"max_attempts": N}}`. Emitting
  /// the bare string `"Retry"` made the whole sequence fail to deserialize at
  /// load (the bridge collects every node via `nodes?`, so one bad node aborts
  /// the entire load with InvalidInput). [maxRetries] carries the user-selected
  /// attempt budget across the bridge.
  Object _recoveryActionToRust(RecoveryActionType action, int maxRetries) {
    if (action == RecoveryActionType.retry) {
      return {
        'Retry': {'max_attempts': maxRetries},
      };
    }
    return _recoveryActionToString(action);
  }

  String _recoveryActionToString(RecoveryActionType action) {
    switch (action) {
      case RecoveryActionType.continueExecution:
        return 'Continue';
      case RecoveryActionType.pause:
        return 'Pause';
      case RecoveryActionType.autofocus:
        return 'Autofocus';
      case RecoveryActionType.nextTarget:
        return 'NextTarget';
      case RecoveryActionType.retry:
        // Should not be reached for the live serialiser path
        // (_recoveryActionToRust special-cases retry into the struct-variant
        // object form). Kept for exhaustiveness; the bare string only
        // deserialises a UNIT variant and is wrong for Rust's
        // `Retry { max_attempts }`.
        return 'Retry';
      case RecoveryActionType.parkAndAbort:
        return 'ParkAndAbort';
      case RecoveryActionType.customBranch:
        return 'CustomBranch';
      // Cloud-motion-aware recovery actions. Names match
      // the Rust enum variants so the deserialiser in skotiq_sequencer
      // accepts the bare-string form.
      case RecoveryActionType.pauseAndWaitForClear:
        return 'PauseAndWaitForClear';
      case RecoveryActionType.slewToGapAndContinue:
        return 'SlewToGapAndContinue';
      // Science — transparency-adaptive recovery. Bare-string
      // form because the Rust variant has no payload.
      case RecoveryActionType.switchTargetOrFilter:
        return 'SwitchTargetOrFilter';
      case RecoveryActionType.notify:
        return 'Notify';
    }
  }
}
