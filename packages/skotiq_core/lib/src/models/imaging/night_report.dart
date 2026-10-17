import 'dart:convert';

/// Severity of a single [NightFinding] surfaced by the Night Doctor.
///
/// Ordered least→most urgent so the report view can rank findings and pick the
/// dominant badge colour for the headline.
enum NightFindingSeverity {
  /// Informational — a neutral observation about the night, no action needed.
  info,

  /// A degradation worth knowing about (e.g. focus drift, a guiding spike).
  warn,

  /// A serious problem that likely cost frames (e.g. clouds, a dew collapse).
  critical;

  String get wire {
    switch (this) {
      case NightFindingSeverity.info:
        return 'info';
      case NightFindingSeverity.warn:
        return 'warn';
      case NightFindingSeverity.critical:
        return 'critical';
    }
  }

  static NightFindingSeverity fromWire(String value) {
    switch (value) {
      case 'warn':
        return NightFindingSeverity.warn;
      case 'critical':
        return NightFindingSeverity.critical;
      case 'info':
      default:
        // Unknown persisted value forward-migrates to the safe lowest severity
        // rather than throwing on read.
        return NightFindingSeverity.info;
    }
  }
}

/// One diagnostic finding from the Night Doctor — a single named problem (or
/// positive observation) with a plain-language explanation, the subs that
/// evidence it, and actionable advice.
///
/// Immutable value type with value equality and JSON round-tripping, matching
/// `integration_settings.dart`.
class NightFinding {
  /// Stable detector id (e.g. `'focus_drift'`), used for dedup + UI keys.
  final String id;
  final NightFindingSeverity severity;
  final String title;
  final String explanation;

  /// `captured_images.id` of the subs that evidence this finding.
  final List<int> evidenceSubIds;
  final String advice;

  /// Optional metric time series backing the finding (e.g. HFR-vs-time), used
  /// by the report view to draw the inline sparkline. Null when the detector
  /// has no series to show.
  final List<double>? metricSeries;

  const NightFinding({
    required this.id,
    required this.severity,
    required this.title,
    required this.explanation,
    this.evidenceSubIds = const [],
    this.advice = '',
    this.metricSeries,
  });

  NightFinding copyWith({
    String? id,
    NightFindingSeverity? severity,
    String? title,
    String? explanation,
    List<int>? evidenceSubIds,
    String? advice,
    List<double>? metricSeries,
  }) {
    return NightFinding(
      id: id ?? this.id,
      severity: severity ?? this.severity,
      title: title ?? this.title,
      explanation: explanation ?? this.explanation,
      evidenceSubIds: evidenceSubIds ?? this.evidenceSubIds,
      advice: advice ?? this.advice,
      metricSeries: metricSeries ?? this.metricSeries,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'severity': severity.wire,
      'title': title,
      'explanation': explanation,
      'evidenceSubIds': evidenceSubIds,
      'advice': advice,
      if (metricSeries != null) 'metricSeries': metricSeries,
    };
  }

  /// Inverse of [toJson]. Decodes defensively: missing/typo'd keys fall back to
  /// empty defaults rather than throwing, so an older persisted blob (or a
  /// native payload with an extra field) forward-migrates without error.
  factory NightFinding.fromJson(Map<String, dynamic> json) {
    return NightFinding(
      id: json['id'] as String? ?? '',
      severity: json['severity'] is String
          ? NightFindingSeverity.fromWire(json['severity'] as String)
          : NightFindingSeverity.info,
      title: json['title'] as String? ?? '',
      explanation: json['explanation'] as String? ?? '',
      evidenceSubIds: _intList(json['evidenceSubIds']),
      advice: json['advice'] as String? ?? '',
      metricSeries: json['metricSeries'] == null
          ? null
          : _doubleList(json['metricSeries']),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NightFinding &&
          other.id == id &&
          other.severity == severity &&
          other.title == title &&
          other.explanation == explanation &&
          _listEquals(other.evidenceSubIds, evidenceSubIds) &&
          other.advice == advice &&
          _listEquals(other.metricSeries, metricSeries);

  @override
  int get hashCode => Object.hash(
    id,
    severity,
    title,
    explanation,
    Object.hashAll(evidenceSubIds),
    advice,
    metricSeries == null ? null : Object.hashAll(metricSeries!),
  );
}

/// The Night Doctor's report for one session (and/or target): an overall
/// quality [score] (0..100), a one-line [headline], and the ranked
/// [findings].
///
/// This is the Dart mirror of the raw-DDL `night_reports` row (see
/// `database/tables/post_session_tables.dart`). [sessionId] / [targetId] are
/// nullable so a report can be attached to a session, a target, or both.
class NightReport {
  final int? sessionId;
  final int? targetId;

  /// Overall night quality, 0..100 — or [ungradedScore] when the night could
  /// not be graded at all. Read [graded] before showing this number.
  final int score;
  final String headline;
  final List<NightFinding> findings;
  final DateTime createdAt;

  /// Sentinel [score] for a night the Night Doctor could not grade: no light
  /// frames, too few to judge, or frames carrying no quality metrics.
  ///
  /// The score is a DEGRADATION score — it starts at 100 and only subtracts
  /// per-finding penalties — so a night with nothing to analyse scores a
  /// perfect 100 unless it carries this sentinel instead. The UI must render
  /// it as "Not graded", never as a number.
  ///
  /// It is deliberately outside 0..100 so it survives the `night_reports.score`
  /// round-trip (an `INTEGER NOT NULL` column) with no schema migration.
  static const int ungradedScore = -1;

  /// Whether [score] is a real grade. False for an un-gradable night (see
  /// [ungradedScore]); the UI must then present "Not graded" and never a ring,
  /// number or grade word.
  bool get graded => score >= 0;

  const NightReport({
    this.sessionId,
    this.targetId,
    required this.score,
    required this.headline,
    this.findings = const [],
    required this.createdAt,
  });

  /// A report for a night that could not be graded: [headline] states why, and
  /// [score] is [ungradedScore] so no surface can print a flattering number.
  const NightReport.ungraded({
    this.sessionId,
    this.targetId,
    required this.headline,
    this.findings = const [],
    required this.createdAt,
  }) : score = ungradedScore;

  NightReport copyWith({
    int? sessionId,
    int? targetId,
    int? score,
    String? headline,
    List<NightFinding>? findings,
    DateTime? createdAt,
  }) {
    return NightReport(
      sessionId: sessionId ?? this.sessionId,
      targetId: targetId ?? this.targetId,
      score: score ?? this.score,
      headline: headline ?? this.headline,
      findings: findings ?? this.findings,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (sessionId != null) 'sessionId': sessionId,
      if (targetId != null) 'targetId': targetId,
      'score': score,
      'headline': headline,
      'findings': findings.map((f) => f.toJson()).toList(),
      'createdAt': createdAt.toUtc().toIso8601String(),
    };
  }

  /// Inverse of [toJson]; decodes defensively.
  factory NightReport.fromJson(Map<String, dynamic> json) {
    return NightReport(
      sessionId: (json['sessionId'] as num?)?.toInt(),
      targetId: (json['targetId'] as num?)?.toInt(),
      // A blob with no score is a blob with no grade — decode it as un-graded
      // rather than as a real (and very bad) 0.
      score: (json['score'] as num?)?.toInt() ?? ungradedScore,
      headline: json['headline'] as String? ?? '',
      findings: json['findings'] is List
          ? (json['findings'] as List)
                .whereType<Map>()
                .map((e) => NightFinding.fromJson(Map<String, dynamic>.from(e)))
                .toList()
          : const [],
      createdAt: _parseDate(json['createdAt']),
    );
  }

  /// Decode a `findings_json` column value (a JSON array of [NightFinding]).
  /// Returns an empty list for null / blank / corrupt input rather than
  /// throwing — a stored-report read should never crash the review screen.
  static List<NightFinding> decodeFindings(String? source) {
    if (source == null || source.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(source);
      if (decoded is List) {
        return decoded
            .whereType<Map>()
            .map((e) => NightFinding.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      }
    } catch (_) {
      // Fall through to empty on any decode/parse error.
    }
    return const [];
  }

  /// Encode [findings] as a `findings_json` column value.
  static String encodeFindings(List<NightFinding> findings) =>
      jsonEncode(findings.map((f) => f.toJson()).toList());

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NightReport &&
          other.sessionId == sessionId &&
          other.targetId == targetId &&
          other.score == score &&
          other.headline == headline &&
          _listEquals(other.findings, findings) &&
          other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(
    sessionId,
    targetId,
    score,
    headline,
    Object.hashAll(findings),
    createdAt,
  );
}

List<int> _intList(Object? value) {
  if (value is! List) return const [];
  return value.whereType<num>().map((n) => n.toInt()).toList();
}

List<double> _doubleList(Object? value) {
  if (value is! List) return const [];
  return value.whereType<num>().map((n) => n.toDouble()).toList();
}

DateTime _parseDate(Object? value) {
  if (value is String) {
    return DateTime.tryParse(value)?.toUtc() ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  }
  if (value is num) {
    return DateTime.fromMillisecondsSinceEpoch(
      value.toInt() * 1000,
      isUtc: true,
    );
  }
  return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
}

bool _listEquals<T>(List<T>? a, List<T>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
