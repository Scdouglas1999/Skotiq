/// Plain-language insight generator for the science layer.
///
/// Shared by the Imaging HUD and the Session dashboard, so the thresholds are
/// stated once.
///
/// Each insight is intentionally short — one sentence with a concrete next
/// action. Severities map to the standard `SkotiqColors` palette
/// (info / success / warning / error) at the UI layer.
library;

import '../../database/database.dart'
    show
        FramePhotometricCalibrationRow,
        ScienceFrameQualityMetricsRow,
        TransparencySampleRow;
import '../equipment_health_service.dart' show EquipmentHealthReport;
import '../optical_train_diagnostics_service.dart'
    show OpticalIssueSeverity, OpticalTrainDiagnostics;
import 'science_status.dart';

/// Severity tier — matches the standard four-level palette used elsewhere
/// in the app (Success / Info / Warning / Error). UI converts to a colour.
enum ScienceInsightSeverity { success, info, warning, error }

/// A single user-facing insight.
class ScienceInsight {
  /// Stable id (e.g. "transparency.below_threshold"). Useful for tests and
  /// for de-duplicating between Imaging and Analytics surfaces.
  final String id;

  /// Severity tier — drives icon and accent colour.
  final ScienceInsightSeverity severity;

  /// Short headline (1 line).
  final String headline;

  /// Optional follow-up sentence with the concrete action.
  final String? body;

  const ScienceInsight({
    required this.id,
    required this.severity,
    required this.headline,
    this.body,
  });
}

/// Snapshot fed into the engine. Keeping inputs explicit (instead of reading
/// providers inside the engine) makes the engine pure and trivial to test.
class ScienceInsightsInputs {
  final ScienceFrameQualityMetricsRow? latestFrameQuality;
  final FramePhotometricCalibrationRow? latestCalibration;
  final TransparencySampleRow? latestTransparency;
  final OpticalTrainDiagnostics? diagnostics;
  final EquipmentHealthReport? healthReport;

  /// Number of calibrated rows accumulated this session so far. Drives the
  /// "transparency unlocks after N frames" hint.
  final int calibratedFrameCount;

  /// Number of frames the science pipeline has processed in this session.
  final int processedFrameCount;

  /// Number of those frames that produced a successful plate solve.
  final int solvedFrameCount;

  /// Most recently failed stage, if any. Surfaces a "last error" insight.
  final ScienceStageResult? lastFailure;

  const ScienceInsightsInputs({
    this.latestFrameQuality,
    this.latestCalibration,
    this.latestTransparency,
    this.diagnostics,
    this.healthReport,
    this.calibratedFrameCount = 0,
    this.processedFrameCount = 0,
    this.solvedFrameCount = 0,
    this.lastFailure,
  });

  double get solveRate {
    if (processedFrameCount <= 0) return 0.0;
    return solvedFrameCount / processedFrameCount;
  }
}

/// Pure rule engine. `evaluate` takes a snapshot and emits insights ordered
/// by severity (errors first), with stable insight ids so the UI can animate
/// list changes if needed.
class ScienceInsightsEngine {
  const ScienceInsightsEngine();

  /// Minimum calibrated frames before the transparency model is considered
  /// trustworthy. Below this we tell the user how far away they are.
  static const int minCalibratedForTransparency = 5;

  /// Solve-rate threshold below which we surface a guidance message.
  static const double poorSolveRate = 0.5;

  List<ScienceInsight> evaluate(ScienceInsightsInputs input) {
    final out = <ScienceInsight>[];

    // ── Last pipeline error ────────────────────────────────────────────────
    final failure = input.lastFailure;
    if (failure != null) {
      out.add(
        ScienceInsight(
          id: 'pipeline.last_failure',
          severity: ScienceInsightSeverity.error,
          headline:
              '${failure.stage.displayName} failed on the most recent frame',
          body:
              failure.note ??
              'Check the science log for details. The capture itself is unaffected.',
        ),
      );
    }

    // ── Plate-solve health ─────────────────────────────────────────────────
    if (input.processedFrameCount >= 3) {
      final pct = (input.solveRate * 100).round();
      if (input.solvedFrameCount == 0) {
        out.add(
          const ScienceInsight(
            id: 'solve.none',
            severity: ScienceInsightSeverity.warning,
            headline: 'No frames have been plate-solved this session',
            body:
                'Most science products need a WCS. Configure a plate solver in Settings → Plate Solving.',
          ),
        );
      } else if (input.solveRate < poorSolveRate) {
        out.add(
          ScienceInsight(
            id: 'solve.low_rate',
            severity: ScienceInsightSeverity.warning,
            headline:
                'Only $pct% of frames are plate-solving (${input.solvedFrameCount}/${input.processedFrameCount})',
            body:
                'Check focal length, pixel scale, and that your solver has the right catalog index installed.',
          ),
        );
      }
    }

    // ── Transparency progress ──────────────────────────────────────────────
    // Only nudge once a session is actually under way (>=1 processed frame).
    // Showing a transparency hint with zero captures would be noise on a
    // fresh install / pre-session UI state.
    if (input.processedFrameCount > 0 &&
        input.latestTransparency == null &&
        input.calibratedFrameCount < minCalibratedForTransparency) {
      final remaining =
          minCalibratedForTransparency - input.calibratedFrameCount;
      out.add(
        ScienceInsight(
          id: 'transparency.warming_up',
          severity: ScienceInsightSeverity.info,
          headline:
              'Transparency unlocks after $remaining more calibrated frame${remaining == 1 ? '' : 's'}',
          body:
              'Atmospheric estimates stabilise once $minCalibratedForTransparency photometric calibrations are in the buffer.',
        ),
      );
    }

    // ── Frame quality ──────────────────────────────────────────────────────
    final fm = input.latestFrameQuality;
    if (fm != null) {
      if (fm.highClipPercent > 1.5) {
        out.add(
          const ScienceInsight(
            id: 'frame.high_clip',
            severity: ScienceInsightSeverity.warning,
            headline: 'Highlights are clipping',
            body:
                'Reduce exposure or gain to protect bright stars before more frames burn in.',
          ),
        );
      }
      if (fm.lowClipPercent > 1.5) {
        out.add(
          const ScienceInsight(
            id: 'frame.low_clip',
            severity: ScienceInsightSeverity.info,
            headline: 'Shadow clipping is elevated',
            body:
                'Increase exposure length or relax the black point so faint detail isn\'t lost.',
          ),
        );
      }
      if (fm.uniformityCv > 0.28) {
        out.add(
          const ScienceInsight(
            id: 'frame.uniformity',
            severity: ScienceInsightSeverity.warning,
            headline: 'Background uniformity is uneven',
            body:
                'Check flats, gradients, and possible optical tilt — the field is brighter on one side.',
          ),
        );
      }
      if (fm.snr < 10) {
        out.add(
          const ScienceInsight(
            id: 'frame.low_snr',
            severity: ScienceInsightSeverity.info,
            headline: 'Frame SNR is low',
            body: 'Longer subs or more total integration will help.',
          ),
        );
      }
    }

    // ── Transparency value ─────────────────────────────────────────────────
    final transparency = input.latestTransparency;
    if (transparency != null && transparency.transparencyPercent < 75) {
      out.add(
        ScienceInsight(
          id: 'transparency.below_threshold',
          severity: ScienceInsightSeverity.info,
          headline:
              'Sky transparency is ${transparency.transparencyPercent.toStringAsFixed(1)}%',
          body:
              'Quality may vary frame-to-frame. Consider stacking only the best windows.',
        ),
      );
    }

    // ── Calibration fit quality ────────────────────────────────────────────
    final calibration = input.latestCalibration;
    if (calibration != null &&
        calibration.isCalibrated &&
        calibration.calibrationRms > 0.2) {
      out.add(
        ScienceInsight(
          id: 'calibration.high_rms',
          severity: ScienceInsightSeverity.info,
          headline:
              'Photometric fit RMS is ${calibration.calibrationRms.toStringAsFixed(2)} mag',
          body:
              'Verify focus and plate-solve inputs — a noisy fit reduces limiting-magnitude accuracy.',
        ),
      );
    }
    if (calibration != null &&
        calibration.isCalibrated &&
        calibration.matchedStarCount < 12) {
      out.add(
        ScienceInsight(
          id: 'calibration.few_matches',
          severity: ScienceInsightSeverity.info,
          headline:
              'Only ${calibration.matchedStarCount} catalog stars matched',
          body:
              'Calibration is usable but more matches give a steadier zero-point. Try a denser field or a wider catalog.',
        ),
      );
    }

    // ── Optical-train diagnostics ──────────────────────────────────────────
    final diag = input.diagnostics;
    if (diag != null) {
      var optIndex = 0;
      for (final issue in diag.issues.take(2)) {
        out.add(
          ScienceInsight(
            id: 'optical.${optIndex++}',
            severity: switch (issue.severity) {
              OpticalIssueSeverity.info => ScienceInsightSeverity.info,
              OpticalIssueSeverity.warning => ScienceInsightSeverity.warning,
              OpticalIssueSeverity.critical => ScienceInsightSeverity.error,
            },
            headline: issue.title,
            body: issue.detail,
          ),
        );
      }
    }

    // ── Equipment health ───────────────────────────────────────────────────
    final health = input.healthReport;
    if (health != null) {
      var eqIndex = 0;
      for (final insight in health.insights.take(2)) {
        out.add(
          ScienceInsight(
            id: 'equipment.${eqIndex++}',
            severity: ScienceInsightSeverity.info,
            headline: insight.title,
            body: insight.message,
          ),
        );
      }
    }

    // Sort: error → warning → info → success.
    // Enum order is success(0), info(1), warning(2), error(3) — so we
    // compare in reverse to put higher-severity items at the top of the list.
    out.sort((a, b) => b.severity.index.compareTo(a.severity.index));
    return out;
  }
}
