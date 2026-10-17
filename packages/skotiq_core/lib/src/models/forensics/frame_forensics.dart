/// Frame-Failure Forensics: Dart-side data model.
///
/// Mirrors the Rust `LikelyCause` enum + the forensic payload that the
/// sequencer attaches to every rejected frame. The wire-stable
/// snake_case labels are the contract between Rust and Dart; see
/// `LikelyCauseExt.fromLabel` for parsing and `.label` for the inverse.
library;

import 'dart:convert';

/// Eight classified rejection causes plus the explicit "we don't know"
/// fallback. The variants line up 1:1 with
/// `skotiq_sequencer::quality::LikelyCause`.
enum LikelyCause {
  cloudPassage,
  seeingSpike,
  guidingFailure,
  windGust,
  satellitePass,
  hotPixelOrCosmic,
  focusDrift,
  unknown,
}

extension LikelyCauseExt on LikelyCause {
  /// Wire-stable snake_case label. Matches the Rust `LikelyCause::label()`
  /// output exactly; persisted in the `frame_forensics.likely_cause`
  /// column and emitted on the `SequencerEvent::FrameRejected` payload.
  String get label {
    switch (this) {
      case LikelyCause.cloudPassage:
        return 'cloud_passage';
      case LikelyCause.seeingSpike:
        return 'seeing_spike';
      case LikelyCause.guidingFailure:
        return 'guiding_failure';
      case LikelyCause.windGust:
        return 'wind_gust';
      case LikelyCause.satellitePass:
        return 'satellite_pass';
      case LikelyCause.hotPixelOrCosmic:
        return 'hot_pixel_or_cosmic';
      case LikelyCause.focusDrift:
        return 'focus_drift';
      case LikelyCause.unknown:
        return 'unknown';
    }
  }

  /// Human-friendly title surfaced in the Forensics panel + Frame
  /// Detail dialog headers.
  String get humanLabel {
    switch (this) {
      case LikelyCause.cloudPassage:
        return 'Cloud passage';
      case LikelyCause.seeingSpike:
        return 'Seeing spike';
      case LikelyCause.guidingFailure:
        return 'Guiding failure';
      case LikelyCause.windGust:
        return 'Wind gust';
      case LikelyCause.satellitePass:
        return 'Satellite / aircraft trail';
      case LikelyCause.hotPixelOrCosmic:
        return 'Hot pixel / cosmic ray';
      case LikelyCause.focusDrift:
        return 'Focus drift';
      case LikelyCause.unknown:
        return 'Unknown';
    }
  }

  /// Parse a wire label back to the enum. Returns `null` when the input
  /// does not match any known variant — callers treat `null` as
  /// equivalent to "classifier did not run", NOT as an alias for
  /// `LikelyCause.unknown` (which is the explicit "we tried but no
  /// signal cleared the heuristics" verdict).
  static LikelyCause? fromLabel(String? label) {
    if (label == null) return null;
    switch (label) {
      case 'cloud_passage':
        return LikelyCause.cloudPassage;
      case 'seeing_spike':
        return LikelyCause.seeingSpike;
      case 'guiding_failure':
        return LikelyCause.guidingFailure;
      case 'wind_gust':
        return LikelyCause.windGust;
      case 'satellite_pass':
        return LikelyCause.satellitePass;
      case 'hot_pixel_or_cosmic':
        return LikelyCause.hotPixelOrCosmic;
      case 'focus_drift':
        return LikelyCause.focusDrift;
      case 'unknown':
        return LikelyCause.unknown;
      default:
        return null;
    }
  }
}

/// Environmental snapshot taken at the instant a frame was captured.
/// Every field is optional because the underlying tracker may not yet
/// have produced a sample. The forensic UI surfaces missing fields as
/// "—" instead of fabricating zeros.
class ForensicEnvironment {
  final double? skyBrightnessMag;
  final double? cloudCoverPercent;
  final double? windKph;
  final double? guideRmsArcsec;
  final double? sensorTempC;

  const ForensicEnvironment({
    this.skyBrightnessMag,
    this.cloudCoverPercent,
    this.windKph,
    this.guideRmsArcsec,
    this.sensorTempC,
  });

  bool get isEmpty =>
      skyBrightnessMag == null &&
      cloudCoverPercent == null &&
      windKph == null &&
      guideRmsArcsec == null &&
      sensorTempC == null;

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (skyBrightnessMag != null) 'sky_brightness_mag': skyBrightnessMag,
    if (cloudCoverPercent != null) 'cloud_cover_percent': cloudCoverPercent,
    if (windKph != null) 'wind_kph': windKph,
    if (guideRmsArcsec != null) 'guide_rms_arcsec': guideRmsArcsec,
    if (sensorTempC != null) 'sensor_temp_c': sensorTempC,
  };

  factory ForensicEnvironment.fromJson(Map<String, dynamic> json) {
    double? asDouble(Object? v) => v == null ? null : (v as num).toDouble();
    return ForensicEnvironment(
      skyBrightnessMag: asDouble(json['sky_brightness_mag']),
      cloudCoverPercent: asDouble(json['cloud_cover_percent']),
      windKph: asDouble(json['wind_kph']),
      guideRmsArcsec: asDouble(json['guide_rms_arcsec']),
      sensorTempC: asDouble(json['sensor_temp_c']),
    );
  }
}

/// Single persisted forensic record. One row per rejected frame.
class FrameForensicsRecord {
  /// UUID — primary key. New records get a freshly minted v4 UUID via
  /// the `uuid` package at insert time.
  final String id;

  /// Soft FK to `captured_images.id`. `null` when the rejected frame
  /// did not have a row in `captured_images` (the FITS may have been
  /// routed to Reject/ without a corresponding capture record).
  final int? capturedImageId;

  /// Drift session identifier (mirrors `captured_images.session_id`).
  final String? sessionId;

  /// `sequence_runs.id` of the active run, when known.
  final int? sequenceRunId;

  /// Sequencer node id that produced the rejected frame.
  final String? nodeId;

  /// 1-based frame index within the burst.
  final int frameIndex;
  final int totalFrames;

  /// On-disk path the rejected FITS was routed to.
  final String rejectPath;

  /// Grader-provided reason string (HFR-over-threshold, etc.).
  final String reason;

  /// Classified cause. Never `null` after persistence — the column has
  /// a NOT NULL DEFAULT of `'unknown'`. Use [LikelyCauseExt.fromLabel]
  /// on the raw wire label to construct.
  final LikelyCause likelyCause;

  /// Ordered evidence bullets. Empty list when the classifier produced
  /// no signals (rare — the analyzer always emits at least the
  /// raw-metric bullets).
  final List<String> evidence;

  /// Environment snapshot from the moment of capture.
  final ForensicEnvironment environment;

  /// Frame metrics measured by the grader.
  final double? hfr;
  final double? eccentricity;
  final int? starCount;

  /// Wall-clock at which the forensic record was inserted (unix
  /// epoch milliseconds).
  final DateTime createdAt;

  const FrameForensicsRecord({
    required this.id,
    required this.capturedImageId,
    required this.sessionId,
    required this.sequenceRunId,
    required this.nodeId,
    required this.frameIndex,
    required this.totalFrames,
    required this.rejectPath,
    required this.reason,
    required this.likelyCause,
    required this.evidence,
    required this.environment,
    required this.hfr,
    required this.eccentricity,
    required this.starCount,
    required this.createdAt,
  });

  /// Build a record from a raw drift row map (used by the DAO).
  factory FrameForensicsRecord.fromRow(Map<String, Object?> row) {
    final evidenceRaw = (row['evidence_json'] as String?) ?? '[]';
    final envRaw = (row['environment_json'] as String?) ?? '{}';
    return FrameForensicsRecord(
      id: row['id'] as String,
      capturedImageId: row['captured_image_id'] as int?,
      sessionId: row['session_id'] as String?,
      sequenceRunId: row['sequence_run_id'] as int?,
      nodeId: row['node_id'] as String?,
      frameIndex: (row['frame_index'] as int?) ?? 0,
      totalFrames: (row['total_frames'] as int?) ?? 0,
      rejectPath: (row['reject_path'] as String?) ?? '',
      reason: (row['reason'] as String?) ?? '',
      likelyCause:
          LikelyCauseExt.fromLabel(row['likely_cause'] as String?) ??
          LikelyCause.unknown,
      evidence: List<String>.from(
        (jsonDecode(evidenceRaw) as List<dynamic>).map((e) => e as String),
      ),
      environment: ForensicEnvironment.fromJson(
        jsonDecode(envRaw) as Map<String, dynamic>,
      ),
      hfr: (row['hfr'] as num?)?.toDouble(),
      eccentricity: (row['eccentricity'] as num?)?.toDouble(),
      starCount: row['star_count'] as int?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        ((row['created_at'] as int?) ?? 0) * 1000,
      ),
    );
  }
}

/// Aggregated summary of forensic records grouped by cause — used by
/// the post-session report ("Out of 12 rejections, 9 were
/// CloudPassage...").
class ForensicSummary {
  /// Map of [LikelyCause] -> count of records.
  final Map<LikelyCause, int> countsByCause;

  /// Total records contributing to this summary.
  final int total;

  /// Earliest record time in the bucket.
  final DateTime? firstAt;

  /// Latest record time in the bucket.
  final DateTime? lastAt;

  const ForensicSummary({
    required this.countsByCause,
    required this.total,
    required this.firstAt,
    required this.lastAt,
  });

  /// Causes ordered by descending count — the "most common cause" first.
  List<MapEntry<LikelyCause, int>> get rankedCauses {
    final entries = countsByCause.entries.where((e) => e.value > 0).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries;
  }

  /// Returns true when no rejections were recorded — UI hides the panel
  /// in that case rather than rendering an empty "0 of 0" header.
  bool get isEmpty => total == 0;
}
