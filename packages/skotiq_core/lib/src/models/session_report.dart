/// Aggregated end-of-session report surfaced after a sequence completes
/// (or aborts / errors) and from the analytics history.
///
/// All numeric fields are derived from existing Drift tables — `imaging_sessions`,
/// `captured_images`, `image_metadata`, and `sequence_runs` — so the report
/// stays read-only and can be regenerated for any past session.
///
/// `null`-able fields encode "no signal" rather than zero so the UI can render
/// dashes instead of misleading "0.00" values when a metric was never recorded
/// (e.g. guider RMS for an unguided night).
library;

/// Per-filter rollup for the report.
class SessionFilterReport {
  /// Filter name as captured (case-preserved). "Unfiltered" when no filter
  /// was on the wheel.
  final String filter;

  /// Frames the sequencer attempted, i.e. accepted + rejected.
  final int framesAttempted;

  /// Frames accepted by quality gates / `isAccepted` flag.
  final int framesAccepted;

  /// Frames rejected. `framesAttempted - framesAccepted`.
  final int framesRejected;

  /// Total accepted exposure time in seconds.
  final double totalIntegrationSecs;

  /// Mean half-flux radius across accepted frames. Null when no frame
  /// recorded HFR for this filter.
  final double? meanHfr;

  /// Mean full-width-half-max across accepted frames, computed as
  /// `meanHfr * 2.0` (Gaussian assumption — same factor the codebase uses
  /// elsewhere). Null when `meanHfr` is null.
  final double? meanFwhm;

  /// Mean star count across accepted frames. Null when no frame recorded a
  /// star count for this filter.
  final double? meanStarCount;

  /// Mean signal-to-noise across accepted frames. Sourced from the science
  /// pipeline's per-frame SNR when available (real photometric SNR);
  /// otherwise falls back to the captured-image `background / noise`
  /// proxy — see [snrIsProxy]. Null when neither source has data.
  final double? meanSnr;

  /// True when [meanSnr] is the background/noise PROXY rather than the
  /// science pipeline's real SNR. Surfaced so exports can label proxy
  /// values honestly — a proxy of 8 and a real SNR of 45 describe the
  /// same data, and presenting the former bare as "SNR" misleads.
  final bool snrIsProxy;

  /// Mean guider RMS total ("seeing") across accepted frames in arcsec.
  /// Null when no frame had guiding data for this filter.
  final double? meanGuidingRmsTotal;

  /// Mean sensor temperature across accepted frames. Null when no frame
  /// recorded sensor temperature for this filter.
  final double? meanSensorTemp;

  /// Histogram of `rejectionReason` -> count for the filter's rejected
  /// frames. Empty when `framesRejected == 0`.
  final Map<String, int> rejectionReasons;

  const SessionFilterReport({
    required this.filter,
    required this.framesAttempted,
    required this.framesAccepted,
    required this.framesRejected,
    required this.totalIntegrationSecs,
    required this.meanHfr,
    required this.meanFwhm,
    required this.meanStarCount,
    required this.meanSnr,
    this.snrIsProxy = true,
    required this.meanGuidingRmsTotal,
    required this.meanSensorTemp,
    required this.rejectionReasons,
  });

  Map<String, dynamic> toJson() => {
    'filter': filter,
    'framesAttempted': framesAttempted,
    'framesAccepted': framesAccepted,
    'framesRejected': framesRejected,
    'totalIntegrationSecs': totalIntegrationSecs,
    'meanHfr': meanHfr,
    'meanFwhm': meanFwhm,
    'meanStarCount': meanStarCount,
    'meanSnr': meanSnr,
    'snrIsProxy': snrIsProxy,
    'meanGuidingRmsTotal': meanGuidingRmsTotal,
    'meanSensorTemp': meanSensorTemp,
    'rejectionReasons': rejectionReasons,
  };
}

/// Per-target rollup (one report can cover multiple targets when the
/// sequence visits more than one).
class SessionTargetReport {
  /// Foreign-key `targets.id` of the target, when known. Null for frames
  /// captured without a linked target.
  final int? targetId;

  /// Display name. Defaults to "Untargeted" when [targetId] is null.
  final String targetName;

  /// Per-filter rollup for this target, sorted alphabetically by filter
  /// name for stable display ordering.
  final List<SessionFilterReport> filters;

  const SessionTargetReport({
    required this.targetId,
    required this.targetName,
    required this.filters,
  });

  /// Sum of [filters]' `framesAttempted`.
  int get framesAttempted =>
      filters.fold<int>(0, (sum, f) => sum + f.framesAttempted);

  /// Sum of [filters]' `framesAccepted`.
  int get framesAccepted =>
      filters.fold<int>(0, (sum, f) => sum + f.framesAccepted);

  /// Sum of [filters]' `framesRejected`.
  int get framesRejected =>
      filters.fold<int>(0, (sum, f) => sum + f.framesRejected);

  /// Sum of [filters]' integration time, in seconds.
  double get totalIntegrationSecs =>
      filters.fold<double>(0.0, (sum, f) => sum + f.totalIntegrationSecs);

  Map<String, dynamic> toJson() => {
    'targetId': targetId,
    'targetName': targetName,
    'filters': filters.map((f) => f.toJson()).toList(),
    'framesAttempted': framesAttempted,
    'framesAccepted': framesAccepted,
    'framesRejected': framesRejected,
    'totalIntegrationSecs': totalIntegrationSecs,
  };
}

/// Guide-stats rollup across the whole session.
class SessionGuideStats {
  /// Mean of `guidingRmsRa` across accepted frames, arcsec.
  final double? meanRmsRaArcsec;

  /// Mean of `guidingRmsDec` across accepted frames, arcsec.
  final double? meanRmsDecArcsec;

  /// Mean of `guidingRmsTotal` across accepted frames, arcsec.
  final double? meanRmsTotalArcsec;

  /// Maximum `guidingRmsRa` observed on any accepted frame.
  final double? maxRmsRaArcsec;

  /// Maximum `guidingRmsDec` observed on any accepted frame.
  final double? maxRmsDecArcsec;

  /// Maximum `guidingRmsTotal` observed on any accepted frame.
  final double? maxRmsTotalArcsec;

  /// Fraction `[0.0, 1.0]` of total frames that had no guiding RMS recorded.
  /// 1.0 == fully unguided run; 0.0 == every frame guided.
  final double percentUnguidedFrames;

  const SessionGuideStats({
    required this.meanRmsRaArcsec,
    required this.meanRmsDecArcsec,
    required this.meanRmsTotalArcsec,
    required this.maxRmsRaArcsec,
    required this.maxRmsDecArcsec,
    required this.maxRmsTotalArcsec,
    required this.percentUnguidedFrames,
  });

  /// Convenience: "no guiding observed at all" — every metric is null/100%.
  bool get isEmpty =>
      meanRmsRaArcsec == null &&
      meanRmsDecArcsec == null &&
      meanRmsTotalArcsec == null;

  Map<String, dynamic> toJson() => {
    'meanRmsRaArcsec': meanRmsRaArcsec,
    'meanRmsDecArcsec': meanRmsDecArcsec,
    'meanRmsTotalArcsec': meanRmsTotalArcsec,
    'maxRmsRaArcsec': maxRmsRaArcsec,
    'maxRmsDecArcsec': maxRmsDecArcsec,
    'maxRmsTotalArcsec': maxRmsTotalArcsec,
    'percentUnguidedFrames': percentUnguidedFrames,
  };
}

/// Mount + operations rollup (autofocus, meridian flips, dithers, etc.).
class SessionMountStats {
  /// Autofocus runs as recorded on the session row or by the sequence-run
  /// stats blob (whichever is higher — the two paths sometimes disagree on
  /// recovery autofocus).
  final int autofocusRuns;

  /// Meridian flips. Sourced from sequence_runs stats; 0 when the session
  /// was driven outside the sequencer (e.g. quick capture).
  final int meridianFlips;

  /// Dither operations. Same provenance as [meridianFlips].
  final int ditherCount;

  /// Trigger watchdog activations (HFR trigger fires, etc.). Same
  /// provenance as [meridianFlips].
  final int triggerFires;

  const SessionMountStats({
    required this.autofocusRuns,
    required this.meridianFlips,
    required this.ditherCount,
    required this.triggerFires,
  });

  Map<String, dynamic> toJson() => {
    'autofocusRuns': autofocusRuns,
    'meridianFlips': meridianFlips,
    'ditherCount': ditherCount,
    'triggerFires': triggerFires,
  };
}

/// Per-frame-type rollup of the calibration frames a session captured.
///
/// The report's target/filter rollup covers LIGHT frames only, which is
/// correct — a dark contributes nothing to a target's integration. But the
/// headline counters were derived from that rollup alone, so a session that
/// captured nothing but calibration frames reported "Integration 0s", "Frames
/// accepted 0/0" and 100% downtime while `imaging_sessions` (3 exposures,
/// 6.0 s), the Imaging screen's "3 / 3 frames", Analytics and three FITS files
/// on disk all agreed the run had happened. Calibration frames are counted here
/// so no surface can claim a session captured nothing when it captured
/// something.
class SessionCalibrationReport {
  /// Normalised frame type, lower-case: 'dark', 'bias', 'flat', 'darkflat'.
  final String frameType;

  /// Frames of this type recorded for the session, accepted or not.
  final int framesAttempted;

  /// Frames of this type marked `is_accepted`.
  final int framesAccepted;

  /// Shutter-open seconds across the ACCEPTED frames of this type. A bias is
  /// ~0 s by construction, so this can legitimately be 0 alongside a non-zero
  /// [framesAccepted].
  final double totalIntegrationSecs;

  const SessionCalibrationReport({
    required this.frameType,
    required this.framesAttempted,
    required this.framesAccepted,
    required this.totalIntegrationSecs,
  });

  int get framesRejected => framesAttempted - framesAccepted;

  Map<String, dynamic> toJson() => {
    'frameType': frameType,
    'framesAttempted': framesAttempted,
    'framesAccepted': framesAccepted,
    'framesRejected': framesRejected,
    'totalIntegrationSecs': totalIntegrationSecs,
  };
}

/// Top-level session report.
///
/// Generated from the persisted Drift rows, so any past session can be
/// regenerated without re-running the sequencer.
class SessionReport {
  /// `imaging_sessions.id` the report was built from.
  final int sessionId;

  /// Display name of the session. Falls back to a generated label when the
  /// session row had no name.
  final String sessionName;

  /// Status string from the session row: 'completed', 'aborted', 'error',
  /// 'active', 'stopped'.
  final String status;

  /// Session start wall-clock time.
  final DateTime startTime;

  /// Session end wall-clock time. Null when the session is still active.
  final DateTime? endTime;

  /// `endTime - startTime`. Falls back to `now - startTime` when end is null.
  final Duration wallClockDuration;

  /// Sum of accepted exposure time across all targets / filters.
  final Duration totalIntegration;

  /// `totalIntegration / wallClockDuration`, clamped to `[0.0, 1.0]`.
  /// Reported separately so the UI can render "% effective imaging time"
  /// without dividing on the fly.
  final double effectiveImagingFraction;

  /// `wallClockDuration - totalIntegration`. Represents slew, dither,
  /// download, autofocus, and any idle time.
  final Duration downtime;

  /// Per-target / per-filter rollup. Ordered by target name for stable
  /// rendering; empty when the session has no accepted light frames.
  final List<SessionTargetReport> targets;

  /// Calibration frames captured by the same session, one entry per frame
  /// type, ordered by frame type. Empty when the session shot only lights.
  final List<SessionCalibrationReport> calibration;

  /// Whole-session guide-stats rollup.
  final SessionGuideStats guideStats;

  /// Mount + operations rollup.
  final SessionMountStats mountStats;

  /// Mean ambient temperature recorded on the session row, in celsius.
  /// Null when not tracked.
  final double? avgTemperatureC;

  /// Mean ambient humidity recorded on the session row, in percent.
  /// Null when not tracked.
  final double? avgHumidityPercent;

  /// Mean seeing recorded on the session row, in arcsec. Null when not
  /// tracked.
  final double? avgSeeingArcsec;

  /// User notes from the session row.
  final String? notes;

  /// Hard error messages collected from the matching sequence_runs
  /// row(s). Empty when no errors were recorded.
  final List<String> errorMessages;

  /// Non-fatal warning messages collected from the matching sequence_runs
  /// row(s), where they are persisted alongside errors in the stats JSON blob
  /// — see [SequenceRunStats.warningMessages]. Empty when none were recorded.
  final List<String> warningMessages;

  /// Why the run in this session ended badly, when one did — the FIRST real
  /// fault, never a teardown step the cancellation cascade tripped over. Null
  /// for a session whose runs did not fail.
  ///
  /// [errorMessages] is the whole cascade in the order it happened; this is the
  /// one line in it that answers "what do I fix". Chosen natively by
  /// `executor::failure_cause` and persisted on
  /// [SequenceRunStats.terminalCause].
  final String? terminalCause;

  /// The directory this session's rejected frames were moved into, when
  /// anything was rejected. What an operator opens next after a reject storm.
  final String? rejectFolder;

  /// When the report was generated.
  final DateTime generatedAt;

  const SessionReport({
    required this.sessionId,
    required this.sessionName,
    required this.status,
    required this.startTime,
    required this.endTime,
    required this.wallClockDuration,
    required this.totalIntegration,
    required this.effectiveImagingFraction,
    required this.downtime,
    required this.targets,
    this.calibration = const [],
    required this.guideStats,
    required this.mountStats,
    required this.avgTemperatureC,
    required this.avgHumidityPercent,
    required this.avgSeeingArcsec,
    required this.notes,
    required this.errorMessages,
    this.warningMessages = const [],
    this.terminalCause,
    this.rejectFolder,
    required this.generatedAt,
  });

  /// Light frames recorded across all targets, accepted or not.
  int get lightFramesAttempted =>
      targets.fold<int>(0, (sum, t) => sum + t.framesAttempted);

  /// Light frames marked accepted across all targets.
  int get lightFramesAccepted =>
      targets.fold<int>(0, (sum, t) => sum + t.framesAccepted);

  /// Calibration frames recorded, accepted or not.
  int get calibrationFramesAttempted =>
      calibration.fold<int>(0, (sum, c) => sum + c.framesAttempted);

  /// Calibration frames marked accepted.
  int get calibrationFramesAccepted =>
      calibration.fold<int>(0, (sum, c) => sum + c.framesAccepted);

  /// Shutter-open seconds across accepted calibration frames.
  double get calibrationIntegrationSecs =>
      calibration.fold<double>(0.0, (sum, c) => sum + c.totalIntegrationSecs);

  /// EVERY frame the session recorded, lights and calibration alike.
  ///
  /// This counted lights only, which is what let a calibration-only session
  /// report "0/0" beside three FITS files on disk. "Frames" means frames; the
  /// light-only figure is [lightFramesAttempted].
  int get totalFramesAttempted =>
      lightFramesAttempted + calibrationFramesAttempted;

  /// Every accepted frame, lights and calibration alike. See
  /// [totalFramesAttempted].
  int get totalFramesAccepted =>
      lightFramesAccepted + calibrationFramesAccepted;

  /// Sum of `framesRejected` across all targets and calibration types.
  int get totalFramesRejected =>
      targets.fold<int>(0, (sum, t) => sum + t.framesRejected) +
      calibration.fold<int>(0, (sum, c) => sum + c.framesRejected);

  /// True when the report has no recorded frames at all.
  bool get isEmpty => totalFramesAttempted == 0;

  Map<String, dynamic> toJson() => {
    'sessionId': sessionId,
    'sessionName': sessionName,
    'status': status,
    'startTime': startTime.toIso8601String(),
    'endTime': endTime?.toIso8601String(),
    'wallClockSecs': wallClockDuration.inMilliseconds / 1000.0,
    'totalIntegrationSecs': totalIntegration.inMilliseconds / 1000.0,
    'effectiveImagingFraction': effectiveImagingFraction,
    'downtimeSecs': downtime.inMilliseconds / 1000.0,
    'totalFramesAttempted': totalFramesAttempted,
    'totalFramesAccepted': totalFramesAccepted,
    'totalFramesRejected': totalFramesRejected,
    'targets': targets.map((t) => t.toJson()).toList(),
    'calibration': calibration.map((c) => c.toJson()).toList(),
    'lightFramesAttempted': lightFramesAttempted,
    'lightFramesAccepted': lightFramesAccepted,
    'calibrationIntegrationSecs': calibrationIntegrationSecs,
    'guideStats': guideStats.toJson(),
    'mountStats': mountStats.toJson(),
    'avgTemperatureC': avgTemperatureC,
    'avgHumidityPercent': avgHumidityPercent,
    'avgSeeingArcsec': avgSeeingArcsec,
    'notes': notes,
    'errorMessages': errorMessages,
    'warningMessages': warningMessages,
    'generatedAt': generatedAt.toIso8601String(),
  };
}
