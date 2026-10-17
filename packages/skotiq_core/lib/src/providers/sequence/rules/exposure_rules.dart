import '../../../models/sequence/sequence_models.dart';
import '../sequence_validation.dart';

/// Validates duration and count on every ExposureNode (enabled or not).
///
/// Disabled nodes still get validated for correctness — toggling them on
/// later should not surprise the user.
class ExposureParamsRule implements SequenceValidator {
  @override
  String get name => 'ExposureParams';

  @override
  List<ValidationIssue> validate(Sequence sequence) {
    final issues = <ValidationIssue>[];
    for (final node in sequence.nodes.values) {
      if (node is! ExposureNode) continue;
      if (node.durationSecs <= 0) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            category: ValidationCategory.exposures,
            title: 'Invalid Exposure Time',
            description:
                'Exposure "${node.name}" has invalid duration: ${node.durationSecs}s',
            affectedNodeId: node.id,
            resolutionHint: 'Set a positive exposure duration.',
          ),
        );
      } else if (node.durationSecs > 1800) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.warning,
            category: ValidationCategory.exposures,
            title: 'Very Long Exposure',
            description:
                'Exposure "${node.name}" is ${(node.durationSecs / 60).toStringAsFixed(0)} minutes. '
                'Very long exposures may fail due to tracking errors.',
            affectedNodeId: node.id,
            resolutionHint:
                'Consider breaking into shorter exposures or using auto-guiding.',
          ),
        );
      }
      if (node.count <= 0) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            category: ValidationCategory.exposures,
            title: 'Invalid Frame Count',
            description: 'Exposure "${node.name}" has count of ${node.count}.',
            affectedNodeId: node.id,
            resolutionHint: 'Set at least 1 frame to capture.',
          ),
        );
      }
      // Negative gain/offset is physically invalid — no sensor accepts a
      // negative analogue gain or bias offset, and the driver would reject
      // it at runtime. Catch it at edit time as an error.
      final gain = node.gain;
      if (gain != null && gain < 0) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            category: ValidationCategory.exposures,
            title: 'Invalid Gain',
            description:
                'Exposure "${node.name}" has a negative gain ($gain). Gain '
                'cannot be negative.',
            affectedNodeId: node.id,
            resolutionHint: 'Set a gain of 0 or higher.',
          ),
        );
      } else if (gain != null && gain == 0) {
        // Gain 0 is legal on many cameras (unity / minimum), but it is also
        // the value you get from a blank field, so flag it as info so the
        // user can confirm it was intentional.
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.info,
            category: ValidationCategory.exposures,
            title: 'Gain Is Zero',
            description:
                'Exposure "${node.name}" uses a gain of 0. Confirm this is '
                'your camera\'s intended minimum gain and not a blank field.',
            affectedNodeId: node.id,
          ),
        );
      }
      final offset = node.offset;
      if (offset != null && offset < 0) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            category: ValidationCategory.exposures,
            title: 'Invalid Offset',
            description:
                'Exposure "${node.name}" has a negative offset ($offset). '
                'Offset cannot be negative.',
            affectedNodeId: node.id,
            resolutionHint: 'Set an offset of 0 or higher.',
          ),
        );
      }
    }
    return issues;
  }
}

/// Info-only note for high binning (3x3, 4x4). Loses resolution; users
/// usually didn't mean to set this.
class HighBinningRule implements SequenceValidator {
  @override
  String get name => 'HighBinning';

  @override
  List<ValidationIssue> validate(Sequence sequence) {
    final issues = <ValidationIssue>[];
    for (final node in sequence.nodes.values) {
      if (node is! ExposureNode) continue;
      if (!node.isEnabled) continue;
      if (node.binning != BinningMode.three &&
          node.binning != BinningMode.four) {
        continue;
      }
      issues.add(
        ValidationIssue(
          severity: ValidationSeverity.info,
          category: ValidationCategory.exposures,
          title: 'High Binning',
          description:
              'Exposure "${node.name}" uses ${node.binning.label} binning which reduces resolution.',
          affectedNodeId: node.id,
        ),
      );
    }
    return issues;
  }
}

/// Warns when the sequence has no enabled exposures. The sequence will run
/// but capture no images.
class NoExposuresRule implements SequenceValidator {
  @override
  String get name => 'NoExposures';

  @override
  List<ValidationIssue> validate(Sequence sequence) {
    // Count standalone ExposureNodes, SmartExposure nodes (whose captures live
    // in per-filter plans) and SciencePhotometry bursts (which capture through
    // the same TakeExposure pipeline) so neither an auto-built sequence nor a
    // photometry-only one is falsely flagged as capturing no images.
    final hasEnabledExposure = sequence.nodes.values.any(
      (n) =>
          (n is ExposureNode && n.isEnabled) ||
          (n is SmartExposureNode && n.isEnabled && n.plans.isNotEmpty) ||
          (n is SciencePhotometryNode && n.isEnabled && n.count > 0),
    );
    if (hasEnabledExposure) return const [];

    // Don't fire if the sequence is itself empty — EmptySequenceRule covers
    // that.
    if (sequence.nodes.isEmpty) return const [];

    return const [
      ValidationIssue(
        severity: ValidationSeverity.warning,
        category: ValidationCategory.exposures,
        title: 'No Exposures',
        description:
            'No exposure nodes found. The sequence will run but capture no images.',
        resolutionHint: 'Add Exposure nodes to capture images.',
      ),
    ];
  }
}

/// Warns when the projected total integration time exceeds 8 hours. The
/// user can split the run across nights for safety.
class LongTotalIntegrationRule implements SequenceValidator {
  @override
  String get name => 'LongTotalIntegration';

  @override
  List<ValidationIssue> validate(Sequence sequence) {
    final totalSecs = sequence.totalIntegrationSecs;
    if (totalSecs <= 28800) return const [];

    return [
      ValidationIssue(
        severity: ValidationSeverity.warning,
        category: ValidationCategory.timing,
        title: 'Very Long Sequence',
        description:
            'Total integration time is ${(totalSecs / 3600).toStringAsFixed(1)} hours. '
            'Consider splitting across multiple nights.',
      ),
    ];
  }
}
