import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/sequence/sequence_models.dart';
import '../../models/sequence/validation/structural_rules.dart';
import '../../models/sequence/validation/validation_issue.dart';
import '../settings_provider.dart';
// "Who owns the rig" — unattended autopilot vs a hand-started run.
import 'rules/autopilot_rules.dart';
import 'rules/defect_map_rules.dart';
import 'rules/disk_space_rules.dart';
import 'rules/equipment_rules.dart';
import 'rules/filter_rules.dart';
import 'rules/plate_solver_rules.dart';
import 'rules/plugin_node_rules.dart';
// Pre-flight checks (darks + equipment health + optical train).
import 'rules/preflight_rules.dart';
import 'rules/settings_rules.dart';
// Daylight gate / observing site / mount-pointing pre-flight rules.
import 'rules/sky_readiness_rules.dart';
import 'rules/live_stacking_rules.dart';
import 'rules/smart_exposure_rules.dart';
import 'rules/weather_safety_rules.dart';

// Sequence validation.
//
//   * Structural rules read only the sequence. They live under
//     `models/sequence/validation/` with the issue vocabulary, listed in
//     [defaultSequenceValidators].
//   * Ref-aware rules (equipment connection, filter wheel content, app
//     settings, disk space) live under `rules/` here and take a
//     [ValidationContext].
//
// Live in-tree validation (the per-node coloured border + counts in the tree
// header) and the pre-flight dialog both call [SequenceValidatorService] here.
// Add a new rule to [defaultSequenceValidators] when it reads only the
// sequence, else to [defaultRefAwareSequenceValidators]. Don't fork the engine.

/// Context passed to ref-aware validators. Carries the Riverpod `Ref` so
/// rules can `read` equipment state / settings without dragging Riverpod
/// types into the rule constructors.
class ValidationContext {
  final Ref ref;
  const ValidationContext(this.ref);
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
