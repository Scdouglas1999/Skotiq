import '../../../services/optical_train_diagnostics_service.dart';
import '../../preflight_providers.dart';
import '../sequence_validation.dart';

// Post-session diagnostics.
//
// Post-session checks do NOT plug into the SequenceValidator pipeline —
// that pipeline runs before a sequence starts. Instead these helpers
// turn the captured `OpticalTrainBaseline` (pre-session) and the
// post-session snapshot into the same `ValidationIssue` value type so
// the session-report dialog can render them with the existing chrome.
//
// Each function returns a list rather than emitting through Riverpod
// because the report dialog already pulls the diagnostics data
// directly; this keeps the rendering paths uniform with the pre-flight
// dialog.

/// Compares the post-session optical-train snapshot with the
/// pre-session baseline. Returns an info-severity issue summarising
/// the drift when one exists, or an empty list if no comparison is
/// possible (no baseline / no post snapshot).
///
/// Threshold uses the same `opticalTrainDriftThreshold` setting that
/// the pre-flight rule consults, so "your rig drifted" appears at
/// the same magnitude before and after.
List<ValidationIssue> postSessionOpticalTrainDrift({
  required OpticalTrainBaseline? preSession,
  required OpticalTrainDiagnostics? postSession,
  required double threshold,
}) {
  if (preSession == null || postSession == null) {
    return const [];
  }
  final dTilt = (postSession.tiltScore - preSession.tiltScore).abs();
  final dColl = (postSession.collimationScore - preSession.collimationScore)
      .abs();
  final drift = dTilt * 0.5 + dColl * 0.5;

  // Below the threshold: tell the user the rig held steady. This is
  // info, not silence — confirming "no drift" is one of the things
  // they care about most after a long run.
  if (drift < threshold) {
    return [
      ValidationIssue(
        severity: ValidationSeverity.info,
        category: ValidationCategory.opticalTrain,
        title: 'Optical Train Held Steady',
        description:
            'Tilt/collimation diagnostics moved ${drift.toStringAsFixed(1)} '
            'units during the session — below the '
            '${threshold.toStringAsFixed(1)} drift threshold.',
      ),
    ];
  }

  return [
    ValidationIssue(
      severity: ValidationSeverity.info,
      category: ValidationCategory.opticalTrain,
      title: 'Optical Train Drifted During Session',
      description:
          'Tilt/collimation diagnostics shifted '
          '${drift.toStringAsFixed(1)} units during the session '
          '(threshold ${threshold.toStringAsFixed(1)}). '
          'Tilt Δ ${dTilt.toStringAsFixed(1)}, '
          'collimation Δ ${dColl.toStringAsFixed(1)}.',
      resolutionHint:
          'Re-check spacers, focuser back-focus, and rotator clamp before '
          'the next session.',
    ),
  ];
}

/// Renders the [PostSessionHealthSummary] (USB disconnects, cooler
/// stability, focuser moves, sky brightness, noticed concerns) into
/// info-severity validation issues for the session-report dialog.
///
/// All issues are info — they're observations, not actionable warnings
/// (the run is already over). The summary is rendered in the new
/// "Diagnostics" section below the existing warnings / recovery
/// blocks.
List<ValidationIssue> postSessionEquipmentHealthSummary(
  PostSessionHealthSummary summary,
) {
  final issues = <ValidationIssue>[];
  if (summary.disconnectsDuringSession > 0) {
    issues.add(
      ValidationIssue(
        severity: ValidationSeverity.info,
        category: ValidationCategory.equipmentHealth,
        title: 'USB Disconnects During Session',
        description:
            '${summary.disconnectsDuringSession} '
            'reconnect${summary.disconnectsDuringSession == 1 ? "" : "s"} '
            'occurred during the run.',
        resolutionHint: summary.disconnectsDuringSession > 10
            ? 'High count — investigate the USB cable / hub for the devices '
                  'involved before the next session.'
            : null,
      ),
    );
  }
  if (summary.coolerOutOfBandSamples > 0) {
    issues.add(
      ValidationIssue(
        severity: ValidationSeverity.info,
        category: ValidationCategory.equipmentHealth,
        title: 'Cooler Out of Setpoint Band',
        description:
            'Cooler temperature drifted outside its setpoint band on '
            '${summary.coolerOutOfBandSamples} samples.',
      ),
    );
  }
  if (summary.focuserMoves > 0) {
    issues.add(
      ValidationIssue(
        severity: ValidationSeverity.info,
        category: ValidationCategory.equipmentHealth,
        title: 'Focuser Activity',
        description:
            '${summary.focuserMoves} focuser move${summary.focuserMoves == 1 ? "" : "s"} '
            'recorded during the run (autofocus + temperature compensation).',
      ),
    );
  }
  if (summary.skyBrightnessMin != null && summary.skyBrightnessMax != null) {
    final min = summary.skyBrightnessMin!;
    final max = summary.skyBrightnessMax!;
    final medianStr = summary.skyBrightnessMedian == null
        ? ''
        : ', median ${summary.skyBrightnessMedian!.toStringAsFixed(2)}';
    issues.add(
      ValidationIssue(
        severity: ValidationSeverity.info,
        category: ValidationCategory.equipmentHealth,
        title: 'Sky Brightness Range',
        description:
            'Sky brightness ranged ${min.toStringAsFixed(2)} → '
            '${max.toStringAsFixed(2)} mag/arcsec²$medianStr.',
      ),
    );
  }
  for (final concern in summary.noticedConcerns) {
    issues.add(
      ValidationIssue(
        severity: ValidationSeverity.info,
        category: ValidationCategory.equipmentHealth,
        title: 'Noticed but Did Not Fire',
        description: concern,
      ),
    );
  }
  return issues;
}

/// Returns all post-session diagnostics for rendering in the session
/// report dialog, grouped in display order.
class PostSessionDiagnostics {
  final List<ValidationIssue> opticalTrain;
  final List<ValidationIssue> equipmentHealth;

  const PostSessionDiagnostics({
    required this.opticalTrain,
    required this.equipmentHealth,
  });

  bool get isEmpty => opticalTrain.isEmpty && equipmentHealth.isEmpty;
  bool get isNotEmpty => !isEmpty;

  /// All issues flattened — convenient for the dialog's iteration when
  /// it doesn't care about category grouping.
  List<ValidationIssue> get all => [...opticalTrain, ...equipmentHealth];

  static PostSessionDiagnostics build({
    required OpticalTrainBaseline? preSession,
    required OpticalTrainDiagnostics? postSession,
    required PostSessionHealthSummary healthSummary,
    required double opticalTrainDriftThreshold,
  }) {
    return PostSessionDiagnostics(
      opticalTrain: postSessionOpticalTrainDrift(
        preSession: preSession,
        postSession: postSession,
        threshold: opticalTrainDriftThreshold,
      ),
      equipmentHealth: postSessionEquipmentHealthSummary(healthSummary),
    );
  }
}
