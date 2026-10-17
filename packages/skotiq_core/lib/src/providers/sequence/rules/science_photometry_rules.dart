import '../../../models/sequence/sequence_models.dart';
import '../sequence_validation.dart';

/// Science: SciencePhotometry validation rules.
///
/// These rules cover the three failure modes the brief calls out:
///   * non-photometric filter (warning) — frames captured through Ha /
///     OIII / Lum are still useful for some workflows but the INSTRMAG
///     / DIFFMAG keywords are no longer comparable to AAVSO catalogues.
///   * `apply_differential = true` with no reference stars (error) —
///     differential magnitudes cannot be computed without references.
///   * `max_cadence_gap_secs < exposure_secs` (error) — physically
///     impossible cadence; the runtime refuses to start the burst.
///
/// A photometry node also surfaces the `binning != 1x1` warning since
/// photometry typically wants 1x1 to preserve PSF sampling for the
/// centroid extraction.

/// Filter not photometric — warning. The user may still want to run a
/// photometry burst through Ha / OIII / Lum for a non-AAVSO workflow,
/// but the FITS INSTRMAG / DIFFMAG keywords lose their canonical
/// meaning.
class SciencePhotometryFilterRule implements SequenceValidator {
  @override
  String get name => 'SciencePhotometryFilter';

  @override
  List<ValidationIssue> validate(Sequence sequence) {
    final issues = <ValidationIssue>[];
    for (final node in sequence.nodes.values) {
      if (node is! SciencePhotometryNode) continue;
      if (!node.isEnabled) continue;
      if (!node.isPhotometricFilter) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.warning,
            category: ValidationCategory.exposures,
            title: 'Photometry filter is non-photometric',
            description:
                'Science Photometry "${node.name}" is configured with filter '
                '"${node.filter}", which is not one of the standard '
                'photometric bands (V, B, R, I, g, r, i, z, Clear, CV). The '
                'INSTRMAG / DIFFMAG keywords stamped on the frames will not '
                'be comparable to AAVSO / Gaia catalogues.',
            affectedNodeId: node.id,
            resolutionHint:
                'Switch to V / B / R / I / Sloan g / r / i / z or Clear if '
                'the goal is canonical photometric reduction.',
          ),
        );
      }
      if (node.binning != BinningMode.one) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.warning,
            category: ValidationCategory.exposures,
            title: 'Photometry binning > 1x1',
            description:
                'Science Photometry "${node.name}" is configured with '
                '${node.binning.name}x binning. Photometric centroid '
                'extraction prefers 1x1 to preserve PSF sampling — '
                'binning > 1 elevates the per-frame uncertainty.',
            affectedNodeId: node.id,
            resolutionHint: 'Set binning to 1x1 for best photometric SNR.',
          ),
        );
      }
    }
    return issues;
  }
}

/// `apply_differential = true` with empty reference stars is an
/// unrecoverable configuration error: differential magnitudes cannot
/// be computed without references. The Rust runtime refuses to start
/// the burst, so we surface this at sequence-edit time.
class SciencePhotometryReferenceStarsEmptyRule implements SequenceValidator {
  @override
  String get name => 'SciencePhotometryReferenceStarsEmpty';

  @override
  List<ValidationIssue> validate(Sequence sequence) {
    final issues = <ValidationIssue>[];
    for (final node in sequence.nodes.values) {
      if (node is! SciencePhotometryNode) continue;
      if (!node.isEnabled) continue;
      if (node.applyDifferential && node.referenceStars.isEmpty) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            category: ValidationCategory.exposures,
            title: 'Differential photometry needs reference stars',
            description:
                'Science Photometry "${node.name}" has '
                'apply_differential=true but no reference stars are '
                'configured. The runtime cannot compute DIFFMAG without '
                'at least one comparison star.',
            affectedNodeId: node.id,
            resolutionHint:
                'Add at least one reference star catalogue ID, or turn '
                'off "apply differential" if instrumental magnitudes alone '
                'are sufficient.',
          ),
        );
      }
      if (node.targetDesignation.trim().isEmpty) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            category: ValidationCategory.exposures,
            title: 'Photometry target designation is empty',
            description:
                'Science Photometry "${node.name}" has no target '
                'designation. The runtime cannot stamp the OBJCAT FITS '
                'keyword or write the photometry_measurements row.',
            affectedNodeId: node.id,
            resolutionHint:
                'Enter a catalogue ID (e.g. "V0376 Per", "KIC-9832227").',
          ),
        );
      }
      if (node.count <= 0) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.warning,
            category: ValidationCategory.exposures,
            title: 'Photometry has zero frames',
            description:
                'Science Photometry "${node.name}" has count <= 0. The '
                'runtime will succeed immediately without capturing any '
                'frames.',
            affectedNodeId: node.id,
            resolutionHint: 'Set a positive count.',
          ),
        );
      }
    }
    return issues;
  }
}

/// `max_cadence_gap_secs < exposure_secs` is physically impossible —
/// the inter-frame gap cannot be shorter than the exposure itself.
/// The Rust runtime refuses to start the burst.
class SciencePhotometryCadenceRule implements SequenceValidator {
  @override
  String get name => 'SciencePhotometryCadence';

  @override
  List<ValidationIssue> validate(Sequence sequence) {
    final issues = <ValidationIssue>[];
    for (final node in sequence.nodes.values) {
      if (node is! SciencePhotometryNode) continue;
      if (!node.isEnabled) continue;
      if (node.hasImpossibleCadence) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            category: ValidationCategory.exposures,
            title: 'Photometry cadence is physically impossible',
            description:
                'Science Photometry "${node.name}" has '
                'max_cadence_gap_secs (${node.maxCadenceGapSecs.toStringAsFixed(1)}s) < '
                'exposure_secs (${node.exposureSecs.toStringAsFixed(1)}s). '
                'The inter-frame start-to-start gap cannot be shorter '
                'than the exposure itself. The runtime will refuse to '
                'start this burst.',
            affectedNodeId: node.id,
            resolutionHint:
                'Either raise the cadence gap above the exposure '
                'duration, or shorten the exposure.',
          ),
        );
      }
      if (node.exposureSecs <= 0.0) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            category: ValidationCategory.exposures,
            title: 'Photometry has invalid exposure duration',
            description:
                'Science Photometry "${node.name}" has '
                'exposure_secs=${node.exposureSecs}. Must be positive.',
            affectedNodeId: node.id,
            resolutionHint: 'Set a positive exposure duration in seconds.',
          ),
        );
      }
    }
    return issues;
  }
}
