import '../../../models/sequence/sequence_models.dart';
import '../../../services/disk_space_guard.dart';
import '../../disk_space_provider.dart';
import '../sequence_validation.dart';

/// Queries free space on the capture directory and compares against the
/// projected sequence size (frame count × frame size derived from camera
/// capabilities). Surfaces info/warning/blocking per the disk-space guard
/// spec.
///
/// Failure to query (path missing, OS utility failure) is itself surfaced
/// as a warning rather than silently ignored — the user needs to know the
/// monitoring is degraded before starting a multi-hour run.
class DiskSpaceProjectionRule implements AsyncSequenceValidator {
  @override
  String get name => 'DiskSpaceProjection';

  @override
  Future<List<ValidationIssue>> validate(
    Sequence sequence,
    ValidationContext ctx,
  ) async {
    try {
      final projection = await projectCurrentSequence(ctx.ref);
      if (projection == null) {
        // No capture path or no sequence — ImageOutputPathRule already
        // emitted a warning if relevant.
        return const [];
      }
      final severity = switch (projection.severity) {
        DiskSpaceSeverity.info => ValidationSeverity.info,
        DiskSpaceSeverity.warning => ValidationSeverity.warning,
        DiskSpaceSeverity.blocking => ValidationSeverity.error,
      };
      final title = switch (projection.severity) {
        DiskSpaceSeverity.info => 'Disk space',
        DiskSpaceSeverity.warning => 'Low disk space',
        DiskSpaceSeverity.blocking => 'Not enough disk space',
      };
      return [
        ValidationIssue(
          severity: severity,
          category: ValidationCategory.diskSpace,
          title: title,
          description: projection.headline,
          resolutionHint: projection.detail,
        ),
      ];
    } catch (e) {
      return [
        ValidationIssue(
          severity: ValidationSeverity.warning,
          category: ValidationCategory.diskSpace,
          title: 'Disk-space check failed',
          description:
              'Could not query free space on the capture directory: $e',
          resolutionHint:
              'Verify the capture directory in Settings → File Output is valid and accessible.',
        ),
      ];
    }
  }
}
