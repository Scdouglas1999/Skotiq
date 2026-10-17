import 'dart:io';

import '../../../models/sequence/sequence_models.dart';
import '../../settings_provider.dart';
import '../sequence_validation.dart';

/// REJECTS sequence start when no usable image output directory
/// is configured.
///
/// Pre- this rule only emitted a warning, which the executor would
/// happily ignore (only `error` severity blocks). On a fresh Pi install
/// where `imageOutputPath` defaults to empty, the Rust sequencer would
/// then either fail to write or write to the working directory with no
/// operator-visible signal. We now fail-closed with `error` severity so
/// the executor's pre-flight gate blocks the start.
///
/// Three failure modes, each with a distinct error code so the REST
/// surface can render distinct messages:
///   * `image_output_path_not_configured` — empty / whitespace-only.
///   * `image_output_path_missing` — directory does not exist.
///   * `image_output_path_not_writable` — exists but probe-write fails.
class ImageOutputPathRule implements RefAwareSequenceValidator {
  @override
  String get name => 'ImageOutputPath';

  @override
  List<ValidationIssue> validate(Sequence sequence, ValidationContext ctx) {
    // Only relevant if the sequence will actually capture.
    final hasEnabledExposure = sequence.nodes.values
        .whereType<ExposureNode>()
        .any((n) => n.isEnabled);
    if (!hasEnabledExposure) return const [];

    // appSettingsProvider is an AsyncNotifier; `.read()` returns AsyncValue.
    // We use the public `value` getter, which returns null while loading or
    // in an error state. Either way, the rule emits an info-severity issue
    // rather than skipping silently.
    final settingsAsync = ctx.ref.read(appSettingsProvider);
    final settings = settingsAsync.value;
    if (settings == null) {
      // App settings not loaded yet — we can't validate. Surface clearly
      // rather than skipping silently.
      return const [
        ValidationIssue(
          severity: ValidationSeverity.info,
          category: ValidationCategory.settings,
          title: 'Settings Not Loaded',
          description:
              'Cannot validate image output path — app settings are still loading.',
        ),
      ];
    }

    final raw = settings.imageOutputPath;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return const [
        ValidationIssue(
          severity: ValidationSeverity.error,
          category: ValidationCategory.settings,
          title: 'Image Output Path Not Configured',
          // Operator-facing copy names what the operator can act on, not the
          // internal field or the HTTP route that carries it; the
          // `resolutionHint` below says where to go.
          description:
              'No capture folder is set, so frames would be captured and then '
              'discarded. Choose where images should be saved before starting '
              'the sequence.',
          resolutionHint:
              'Configure an image save location in Settings → File Output.',
          code: 'image_output_path_not_configured',
        ),
      ];
    }

    final dir = Directory(trimmed);
    if (!dir.existsSync()) {
      return [
        ValidationIssue(
          severity: ValidationSeverity.error,
          category: ValidationCategory.settings,
          title: 'Image Output Path Missing',
          description:
              'Configured image output directory does not exist: $trimmed',
          resolutionHint:
              'Create the directory or update Settings → File Output to '
              'point to an existing location.',
          code: 'image_output_path_missing',
        ),
      ];
    }

    // Probe-write a tempfile to verify the directory is writable. Fail-
    // closed: any I/O exception here is treated as not-writable.
    final probePath =
        '${dir.path}${Platform.pathSeparator}.skotiq_writable_probe';
    File? probe;
    try {
      probe = File(probePath);
      probe.writeAsStringSync('ok');
    } catch (e) {
      return [
        ValidationIssue(
          severity: ValidationSeverity.error,
          category: ValidationCategory.settings,
          title: 'Image Output Path Not Writable',
          description:
              'Configured image output directory cannot be written: '
              '$trimmed ($e)',
          resolutionHint:
              'Check filesystem permissions, free disk space, or update '
              'Settings → File Output to point to a writable directory.',
          code: 'image_output_path_not_writable',
        ),
      ];
    } finally {
      try {
        probe?.deleteSync();
      } catch (_) {
        // Probe cleanup failure is harmless — leaves an empty file. We
        // do NOT promote this to an error because we already succeeded
        // in writing, which was the actual signal we needed.
      }
    }
    return const [];
  }
}

/// Info-only: flag a sequence still named "Untitled Sequence".
class DefaultSequenceNameRule implements RefAwareSequenceValidator {
  @override
  String get name => 'DefaultSequenceName';

  @override
  List<ValidationIssue> validate(Sequence sequence, ValidationContext ctx) {
    final n = sequence.name;
    if (n.isEmpty || n == 'Untitled Sequence') {
      return const [
        ValidationIssue(
          severity: ValidationSeverity.info,
          category: ValidationCategory.settings,
          title: 'Default Sequence Name',
          description:
              'Consider naming your sequence for easier identification.',
        ),
      ];
    }
    return const [];
  }
}

/// Info-only: flag a very long estimated duration. Users running 10+ hour
/// sequences usually want to know.
class LongEstimatedDurationRule implements RefAwareSequenceValidator {
  @override
  String get name => 'LongEstimatedDuration';

  @override
  List<ValidationIssue> validate(Sequence sequence, ValidationContext ctx) {
    final mins = sequence.estimatedDurationMins;
    if (mins == null) return const [];
    if (mins <= 600) return const [];
    return const [
      ValidationIssue(
        severity: ValidationSeverity.info,
        category: ValidationCategory.settings,
        title: 'Long Sequence',
        description: 'This sequence is estimated to run for over 10 hours.',
      ),
    ];
  }
}

/// Warns when the sequence has targets, runs > 2 hours, but has no
/// meridian-flip handling (no MeridianFlipNode + no Recovery node with
/// meridianFlip trigger). Targets crossing the meridian during a long run
/// will smash the mount into tracking limits without a flip.
class MeridianFlipTriggerRule implements RefAwareSequenceValidator {
  @override
  String get name => 'MeridianFlipTrigger';

  @override
  List<ValidationIssue> validate(Sequence sequence, ValidationContext ctx) {
    final targets = sequence.targetHeaders;
    if (targets.isEmpty) return const [];

    final hasFlipNode = sequence.nodes.values.any(
      (n) => n is MeridianFlipNode && n.isEnabled,
    );
    if (hasFlipNode) return const [];

    final hasRecoveryFlip = sequence.nodes.values.any(
      (n) =>
          n is RecoveryNode &&
          n.isEnabled &&
          n.triggerType == TriggerType.meridianFlip,
    );
    if (hasRecoveryFlip) return const [];

    double totalMins = 0;
    for (final node in sequence.nodes.values) {
      if (node is! ExposureNode) continue;
      if (!node.isEnabled) continue;
      totalMins += (node.durationSecs * node.count) / 60.0;
    }
    if (totalMins < 120) return const [];

    return const [
      ValidationIssue(
        severity: ValidationSeverity.warning,
        category: ValidationCategory.equipment,
        title: 'No Meridian Flip Trigger',
        description:
            'This sequence has targets and runs for over 2 hours but has no meridian flip trigger. '
            'If targets cross the meridian during imaging, the mount may hit its tracking limits.',
        resolutionHint:
            'Add a MeridianFlip node to the sequence or enable auto meridian flip in Settings → Meridian Flip.',
      ),
    ];
  }
}
