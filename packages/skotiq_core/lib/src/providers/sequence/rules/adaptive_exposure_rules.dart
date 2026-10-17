import '../../../models/sequence/sequence_models.dart';
import '../sequence_validation.dart';

/// Sky-brightness adaptive exposure validation rules.
///
/// All three rules below operate on the per-node
/// [ExposureNode.adaptiveExposure] override. The global default from
/// app settings is validated by the settings page UI itself (numeric
/// fields + slider widgets enforce bounds at edit time); these rules
/// catch the persisted-but-illegal-state cases that survive a
/// round-trip through the database / sequence-file JSON.

/// `min_exposure_secs` MUST be <= `max_exposure_secs`. Hard error
/// because the clamp logic at runtime degenerates to "always max"
/// when min > max, which is almost certainly not what the user wanted.
class AdaptiveExposureBoundsRule implements SequenceValidator {
  @override
  String get name => 'AdaptiveExposureBounds';

  @override
  List<ValidationIssue> validate(Sequence sequence) {
    final issues = <ValidationIssue>[];
    for (final node in sequence.nodes.values) {
      if (node is! ExposureNode) continue;
      final cfg = node.adaptiveExposure;
      if (cfg == null) continue;

      if (cfg.minExposureSecs <= 0) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            category: ValidationCategory.exposures,
            title: 'Adaptive exposure min must be > 0',
            description:
                'Exposure "${node.name}" has min_exposure_secs = ${cfg.minExposureSecs.toStringAsFixed(1)}s. '
                'The minimum clamp must be positive.',
            affectedNodeId: node.id,
            resolutionHint:
                'Set the global minimum to a positive value (e.g. 5s).',
          ),
        );
      }
      if (cfg.maxExposureSecs <= 0) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            category: ValidationCategory.exposures,
            title: 'Adaptive exposure max must be > 0',
            description:
                'Exposure "${node.name}" has max_exposure_secs = ${cfg.maxExposureSecs.toStringAsFixed(1)}s. '
                'The maximum clamp must be positive.',
            affectedNodeId: node.id,
            resolutionHint:
                'Set the global maximum to a positive value (e.g. 600s).',
          ),
        );
      }
      if (cfg.minExposureSecs > cfg.maxExposureSecs) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            category: ValidationCategory.exposures,
            title: 'Adaptive exposure bounds inverted',
            description:
                'Exposure "${node.name}" has min_exposure_secs (${cfg.minExposureSecs.toStringAsFixed(1)}s) '
                '> max_exposure_secs (${cfg.maxExposureSecs.toStringAsFixed(1)}s). '
                'The clamp logic will pin every frame to the max value, defeating adaptation.',
            affectedNodeId: node.id,
            resolutionHint:
                'Either lower the minimum or raise the maximum so min ≤ max.',
          ),
        );
      }

      // Each per-filter override pair must also satisfy min <= max.
      for (final entry in cfg.perFilterMinSecs.entries) {
        final filter = entry.key;
        final min = entry.value;
        final max = cfg.perFilterMaxSecs[filter] ?? cfg.maxExposureSecs;
        if (min <= 0) {
          issues.add(
            ValidationIssue(
              severity: ValidationSeverity.error,
              category: ValidationCategory.exposures,
              title: 'Adaptive exposure per-filter min must be > 0',
              description:
                  'Exposure "${node.name}" filter "$filter" has min_exposure_secs = ${min.toStringAsFixed(1)}s.',
              affectedNodeId: node.id,
              resolutionHint:
                  'Set a positive per-filter minimum (or remove the override).',
            ),
          );
        }
        if (min > max) {
          issues.add(
            ValidationIssue(
              severity: ValidationSeverity.error,
              category: ValidationCategory.exposures,
              title: 'Adaptive exposure per-filter bounds inverted',
              description:
                  'Exposure "${node.name}" filter "$filter" has '
                  'per-filter min ${min.toStringAsFixed(1)}s > '
                  'effective max ${max.toStringAsFixed(1)}s.',
              affectedNodeId: node.id,
              resolutionHint:
                  'Either lower the per-filter min or raise the per-filter / global max.',
            ),
          );
        }
      }
    }
    return issues;
  }
}

/// When `adaptive_exposure` is configured but no filter is enabled
/// (per-filter map populated with every entry = false, and the global
/// enable is on), the adapter will see "enabled but no filter to apply
/// to" and silently do nothing. Surface as a warning so the user can
/// either enable a filter or remove the per-node override.
class AdaptiveExposureNoFilterEnabledRule implements SequenceValidator {
  @override
  String get name => 'AdaptiveExposureNoFilterEnabled';

  @override
  List<ValidationIssue> validate(Sequence sequence) {
    final issues = <ValidationIssue>[];
    for (final node in sequence.nodes.values) {
      if (node is! ExposureNode) continue;
      final cfg = node.adaptiveExposure;
      if (cfg == null) continue;
      if (!cfg.enabled) continue;
      if (cfg.perFilterEnabled.isEmpty) continue; // implicit-global is fine
      final anyEnabled = cfg.perFilterEnabled.values.any((v) => v);
      if (anyEnabled) continue;
      issues.add(
        ValidationIssue(
          severity: ValidationSeverity.warning,
          category: ValidationCategory.exposures,
          title: 'Adaptive exposure has no enabled filters',
          description:
              'Exposure "${node.name}" has adaptive exposure ON globally but every per-filter override '
              'is disabled. No filter will actually be adapted.',
          affectedNodeId: node.id,
          resolutionHint:
              'Enable adaptive exposure for at least one filter, or remove the per-node config.',
        ),
      );
    }
    return issues;
  }
}

/// When the configured nominal duration is way out of the adapter's
/// [min, max] bounds, the runtime adapter will emit
/// `OutOfNominalBounds` and clamp into bounds. Surface as a warning
/// at validation time so the user fixes the config before pressing
/// Start (rather than only learning about it from a dashboard event
/// 60 s into the run).
class AdaptiveExposureNominalOutOfBoundsRule implements SequenceValidator {
  @override
  String get name => 'AdaptiveExposureNominalOutOfBounds';

  @override
  List<ValidationIssue> validate(Sequence sequence) {
    final issues = <ValidationIssue>[];
    for (final node in sequence.nodes.values) {
      if (node is! ExposureNode) continue;
      final cfg = node.adaptiveExposure;
      if (cfg == null) continue;
      if (!cfg.enabled) continue;

      final min = cfg.minForFilter(node.filter);
      final max = cfg.maxForFilter(node.filter);
      if (min > max) continue; // covered by AdaptiveExposureBoundsRule
      final nominal = node.durationSecs;
      if (nominal < min) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.warning,
            category: ValidationCategory.exposures,
            title: 'Nominal exposure below adaptive min',
            description:
                'Exposure "${node.name}" has nominal duration ${nominal.toStringAsFixed(1)}s '
                'but the adaptive minimum (for filter "${node.filter ?? "(none)"}") is ${min.toStringAsFixed(1)}s. '
                'Every frame will be clamped to the minimum.',
            affectedNodeId: node.id,
            resolutionHint:
                'Raise the nominal duration to at least the adaptive minimum, '
                'or lower the minimum clamp.',
          ),
        );
      } else if (nominal > max) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.warning,
            category: ValidationCategory.exposures,
            title: 'Nominal exposure above adaptive max',
            description:
                'Exposure "${node.name}" has nominal duration ${nominal.toStringAsFixed(1)}s '
                'but the adaptive maximum (for filter "${node.filter ?? "(none)"}") is ${max.toStringAsFixed(1)}s. '
                'Every frame will be clamped to the maximum.',
            affectedNodeId: node.id,
            resolutionHint:
                'Lower the nominal duration to at most the adaptive maximum, '
                'or raise the maximum clamp.',
          ),
        );
      }
    }
    return issues;
  }
}
