import '../../../models/sequence/sequence_models.dart';
import '../sequence_validation.dart';

/// Validates RA / Dec on TargetHeaderNode and the equivalent custom-coord
/// path on SlewNode. RA must be in [0, 24); Dec must be in [-90, +90].
class TargetCoordinatesRule implements SequenceValidator {
  @override
  String get name => 'TargetCoordinates';

  @override
  List<ValidationIssue> validate(Sequence sequence) {
    final issues = <ValidationIssue>[];
    for (final node in sequence.nodes.values) {
      if (node is! TargetHeaderNode) continue;
      if (node.raHours < 0 || node.raHours >= 24) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            category: ValidationCategory.targets,
            title: 'Invalid RA',
            description:
                'Target "${node.targetName}" has invalid RA: ${node.raHours}h',
            affectedNodeId: node.id,
            resolutionHint: 'RA must be between 0 and 24 hours.',
          ),
        );
      }
      if (node.decDegrees < -90 || node.decDegrees > 90) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            category: ValidationCategory.targets,
            title: 'Invalid Dec',
            description:
                'Target "${node.targetName}" has invalid Dec: ${node.decDegrees}°',
            affectedNodeId: node.id,
            resolutionHint: 'Declination must be between -90 and +90 degrees.',
          ),
        );
      }
    }
    return issues;
  }
}

/// Validates custom RA/Dec on `SlewNode`s that don't use target coords.
class SlewCoordinatesRule implements SequenceValidator {
  @override
  String get name => 'SlewCoordinates';

  @override
  List<ValidationIssue> validate(Sequence sequence) {
    final issues = <ValidationIssue>[];
    for (final node in sequence.nodes.values) {
      if (node is! SlewNode) continue;
      if (node.useTargetCoords) continue;

      final ra = node.customRa;
      final dec = node.customDec;
      if (ra != null && (ra < 0 || ra >= 24)) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            category: ValidationCategory.targets,
            title: 'Invalid Slew RA',
            description: 'Slew "${node.name}" has invalid RA: ${ra}h',
            affectedNodeId: node.id,
            resolutionHint: 'RA must be between 0 and 24 hours.',
          ),
        );
      }
      if (dec != null && (dec < -90 || dec > 90)) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            category: ValidationCategory.targets,
            title: 'Invalid Slew Dec',
            description: 'Slew "${node.name}" has invalid Dec: $dec°',
            affectedNodeId: node.id,
            resolutionHint: 'Declination must be between -90 and +90 degrees.',
          ),
        );
      }
    }
    return issues;
  }
}

/// Warns when a target has no instructions. Note: distinct from the generic
/// EmptyContainerRule because targets get a friendlier label.
class EmptyTargetRule implements SequenceValidator {
  @override
  String get name => 'EmptyTarget';

  @override
  List<ValidationIssue> validate(Sequence sequence) {
    final issues = <ValidationIssue>[];
    for (final target in sequence.targetHeaders) {
      if (target.childIds.isNotEmpty) continue;
      issues.add(
        ValidationIssue(
          severity: ValidationSeverity.warning,
          category: ValidationCategory.targets,
          title: 'Empty Target',
          description: 'Target "${target.targetName}" has no instructions.',
          affectedNodeId: target.id,
          resolutionHint:
              'Add exposure or other instruction nodes to the target.',
        ),
      );
    }
    return issues;
  }
}

/// Warns when a target's minimum altitude is unusually low (<10°). Imaging
/// that close to the horizon almost always yields bad data.
class LowAltitudeLimitRule implements SequenceValidator {
  @override
  String get name => 'LowAltitudeLimit';

  @override
  List<ValidationIssue> validate(Sequence sequence) {
    final issues = <ValidationIssue>[];
    for (final target in sequence.targetHeaders) {
      final minAlt = target.minAltitude;
      if (minAlt == null) continue;
      if (minAlt >= 10) continue;
      issues.add(
        ValidationIssue(
          severity: ValidationSeverity.warning,
          category: ValidationCategory.targets,
          title: 'Very Low Altitude Limit',
          description:
              'Target "${target.targetName}" minimum altitude is $minAlt°. '
              'Imaging near the horizon may result in poor quality.',
          affectedNodeId: target.id,
          resolutionHint: 'Consider setting minimum altitude to 20° or higher.',
        ),
      );
    }
    return issues;
  }
}

/// Error when an integration budget is configured
/// without any populated total or per-filter caps. The runtime would
/// silently no-op (every cap is zero), so the user would see "budget
/// configured" in the UI but no enforcement at run-time — a confusing
/// silent-fallback.
class IntegrationBudgetEmptyRule implements SequenceValidator {
  @override
  String get name => 'IntegrationBudgetEmpty';

  @override
  List<ValidationIssue> validate(Sequence sequence) {
    final issues = <ValidationIssue>[];
    for (final target in sequence.targetHeaders) {
      final budget = target.integrationBudget;
      if (budget == null) continue;
      if (budget.isActive) continue;
      issues.add(
        ValidationIssue(
          severity: ValidationSeverity.error,
          category: ValidationCategory.targets,
          title: 'Empty Integration Budget',
          description:
              'Target "${target.targetName}" has an integration budget '
              'enabled but no total time or per-filter caps configured.',
          affectedNodeId: target.id,
          resolutionHint:
              'Set a non-zero total time or add at least one per-filter entry, '
              'or turn the integration budget off.',
        ),
      );
    }
    return issues;
  }
}

/// Error when every per-filter ratio is zero AND no
/// absolute cap exists. The runtime cannot normalise zero-sum ratios,
/// so the budget would never fire — better to fail loudly at validation
/// time.
class IntegrationBudgetRatioZeroSumRule implements SequenceValidator {
  @override
  String get name => 'IntegrationBudgetRatioZeroSum';

  @override
  List<ValidationIssue> validate(Sequence sequence) {
    final issues = <ValidationIssue>[];
    for (final target in sequence.targetHeaders) {
      final budget = target.integrationBudget;
      if (budget == null || !budget.isActive) continue;
      final hasAbsolute = budget.perFilter.values.any(
        (e) => e.isAbsolute && e.value > 0,
      );
      if (hasAbsolute) continue;
      final hasRatio = budget.perFilter.values.any((e) => e.isRatio);
      if (!hasRatio) continue;
      final ratioSum = budget.perFilter.values
          .where((e) => e.isRatio)
          .fold<double>(0, (acc, e) => acc + e.value);
      if (ratioSum <= 0) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            category: ValidationCategory.targets,
            title: 'Integration Budget Ratios Sum To Zero',
            description:
                'Target "${target.targetName}" has only ratio entries and '
                'their sum is zero — the budget can never fire.',
            affectedNodeId: target.id,
            resolutionHint:
                'Set at least one ratio entry to a positive value or use absolute caps.',
          ),
        );
      }
    }
    return issues;
  }
}

/// Error when a budget has ratio entries but no
/// total_secs to normalise against. Ratios without a total are
/// meaningless ("4 parts of nothing" = 0) and the runtime fails
/// closed; surface the misconfiguration at edit time.
class IntegrationBudgetRatioWithoutTotalRule implements SequenceValidator {
  @override
  String get name => 'IntegrationBudgetRatioWithoutTotal';

  @override
  List<ValidationIssue> validate(Sequence sequence) {
    final issues = <ValidationIssue>[];
    for (final target in sequence.targetHeaders) {
      final budget = target.integrationBudget;
      if (budget == null || !budget.isActive) continue;
      if (budget.totalSecs > 0.0) continue;
      final hasRatio = budget.perFilter.values.any(
        (e) => e.isRatio && e.value > 0,
      );
      if (hasRatio) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            category: ValidationCategory.targets,
            title: 'Ratio Without Total',
            description:
                'Target "${target.targetName}" has ratio-based filter budgets '
                'but no total integration time to distribute them across.',
            affectedNodeId: target.id,
            resolutionHint:
                'Set a total integration time, or convert ratio entries to absolute seconds.',
          ),
        );
      }
    }
    return issues;
  }
}

/// Error when a `startWhen` / `endWhen` `And` / `Or` compound
/// has no children. The runtime treats an empty compound as `false` to
/// fail closed, which means a "wait forever" target — surface the
/// misconfiguration at edit time so the user can fix it before running.
class TargetTriggerEmptyCompoundRule implements SequenceValidator {
  @override
  String get name => 'TargetTriggerEmptyCompound';

  @override
  List<ValidationIssue> validate(Sequence sequence) {
    final issues = <ValidationIssue>[];
    for (final target in sequence.targetHeaders) {
      for (final entry in <(String, TargetTrigger?)>[
        ('start', target.startWhen),
        ('end', target.endWhen),
      ]) {
        final trig = entry.$2;
        if (trig == null) continue;
        if (!trig.hasEmptyCompound) continue;
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            category: ValidationCategory.targets,
            title: 'Empty Compound Trigger',
            description:
                'Target "${target.targetName}" has an empty And/Or in its '
                '${entry.$1}_when condition.',
            affectedNodeId: target.id,
            resolutionHint:
                'Add at least one sub-trigger, or remove the compound.',
          ),
        );
      }
    }
    return issues;
  }
}

/// Error when a target's `startWhen` requires the target to
/// reach an altitude it can never reach from the user's location.
/// Formula: at latitude φ, a target with declination δ culminates at
/// `90° - |φ - δ|`. We flag any `AltitudeAbove(N)` term where
/// `culmination < N`.
class TargetTriggerImpossibleAltitudeRule implements SequenceValidator {
  /// Observer latitude. Older validation rules don't get an observer
  /// context wired in, so we accept it via constructor; the registry
  /// passes the active profile latitude when wiring this rule up.
  /// `null` means "skip this rule" (no opinion without an observer).
  final double? observerLatitudeDeg;

  const TargetTriggerImpossibleAltitudeRule({this.observerLatitudeDeg});

  @override
  String get name => 'TargetTriggerImpossibleAltitude';

  @override
  List<ValidationIssue> validate(Sequence sequence) {
    final lat = observerLatitudeDeg;
    if (lat == null) return const [];
    final issues = <ValidationIssue>[];
    for (final target in sequence.targetHeaders) {
      final culmination =
          90.0 - ((lat - target.decDegrees).abs()).clamp(0.0, 180.0);
      for (final entry in <(String, TargetTrigger?)>[
        ('start', target.startWhen),
        ('end', target.endWhen),
      ]) {
        final trig = entry.$2;
        if (trig == null) continue;
        final thresholds = <double>[];
        _collectAltitudeAbove(trig, thresholds);
        for (final t in thresholds) {
          if (t > culmination) {
            issues.add(
              ValidationIssue(
                severity: ValidationSeverity.error,
                category: ValidationCategory.targets,
                title: 'Unreachable Altitude',
                description:
                    'Target "${target.targetName}" requires altitude '
                    '≥ ${t.toStringAsFixed(1)}° in its ${entry.$1}_when '
                    'but culminates at ${culmination.toStringAsFixed(1)}° '
                    'from your latitude (${lat.toStringAsFixed(1)}°).',
                affectedNodeId: target.id,
                resolutionHint:
                    'Lower the altitude threshold or pick a target with '
                    'higher declination.',
              ),
            );
          }
        }
      }
    }
    return issues;
  }

  static void _collectAltitudeAbove(TargetTrigger t, List<double> out) {
    switch (t) {
      case AltitudeAboveTrigger(altitudeDeg: final v):
        out.add(v);
      case AndTrigger(children: final cs):
        for (final c in cs) {
          _collectAltitudeAbove(c, out);
        }
      case OrTrigger(children: final cs):
        for (final c in cs) {
          _collectAltitudeAbove(c, out);
        }
      default:
        return;
    }
  }
}

/// Error when `startWhen` and `endWhen` are structurally
/// guaranteed to contradict each other. `endWhen` is a stop trigger: if it is
/// already satisfied when the target starts, the runtime skips the target.
/// The common trap is `startWhen = TimeAfter(t1)` with
/// `endWhen = TimeBefore(t0)` where `t0 > t1`; once the start wait completes,
/// the end trigger is immediately true.
class TargetTriggerStartEndContradictionRule implements SequenceValidator {
  const TargetTriggerStartEndContradictionRule();

  @override
  String get name => 'TargetTriggerStartEndContradiction';

  @override
  List<ValidationIssue> validate(Sequence sequence) {
    final issues = <ValidationIssue>[];
    for (final target in sequence.targetHeaders) {
      final startAfter = _guaranteedStartTimeAfter(target.startWhen);
      final endBefore = _endTimeBefore(target.endWhen);
      if (startAfter == null || endBefore == null) continue;
      if (endBefore <= startAfter) continue;
      issues.add(
        ValidationIssue(
          severity: ValidationSeverity.error,
          category: ValidationCategory.targets,
          title: 'End Trigger Already Satisfied',
          description:
              'Target "${target.targetName}" waits until its startWhen '
              '(TimeAfter), then immediately satisfies endWhen (TimeBefore). '
              'The target will be skipped as soon as it starts.',
          affectedNodeId: target.id,
          resolutionHint:
              'Use endWhen TimeAfter for a stop-at-time cap, move the '
              'TimeBefore cutoff before the start time, or remove one trigger.',
        ),
      );
    }
    return issues;
  }

  static int? _guaranteedStartTimeAfter(TargetTrigger? trigger) {
    if (trigger == null) return null;
    switch (trigger) {
      case TimeAfterTrigger(unixSeconds: final seconds):
        return seconds;
      case AndTrigger(children: final children):
        int? latest;
        for (final child in children) {
          final childTime = _guaranteedStartTimeAfter(child);
          if (childTime == null) continue;
          latest = latest == null
              ? childTime
              : (childTime > latest ? childTime : latest);
        }
        return latest;
      case OrTrigger(children: final children):
        if (children.isEmpty) return null;
        int? earliest;
        for (final child in children) {
          final childTime = _guaranteedStartTimeAfter(child);
          if (childTime == null) return null;
          earliest = earliest == null
              ? childTime
              : (childTime < earliest ? childTime : earliest);
        }
        return earliest;
      default:
        return null;
    }
  }

  static int? _endTimeBefore(TargetTrigger? trigger) {
    if (trigger == null) return null;
    switch (trigger) {
      case TimeBeforeTrigger(unixSeconds: final seconds):
        return seconds;
      case OrTrigger(children: final children):
        int? latest;
        for (final child in children) {
          final childTime = _endTimeBefore(child);
          if (childTime == null) continue;
          latest = latest == null
              ? childTime
              : (childTime > latest ? childTime : latest);
        }
        return latest;
      default:
        return null;
    }
  }
}

/// Warns when there are enabled exposures but no target defined.
class NoTargetForExposuresRule implements SequenceValidator {
  @override
  String get name => 'NoTargetForExposures';

  @override
  List<ValidationIssue> validate(Sequence sequence) {
    final targets = sequence.targetHeaders;
    if (targets.isNotEmpty) return const [];

    final hasEnabledExposures = sequence.nodes.values
        .whereType<ExposureNode>()
        .any((n) => n.isEnabled);
    if (!hasEnabledExposures) return const [];

    return const [
      ValidationIssue(
        severity: ValidationSeverity.warning,
        category: ValidationCategory.targets,
        title: 'No Targets Defined',
        description:
            'Exposures exist but no target is defined. The mount will image at its current position.',
        resolutionHint: 'Add a Target Group node with coordinates.',
      ),
    ];
  }
}
