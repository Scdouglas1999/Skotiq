/// Immutable input snapshot handed to every [NarratorDetector].
///
/// The engine and detectors are *pure* given a [NarratorContext] plus each
/// detector's own rolling state. Keeping every input explicit here (rather than
/// reading providers inside detectors) is what makes the whole Narrator trivial
/// to unit-test with synthetic context sequences — exactly the pattern
/// [ScienceInsightsInputs] established for `ScienceInsightsEngine`.
///
/// **Graceful degradation is by construction:** every field is nullable or an
/// empty collection by default. A session with no guiding, no weather, no SQM,
/// or science disabled simply hands the detectors empty inputs, and the
/// detectors that depend on those inputs never fire. No detector throws on
/// missing data.
///
/// **The clock is injected.** Detectors must read [now] instead of calling
/// `DateTime.now()` so their trend/cooldown maths is deterministic in tests.
library;

import '../../../database/database.dart'
    show FramePhotometricCalibrationRow, ScienceFrameQualityMetricsRow;
import '../../../models/science/science_models.dart'
    show LightCurvePoint, MovingObjectCandidate, TransparencyTrendPoint;
import '../../optical_train_diagnostics_service.dart'
    show OpticalTrainDiagnostics;
import '../../transients/transient_candidate.dart' show TransientCandidate;
import '../science_status.dart' show ScienceStageResult;

/// A single point of the auto-grader's accept/reject history. Produced by a
/// small hook from where the auto-grader runs (so the Narrator does not have to
/// re-derive the grade), with [rejected] = false for accepted frames.
class NarratorGradeEvent {
  final int capturedImageId;
  final DateTime timestamp;
  final bool rejected;

  /// The grader's reason string when [rejected] is true, e.g.
  /// `Auto-grade: HFR 3.40 > 3.20`. Null for accepted frames.
  final String? reason;

  const NarratorGradeEvent({
    required this.capturedImageId,
    required this.timestamp,
    required this.rejected,
    this.reason,
  });
}

/// Per-frame imaging stats the Narrator watches for the focus/seeing/star-count
/// detectors. Sourced from the live capture stats hook (HFR/FWHM/star count)
/// because those are not all persisted on the science quality row.
class NarratorImageStats {
  final DateTime timestamp;
  final int? capturedImageId;
  final double? hfr;
  final double? fwhm;
  final int? starCount;

  /// Frame timestamp's focuser temperature in °C, when a focuser reports it.
  /// Null whenever no temperature-reporting focuser is connected.
  final double? focuserTempC;

  const NarratorImageStats({
    required this.timestamp,
    this.capturedImageId,
    this.hfr,
    this.fwhm,
    this.starCount,
    this.focuserTempC,
  });
}

/// A single sky-background sample derived from a light frame's measured
/// background. [aduPerSecond] is the background ADU normalized by the frame's
/// exposure time; it is *not* absolutely calibrated, so it only supports a
/// relative (filter-matched) brightness-change measurement, never an absolute
/// mag/arcsec². [filter] is required so the detector can compare like-with-like
/// (an L→Ha filter change otherwise swings the background by magnitudes).
class NarratorSkySample {
  final DateTime timestamp;
  final double aduPerSecond;
  final String? filter;

  const NarratorSkySample({
    required this.timestamp,
    required this.aduPerSecond,
    this.filter,
  });
}

/// Accumulated integration per filter, in seconds. Drives the integration
/// milestone.
class NarratorFilterIntegration {
  final String filter;
  final double seconds;

  /// The target this integration is on, for the headline ("…on NGC 7000").
  final String? targetName;

  const NarratorFilterIntegration({
    required this.filter,
    required this.seconds,
    this.targetName,
  });
}

/// Result of a completed period analysis the Narrator can announce.
class NarratorPeriodResult {
  final String objectId;
  final double periodDays;

  /// Lomb-Scargle false-alarm probability (lower = more significant).
  final double? lombScargleFap;

  /// BLS signal-detection efficiency (higher = more significant).
  final double? blsSde;

  const NarratorPeriodResult({
    required this.objectId,
    required this.periodDays,
    this.lombScargleFap,
    this.blsSde,
  });
}

/// Weather layer cloud read, when a weather provider is configured.
class NarratorWeatherState {
  /// Whether the weather layer currently reports clouds (used to disambiguate
  /// a star-count collapse from focus drift).
  final bool cloudy;

  /// Cloud cover percentage when available, else null.
  final double? cloudCoverPercent;

  const NarratorWeatherState({required this.cloudy, this.cloudCoverPercent});
}

/// Immutable snapshot of every Narrator input at a single instant.
class NarratorContext {
  /// Injected clock. Detectors MUST use this, never `DateTime.now()`.
  final DateTime now;

  /// Active session id, if a session is running. Sessionless captures pass
  /// null; events are then stored with a null sessionId.
  final int? sessionId;

  /// The frame that prompted this context build, if this was a per-frame
  /// update. Stamped onto fired events as `capturedImageId`.
  final int? capturedImageId;

  // ── Photometry / calibration ──────────────────────────────────────────────
  /// Photometric calibrations this session, oldest → newest.
  final List<FramePhotometricCalibrationRow> calibrations;

  /// Number of calibrated frames so far (rows with `isCalibrated`).
  final int calibratedFrameCount;

  // ── Light curve ───────────────────────────────────────────────────────────
  /// The light-curve points for the primary target, oldest → newest.
  final List<LightCurvePoint> lightCurve;

  /// Completed period-analysis results to announce (usually 0 or 1).
  final List<NarratorPeriodResult> periodResults;

  // ── Discovery ─────────────────────────────────────────────────────────────
  /// Moving-object candidates detected this session.
  final List<MovingObjectCandidate> movingObjects;

  /// First Light (Pillar B) difference-imaging transient candidates from the
  /// frame that prompted this context, already cross-matched (so
  /// `catalogMatch == null` is a genuine unknown). Empty whenever the frame was
  /// not differenced against the atlas (no deep template yet, atlas disabled).
  final List<TransientCandidate> transientCandidates;

  // ── Conditions ────────────────────────────────────────────────────────────
  /// Transparency trend points this session, oldest → newest.
  final List<TransparencyTrendPoint> transparency;

  /// SQM samples this session, oldest → newest.
  final List<NarratorSkySample> skySamples;

  /// Weather layer cloud read, if configured.
  final NarratorWeatherState? weather;

  // ── Frame quality / equipment ─────────────────────────────────────────────
  /// Science frame-quality rows this session, oldest → newest (clip, gradient).
  final List<ScienceFrameQualityMetricsRow> frameQuality;

  /// Per-frame imaging stats (HFR / FWHM / star count), oldest → newest.
  final List<NarratorImageStats> imageStats;

  /// Latest optical-train diagnostics run, if any.
  final OpticalTrainDiagnostics? diagnostics;

  /// HFR baseline captured at the most recent successful autofocus, when known.
  final double? autofocusHfrBaseline;

  // ── Guiding ───────────────────────────────────────────────────────────────
  /// Rolling guide RMS-total history (arcsec), oldest → newest.
  final List<double> guideRmsTotalHistory;

  /// Latest guide RMS total (arcsec), if guiding is active.
  final double? guideRmsTotal;

  // ── Integration ───────────────────────────────────────────────────────────
  /// Accumulated integration per filter.
  final List<NarratorFilterIntegration> filterIntegration;

  // ── Pipeline / grader ─────────────────────────────────────────────────────
  /// Auto-grader accept/reject events, oldest → newest.
  final List<NarratorGradeEvent> gradeEvents;

  /// Rolling plate-solve outcomes (true = solved), oldest → newest.
  final List<bool> solveHistory;

  /// Most recent failed science stage, if any.
  final ScienceStageResult? lastStageFailure;

  const NarratorContext({
    required this.now,
    this.sessionId,
    this.capturedImageId,
    this.calibrations = const [],
    this.calibratedFrameCount = 0,
    this.lightCurve = const [],
    this.periodResults = const [],
    this.movingObjects = const [],
    this.transientCandidates = const [],
    this.transparency = const [],
    this.skySamples = const [],
    this.weather,
    this.frameQuality = const [],
    this.imageStats = const [],
    this.diagnostics,
    this.autofocusHfrBaseline,
    this.guideRmsTotalHistory = const [],
    this.guideRmsTotal,
    this.filterIntegration = const [],
    this.gradeEvents = const [],
    this.solveHistory = const [],
    this.lastStageFailure,
  });
}
