import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/sequence/sequence_models.dart';
import '../settings_provider.dart';
// Sky-brightness adaptive exposure validation rules.
import 'rules/adaptive_exposure_rules.dart';
// "Who owns the rig" — unattended autopilot vs a hand-started run.
import 'rules/autopilot_rules.dart';
// Per-frame defect-map validation rules.
import 'rules/defect_map_rules.dart';
import 'rules/disk_space_rules.dart';
import 'rules/equipment_rules.dart';
import 'rules/exposure_rules.dart';
import 'rules/filter_rules.dart';
import 'rules/logic_node_rules.dart';
import 'rules/plate_solver_rules.dart';
import 'rules/plugin_node_rules.dart';
// Pre-flight checks (darks + equipment health + optical train).
import 'rules/preflight_rules.dart';
import 'rules/settings_rules.dart';
// Daylight gate / observing site / mount-pointing pre-flight rules.
import 'rules/sky_readiness_rules.dart';
// LiveStacking node validation rules.
import 'rules/live_stacking_rules.dart';
// Science: SciencePhotometry node validation rules.
import 'rules/science_photometry_rules.dart';
// SmartExposure node validation rules.
import 'rules/smart_exposure_rules.dart';
import 'rules/structure_rules.dart';
import 'rules/target_rules.dart';
// TargetScheduler node validation rules.
import 'rules/target_scheduler_rules.dart';
import 'rules/timing_rules.dart';
import 'rules/weather_safety_rules.dart';

// Unified sequence validation.
//
// This file is the single source of truth for sequence validation.
//
//   * Pure structural rules are sync and live under `rules/`.
//   * Ref-aware rules (equipment connection, filter wheel content, app
//     settings, disk space) are also under `rules/` and take a
//     [ValidationContext].
//
// Live in-tree validation (the per-node coloured border + counts in the tree
// header) and the pre-flight dialog both call into [SequenceValidator] here.
// Add a new rule by adding it to [defaultSequenceValidators] /
// [defaultRefAwareSequenceValidators]. Don't fork the engine.

/// Severity of a validation issue. Three levels:
///
///   * [error] — blocks sequence execution. The pre-flight dialog refuses to
///     start the sequence.
///   * [warning] — sequence will run but something is suspicious or could
///     misbehave at runtime.
///   * [info] — informational; no action required, but the user might want
///     to know.
enum ValidationSeverity { error, warning, info }

/// Coarse category used by the dialog UI to group issues. Adding a category
/// requires updating UI code that switches on it.
enum ValidationCategory {
  structure,
  targets,
  exposures,
  equipment,
  timing,
  settings,
  diskSpace,
  // Pre-flight checks. New categories so the pre-flight
  // dialog can group these in their own collapsible sections instead of
  // mixing them with the structural / equipment-connection issues.
  /// Dark library coverage (matching dark frames for the sequence's
  /// (gain, offset, temp, duration, binning) combinations).
  darkLibrary,

  /// Long-term equipment health (USB stability, focuser range, mount
  /// alignment freshness, time sync, cooler delta, filter wheel
  /// homing).
  equipmentHealth,

  /// Optical-train drift / pre-session calibration comparison.
  opticalTrain,
}

/// Display label for [ValidationCategory] — used by the dialog UI.
extension ValidationCategoryLabel on ValidationCategory {
  String get label {
    switch (this) {
      case ValidationCategory.structure:
        return 'Structure';
      case ValidationCategory.targets:
        return 'Targets';
      case ValidationCategory.exposures:
        return 'Imaging';
      case ValidationCategory.equipment:
        return 'Equipment';
      case ValidationCategory.timing:
        return 'Timing';
      case ValidationCategory.settings:
        return 'Settings';
      case ValidationCategory.diskSpace:
        return 'Storage';
      case ValidationCategory.darkLibrary:
        return 'Dark Library';
      case ValidationCategory.equipmentHealth:
        return 'Equipment Health';
      case ValidationCategory.opticalTrain:
        return 'Optical Train';
    }
  }
}

/// A single validation finding.
///
/// Plain immutable value class with const constructor + value equality. We
/// intentionally do not use freezed here — the equivalent value classes in
/// the sequence subsystem ([SequenceProgress] etc.) are also hand-rolled,
/// and the additional codegen would not buy us anything.
class ValidationIssue {
  final ValidationSeverity severity;
  final ValidationCategory category;
  final String title;
  final String description;

  /// Optional concrete hint the user can act on. Surfaced beneath the
  /// description in the pre-flight dialog.
  final String? resolutionHint;

  /// Optional id of the offending node. When present, the tree paints a
  /// matching coloured border / badge on that node.
  final String? affectedNodeId;

  /// Optional stable machine-readable code (e.g.
  /// `image_output_path_not_configured`). Set on issues that REST
  /// clients need to programmatically branch on so the wire payload
  /// doesn't depend on the human-readable `title` text.
  final String? code;

  const ValidationIssue({
    required this.severity,
    required this.category,
    required this.title,
    required this.description,
    this.resolutionHint,
    this.affectedNodeId,
    this.code,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ValidationIssue &&
          runtimeType == other.runtimeType &&
          severity == other.severity &&
          category == other.category &&
          title == other.title &&
          description == other.description &&
          resolutionHint == other.resolutionHint &&
          affectedNodeId == other.affectedNodeId &&
          code == other.code;

  @override
  int get hashCode => Object.hash(
    severity,
    category,
    title,
    description,
    resolutionHint,
    affectedNodeId,
    code,
  );

  @override
  String toString() =>
      'ValidationIssue($severity, $category, "$title"${affectedNodeId != null ? ", node=$affectedNodeId" : ""}${code != null ? ", code=$code" : ""})';
}

/// Aggregated result of running all validators against a sequence.
class ValidationResult {
  final List<ValidationIssue> issues;
  final DateTime validatedAt;

  const ValidationResult({required this.issues, required this.validatedAt});

  factory ValidationResult.empty() =>
      ValidationResult(issues: const [], validatedAt: DateTime.now());

  bool get hasErrors =>
      issues.any((i) => i.severity == ValidationSeverity.error);
  bool get hasWarnings =>
      issues.any((i) => i.severity == ValidationSeverity.warning);
  bool get hasInfo => issues.any((i) => i.severity == ValidationSeverity.info);

  /// Sequence may start iff there are no errors.
  bool get isValid => !hasErrors;

  int get errorCount =>
      issues.where((i) => i.severity == ValidationSeverity.error).length;
  int get warningCount =>
      issues.where((i) => i.severity == ValidationSeverity.warning).length;
  int get infoCount =>
      issues.where((i) => i.severity == ValidationSeverity.info).length;

  int get totalCount => issues.length;

  /// Returns issues grouped by `affectedNodeId`. Issues with a null
  /// affectedNodeId are not included.
  Map<String, List<ValidationIssue>> get issuesByNodeId {
    final byNode = <String, List<ValidationIssue>>{};
    for (final issue in issues) {
      final id = issue.affectedNodeId;
      if (id != null) {
        byNode.putIfAbsent(id, () => <ValidationIssue>[]).add(issue);
      }
    }
    return byNode;
  }

  /// Worst severity (error > warning > info) attached to a given node, or
  /// null if the node has no issues.
  ValidationSeverity? worstSeverityForNode(String nodeId) {
    final nodeIssues = issuesByNodeId[nodeId];
    if (nodeIssues == null || nodeIssues.isEmpty) return null;
    if (nodeIssues.any((i) => i.severity == ValidationSeverity.error)) {
      return ValidationSeverity.error;
    }
    if (nodeIssues.any((i) => i.severity == ValidationSeverity.warning)) {
      return ValidationSeverity.warning;
    }
    return ValidationSeverity.info;
  }
}

/// Context passed to ref-aware validators. Carries the Riverpod `Ref` so
/// rules can `read` equipment state / settings without dragging Riverpod
/// types into the rule constructors.
class ValidationContext {
  final Ref ref;
  const ValidationContext(this.ref);
}

/// A single composable validator that knows how to check one specific class
/// of problem. Implementations should be small and grep-able — one rule per
/// class. Synchronous; rules needing async data should resolve it via
/// [ValidationContext.ref.read] of an already-loaded provider (the disk-space
/// rule is the lone async exception and implements [AsyncSequenceValidator]).
abstract class SequenceValidator {
  /// Stable, human-readable name. Used by debugging / logs and in test
  /// failure messages.
  String get name;

  /// Run this rule against a sequence. Implementations MUST NOT return null;
  /// return an empty list if the rule is clean. Implementations must not
  /// silently swallow missing context — if data is unavailable, emit an
  /// `info` severity issue explaining that the check could not run.
  List<ValidationIssue> validate(Sequence sequence);
}

/// Variant of [SequenceValidator] that needs `Ref` to read providers (e.g.
/// equipment connection state). Always pass a [ValidationContext].
abstract class RefAwareSequenceValidator {
  String get name;

  List<ValidationIssue> validate(Sequence sequence, ValidationContext ctx);
}

/// Variant that does async I/O (disk-space queries currently). Kept separate
/// so the live in-tree validator can skip async checks and stay sync.
abstract class AsyncSequenceValidator {
  String get name;

  Future<List<ValidationIssue>> validate(
    Sequence sequence,
    ValidationContext ctx,
  );
}

/// The full set of pure structural validators. Order is preserved in the
/// output.
final List<SequenceValidator> defaultSequenceValidators =
    List<SequenceValidator>.unmodifiable(<SequenceValidator>[
      EmptySequenceRule(),
      MissingRootNodeRule(),
      OrphanedNodesRule(),
      EmptyContainerRule(),
      TargetCoordinatesRule(),
      TargetCoordinatesUnsetRule(),
      EmptyTargetRule(),
      LowAltitudeLimitRule(),
      // Per-target integration budget validators.
      IntegrationBudgetEmptyRule(),
      IntegrationBudgetRatioZeroSumRule(),
      IntegrationBudgetRatioWithoutTotalRule(),
      // Per-target altitude/time crossing validators. The
      // ImpossibleAltitude rule needs an observer latitude to be useful; we
      // wire it up below in `sequenceValidatorsFor(latitude)` if/when the
      // caller has one. The structural rules (empty compound,
      // start/end contradiction) work without an observer.
      TargetTriggerEmptyCompoundRule(),
      const TargetTriggerStartEndContradictionRule(),
      NoTargetForExposuresRule(),
      ExposureParamsRule(),
      HighBinningRule(),
      NoExposuresRule(),
      LongTotalIntegrationRule(),
      UnboundedLoopRule(),
      SlewCoordinatesRule(),
      WaitTimePastRule(),
      WaitTimeUnconfiguredRule(),
      LoopUntilTimeUnsetRule(),
      LoopEndTimePastRule(),
      // Logic-node-specific rules (Recovery / Parallel / Conditional).
      RecoveryNodeConfigRule(),
      // Cloud-motion-aware trigger config validation.
      CloudTriggerConfigRule(),
      ParallelNodeRequiredSuccessesRule(),
      ConditionalNodeEmptyBranchRule(),
      LoopUnreachableTerminationRule(),
      // A Loop at 1 iteration and a Conditional set to Always are both no-ops
      // and must be flagged.
      NoOpLogicNodeRule(),
      PluginNodeConfigurationRule(),
      // SmartExposure validation.
      SmartExposureEmptyPlansRule(),
      SmartExposureNegativeCountRule(),
      SmartExposureUnboundedLoopRule(),
      // Science: SciencePhotometry validation.
      SciencePhotometryFilterRule(),
      SciencePhotometryReferenceStarsEmptyRule(),
      SciencePhotometryCadenceRule(),
      // LiveStacking node validation.
      LiveStackingNoExposureRule(),
      LiveStackingPortClashRule(),
      // TargetScheduler validation.
      TargetSchedulerNoChildrenRule(),
      TargetSchedulerNonTargetChildRule(),
      TargetSchedulerWeightsRule(),
      // Sky-brightness adaptive exposure validation.
      AdaptiveExposureBoundsRule(),
      AdaptiveExposureNoFilterEnabledRule(),
      AdaptiveExposureNominalOutOfBoundsRule(),
    ]);

/// The full set of ref-aware validators (read providers but no I/O).
final List<RefAwareSequenceValidator> defaultRefAwareSequenceValidators =
    List<RefAwareSequenceValidator>.unmodifiable(<RefAwareSequenceValidator>[
      PluginNodeAvailabilityRule(),
      // Something else may already own the mount.
      AutopilotArmedRule(),
      EquipmentConnectionRule(),
      // The executor refuses a centring sequence with no solver; say so first.
      PlateSolverForCenteringRule(),
      PlateSolveFocalLengthRule(),
      RotatorRotationConflictRule(),
      FilterInWheelRule(),
      // Same check against the equipment profile for the daylight case, when
      // no wheel is connected and FilterInWheelRule cannot run.
      FilterInProfileRule(),
      // Fail-closed weather gate with no sensor aborts the run seconds in.
      WeatherSafetyNoSourceRule(),
      // The daylight gate refuses every light frame categorically; the missing
      // observing site disables it silently; a target with no Slew images
      // whatever the mount was left on.
      DaylightGateRule(),
      ObserverLocationUnsetRule(),
      MountOffTargetRule(),
      ImageOutputPathRule(),
      DefaultSequenceNameRule(),
      LongEstimatedDurationRule(),
      MeridianFlipTriggerRule(),
      // SmartExposure needs a filter wheel.
      SmartExposureFilterWheelMissingRule(),
      // Audit C6: every SmartExposure row's filterName must match a filter
      // configured in the active equipment profile.
      SmartExposureFilterUnknownRule(),
      // LiveStacking global kill-switch check (reads sequencerDefaults).
      LiveStackingGloballyDisabledRule(),
      // Pre-flight equipment-health checks (synchronous —
      // they only read providers, no network / disk I/O).
      UsbStabilityRule(),
      FocuserRangeRule(),
      PolarAlignmentFreshnessRule(),
      CoolerDeltaRule(),
      FilterWheelHomingRule(),
      OpticalTrainPreflightRule(),
      // Defect-map calibration check. Warns when the user
      // enabled auto-apply but no map exists for the current camera/bucket.
      DefectMapAppliedButCalibrationOffRule(),
    ]);

/// The full set of async validators (perform I/O — disk space).
final List<AsyncSequenceValidator> defaultAsyncSequenceValidators =
    List<AsyncSequenceValidator>.unmodifiable(<AsyncSequenceValidator>[
      DiskSpaceProjectionRule(),
      // Pre-flight async checks (query dark library DAO,
      // NTP). Live in the async tier so the live in-tree validator (which
      // runs on every keystroke) doesn't trigger them.
      DarkLibraryCoverageRule(),
      HistoryDrivenQualityRule(),
      TimeSyncRule(),
    ]);

/// Provider that exposes the canonical validator. UI / providers consume
/// this — they should not new up [SequenceValidator] directly except in
/// tests.
final sequenceValidatorProvider =
    Provider.autoDispose<SequenceValidatorService>((ref) {
      return SequenceValidatorService(
        ref: ref,
        syncRules: defaultSequenceValidators,
        refAwareRules: defaultRefAwareSequenceValidators,
        asyncRules: defaultAsyncSequenceValidators,
      );
    });

/// Service that runs all registered validators against a sequence.
///
/// Has two modes:
///   * [validateSync] — runs only the pure structural and ref-aware rules.
///     Used by the live in-tree validation provider where we don't want
///     async work on every keystroke.
///   * [validate] — runs the full set including disk-space (async).
///     Used by the pre-flight dialog before the sequence starts.
class SequenceValidatorService {
  final Ref _ref;
  final List<SequenceValidator> _syncRules;
  final List<RefAwareSequenceValidator> _refAwareRules;
  final List<AsyncSequenceValidator> _asyncRules;

  SequenceValidatorService({
    required Ref ref,
    required List<SequenceValidator> syncRules,
    required List<RefAwareSequenceValidator> refAwareRules,
    required List<AsyncSequenceValidator> asyncRules,
  }) : _ref = ref,
       _syncRules = syncRules,
       _refAwareRules = refAwareRules,
       _asyncRules = asyncRules;

  /// Runs only synchronous rules. Safe to call from non-async UI paths.
  ValidationResult validateSync(Sequence sequence) {
    final issues = <ValidationIssue>[];
    final ctx = ValidationContext(_ref);
    for (final rule in _syncRules) {
      issues.addAll(rule.validate(sequence));
    }
    for (final rule in _refAwareRules) {
      issues.addAll(rule.validate(sequence, ctx));
    }
    return ValidationResult(issues: issues, validatedAt: DateTime.now());
  }

  /// Runs the full validator stack including async rules (disk space).
  Future<ValidationResult> validate(Sequence sequence) async {
    // Settings-dependent rules intentionally use the already-loaded snapshot
    // so synchronous live validation stays cheap. A full pre-flight must first
    // make that snapshot authoritative; otherwise a fresh-start validation can
    // silently skip strictness, dark-library, clock, cooler, and alignment
    // checks while settings are still loading.
    await _ref.read(appSettingsProvider.future);

    final issues = <ValidationIssue>[];
    final ctx = ValidationContext(_ref);
    for (final rule in _syncRules) {
      issues.addAll(rule.validate(sequence));
    }
    for (final rule in _refAwareRules) {
      issues.addAll(rule.validate(sequence, ctx));
    }
    for (final rule in _asyncRules) {
      issues.addAll(await rule.validate(sequence, ctx));
    }
    return ValidationResult(issues: issues, validatedAt: DateTime.now());
  }
}

/// Convenience top-level function for the pure structural validators only.
///
/// Kept for callers that have no `Ref` (e.g. the sequence executor's
/// `start()` pre-check, which already executes inside Riverpod but needed a
/// way to validate before paying for equipment lookups). For full
/// validation including equipment / disk space, depend on
/// [sequenceValidatorProvider] instead.
List<ValidationIssue> validateSequence(Sequence sequence) {
  final issues = <ValidationIssue>[];
  for (final rule in defaultSequenceValidators) {
    issues.addAll(rule.validate(sequence));
  }
  return issues;
}

/// Typed exception thrown by start paths (executor.start(),
/// sequence_action_service.start(), the headless POST /sequencer/start
/// handler) when pre-flight validation finds at least one
/// [ValidationSeverity.error] issue.
///
/// Carries the full [ValidationResult] so callers surface ALL findings; a
/// first-error-wins `Exception` truncates the rest and sends the operator back
/// for another round per error.
class SequenceValidationException implements Exception {
  /// Complete validation result. Includes errors, warnings, and info-level
  /// issues. Callers should typically only block on `result.errorCount`.
  final ValidationResult result;

  const SequenceValidationException(this.result);

  /// All blocking issues (severity == error). Convenience accessor.
  List<ValidationIssue> get errors => result.issues
      .where((i) => i.severity == ValidationSeverity.error)
      .toList(growable: false);

  /// Concise one-line summary suitable for a snackbar / log line. Includes
  /// the count and the title of every error (joined with `; `) so callers
  /// that simply `print(e)` still surface every blocking finding.
  @override
  String toString() {
    final errs = errors;
    if (errs.isEmpty) {
      // Defensive: callers should not throw this without errors, but if
      // they do we still produce a useful string instead of an empty one.
      return 'SequenceValidationException(no errors)';
    }
    final titles = errs.map((e) => e.title).join('; ');
    return 'Cannot start sequence: ${errs.length} validation '
        '${errs.length == 1 ? 'error' : 'errors'}: $titles';
  }

  /// Structured form for the headless API / remote callers. Mirrors the
  /// shape of the in-app pre-flight dialog so a remote dashboard can
  /// render the same UI as the desktop.
  Map<String, Object?> toJsonBody() => {
    'code': 'sequence_validation_failed',
    'message': toString(),
    'errorCount': result.errorCount,
    'warningCount': result.warningCount,
    'infoCount': result.infoCount,
    'issues': result.issues
        .map(
          (i) => {
            'severity': i.severity.name,
            'category': i.category.name,
            'title': i.title,
            'description': i.description,
            if (i.resolutionHint != null) 'resolutionHint': i.resolutionHint,
            if (i.affectedNodeId != null) 'affectedNodeId': i.affectedNodeId,
            if (i.code != null) 'code': i.code,
          },
        )
        .toList(),
  };
}

/// Rejects a target whose sky position was never chosen.
///
/// [TargetHeaderNode] has no nullable coordinate meaning "no pointing picked
/// yet", so a target added from the palette starts at exactly RA 0h / Dec +0°.
/// That is a real point in Pisces and both values are in range, so
/// [TargetCoordinatesRule] passes it. The runtime then stamps the placeholder
/// onto the execution context for the whole subtree: a Slew below it drives
/// the mount to Pisces and every frame captured under it is recorded claiming
/// that pointing under the target's name. Only validation runs before the
/// mount moves, so this is the last place an unattended run can be stopped.
///
/// The editor surfaces that render this state already refuse to confirm it
/// (the Slew editor warns instead of showing "Will use target: M31" in
/// green); this rule is the matching gate on the start path.
class TargetCoordinatesUnsetRule implements SequenceValidator {
  /// True while [node] still carries the (0h, +0°) placeholder. A deliberate
  /// origin pointing reads as unset as well; nudging either value by the
  /// ten-thousandth of a unit the coordinate editor already exposes claims it
  /// back.
  static bool isUnset(TargetHeaderNode node) =>
      node.raHours == 0 && node.decDegrees == 0;

  @override
  String get name => 'TargetCoordinatesUnset';

  @override
  List<ValidationIssue> validate(Sequence sequence) {
    final issues = <ValidationIssue>[];
    for (final target in sequence.targetHeaders) {
      if (!isUnset(target)) continue;

      // Block only when the placeholder actually reaches hardware or frame
      // metadata on this run. A half-built target nobody has wired up yet is
      // still worth flagging in the tree, but blocking an unrelated run on it
      // would train the operator to ignore the pre-flight dialog.
      final consumed =
          _isLive(sequence, target) &&
          (_hasEnabledInstruction(sequence, target) ||
              _hasExternalPointingConsumer(sequence, target));

      issues.add(
        ValidationIssue(
          severity: consumed
              ? ValidationSeverity.error
              : ValidationSeverity.warning,
          category: ValidationCategory.targets,
          title: 'Target Coordinates Not Set',
          description: consumed
              ? 'Target "${target.targetName}" is still at the RA 0h / Dec +0° '
                    'placeholder. Starting this sequence would point the mount '
                    'at that spot in Pisces and record every frame under it as '
                    '"${target.targetName}".'
              : 'Target "${target.targetName}" is still at the RA 0h / Dec +0° '
                    'placeholder. Nothing enabled under it points there yet, so '
                    'the run is not affected — but the target does not know '
                    'where it is.',
          affectedNodeId: target.id,
          code: 'target_coordinates_unset',
          resolutionHint:
              'Look "${target.targetName}" up in the target editor, or enter '
              'its RA/Dec by hand.',
        ),
      );
    }
    return issues;
  }

  /// True when [node] and every ancestor up to the root are enabled — i.e.
  /// the node is reachable on this run. A disabled container silences
  /// everything beneath it, so its subtree can never move the mount.
  static bool _isLive(Sequence sequence, SequenceNode node) {
    final seen = <String>{};
    SequenceNode? cursor = node;
    while (cursor != null && seen.add(cursor.id)) {
      if (!cursor.isEnabled) return false;
      final parentId = cursor.parentId;
      cursor = parentId == null ? null : sequence.nodes[parentId];
    }
    return true;
  }

  /// True when at least one enabled leaf instruction sits under [parent] with
  /// no disabled container in between. Containers alone execute nothing, so
  /// an empty (or fully disabled) target never consumes its own coordinates.
  static bool _hasEnabledInstruction(
    Sequence sequence,
    SequenceNode parent, [
    Set<String>? seen,
  ]) {
    final visited = seen ?? <String>{parent.id};
    for (final id in parent.childIds) {
      final child = sequence.nodes[id];
      if (child == null || !child.isEnabled) continue;
      if (!visited.add(child.id)) continue;
      if (!isContainerNode(child)) return true;
      if (_hasEnabledInstruction(sequence, child, visited)) return true;
    }
    return false;
  }

  /// True when an enabled Slew/Center that inherits its pointing resolves to
  /// [target] from outside the target's own subtree. Such a node has no
  /// TargetHeader ancestor and falls back to the first target in the
  /// sequence — the same resolution the Slew editor shows the user — so an
  /// otherwise-idle target can still be what aims the mount.
  static bool _hasExternalPointingConsumer(
    Sequence sequence,
    TargetHeaderNode target,
  ) {
    for (final node in sequence.nodes.values) {
      final inheritsPointing = switch (node) {
        SlewNode(useTargetCoords: final use) ||
        CenterNode(useTargetCoords: final use) => use,
        _ => false,
      };
      if (!inheritsPointing) continue;
      if (!_isLive(sequence, node)) continue;
      if (_resolvePointingSource(sequence, node)?.id != target.id) continue;
      return true;
    }
    return false;
  }

  /// The TargetHeader a pointing-inheriting node reads its coordinates from:
  /// the nearest TargetHeader ancestor, else the first target in the
  /// sequence.
  static TargetHeaderNode? _resolvePointingSource(
    Sequence sequence,
    SequenceNode node,
  ) {
    final seen = <String>{};
    SequenceNode? cursor = node;
    while (cursor != null && seen.add(cursor.id)) {
      if (cursor is TargetHeaderNode) return cursor;
      final parentId = cursor.parentId;
      cursor = parentId == null ? null : sequence.nodes[parentId];
    }
    final targets = sequence.targetHeaders;
    return targets.isEmpty ? null : targets.first;
  }
}

/// True for node types that own a child list (Target/Loop/Parallel/Conditional/
/// Recovery/InstructionSet). Used by validation rules to flag empty
/// containers and by editor logic that decides where to attach new nodes.
///
/// `SequenceNode` is sealed, so every concrete subtype must be classified
/// below. Adding a new node type will produce a compile-time error here
/// instead of silently defaulting to "not a container".
bool isContainerNode(SequenceNode node) {
  return switch (node) {
    TargetHeaderNode _ ||
    LoopNode _ ||
    ParallelNode _ ||
    ConditionalNode _ ||
    RecoveryNode _ ||
    InstructionSetNode _ ||
    // TargetScheduler holds child target headers and picks
    // among them at runtime.
    TargetSchedulerNode _ => true,
    // Leaf nodes (instructions / triggers) do not own children
    ExposureNode _ ||
    SlewNode _ ||
    CenterNode _ ||
    AutofocusNode _ ||
    DitherNode _ ||
    StartGuidingNode _ ||
    StopGuidingNode _ ||
    FilterChangeNode _ ||
    CoolCameraNode _ ||
    WarmCameraNode _ ||
    RotatorNode _ ||
    ParkNode _ ||
    UnparkNode _ ||
    HomeMountNode _ ||
    WaitTimeNode _ ||
    DelayNode _ ||
    NotificationNode _ ||
    ScriptNode _ ||
    MeridianFlipNode _ ||
    OpenDomeNode _ ||
    CloseDomeNode _ ||
    ParkDomeNode _ ||
    PolarAlignmentNode _ ||
    OpenCoverNode _ ||
    CloseCoverNode _ ||
    CalibratorOnNode _ ||
    CalibratorOffNode _ ||
    // SmartExposure — leaf instruction (per-filter
    // behaviour is encoded in `plans`, no children).
    SmartExposureNode _ ||
    // LiveStacking — leaf side-effect instruction.
    LiveStackingNode _ ||
    // Science: SciencePhotometry — leaf instruction.
    SciencePhotometryNode _ ||
    // Plugin-contributed instruction. Leaf.
    PluginInstructionNode _ => false,
  };
}
