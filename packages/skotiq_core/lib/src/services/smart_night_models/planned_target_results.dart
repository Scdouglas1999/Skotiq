part of '../smart_night_models.dart';

/// One target placed onto the night's tree — captured here so the wizard
/// preview can render a Gantt-style timeline without re-running the
/// scoring pipeline.
class SmartNightPlannedTarget {
  final TargetSuggestion suggestion;

  /// Wall-clock start/end inside the dark window — clipped by the
  /// scheduler so transitions between targets don't overlap.
  final DateTime windowStart;
  final DateTime windowEnd;

  /// Per-filter exposure plan (count + duration + rationale).
  final List<SmartNightFilterPlan> filterPlans;

  /// Total integration for this target across all filters (seconds).
  final double integrationSecs;

  /// Rationale string surfaced to the user: `"Picked because (reason)"`.
  final String rationale;

  /// True when this target plans a single unfiltered row — the rig has no
  /// filter wheel, so the emitted sub-tree captures with no filter selection
  /// instead of rotating one.
  bool get isUnfiltered =>
      filterPlans.length == 1 && filterPlans.single.isUnfiltered;

  const SmartNightPlannedTarget({
    required this.suggestion,
    required this.windowStart,
    required this.windowEnd,
    required this.filterPlans,
    required this.integrationSecs,
    required this.rationale,
  });

  Map<String, dynamic> toJson() => {
    'suggestion': suggestion.toJson(),
    'windowStart': windowStart.toIso8601String(),
    'windowEnd': windowEnd.toIso8601String(),
    'filterPlans': filterPlans.map((p) => p.toJson()).toList(),
    'integrationSecs': integrationSecs,
    'rationale': rationale,
  };

  factory SmartNightPlannedTarget.fromJson(Map<String, dynamic> json) {
    return SmartNightPlannedTarget(
      suggestion: TargetSuggestion.fromJson(
        (json['suggestion'] as Map).cast<String, dynamic>(),
      ),
      windowStart: DateTime.parse(json['windowStart'] as String),
      windowEnd: DateTime.parse(json['windowEnd'] as String),
      filterPlans: (json['filterPlans'] as List? ?? const [])
          .map(
            (e) => SmartNightFilterPlan.fromJson(
              (e as Map).cast<String, dynamic>(),
            ),
          )
          .toList(),
      integrationSecs: _jsonDouble(json['integrationSecs'], 0.0),
      rationale: json['rationale'] as String? ?? '',
    );
  }
}

/// One filter row inside a planned target. Maps 1:1 to a [FilterPlan]
/// on the emitted [SmartExposureNode].
class SmartNightFilterPlan {
  final String filterName;
  final int count;
  final double durationSecs;
  final ExposureRecommendation? recommendation;

  const SmartNightFilterPlan({
    required this.filterName,
    required this.count,
    required this.durationSecs,
    this.recommendation,
  });

  double get integrationSecs => count * durationSecs;

  /// True when this row carries no filter selection. Emitted as an
  /// [ExposureNode] with a null `filter`, never as a filter change.
  bool get isUnfiltered => filterName.trim().isEmpty;

  Map<String, dynamic> toJson() => {
    'filterName': filterName,
    'count': count,
    'durationSecs': durationSecs,
    'recommendation': _recommendationToJson(recommendation),
  };

  factory SmartNightFilterPlan.fromJson(Map<String, dynamic> json) {
    return SmartNightFilterPlan(
      filterName: json['filterName'] as String? ?? 'L',
      count: _jsonInt(json['count'], 0),
      durationSecs: _jsonDouble(json['durationSecs'], 0.0),
      recommendation: _recommendationFromJson(json['recommendation']),
    );
  }
}

/// Result of [SmartNightService.buildSingleTargetSequence].
class SingleTargetSequenceResult {
  final Sequence sequence;
  final SmartNightStrategy strategy;
  final List<SmartNightFilterPlan> filterPlans;
  final SmartNightPlannedTarget plannedTarget;

  const SingleTargetSequenceResult({
    required this.sequence,
    required this.strategy,
    required this.filterPlans,
    required this.plannedTarget,
  });
}

/// Filter-aware integration estimate for Plan Tonight list rows.
class TargetIntegrationPreview {
  /// Total light-frame integration (all filters) that fits the window.
  final double estimatedIntegrationHours;

  /// Hours the target is above [SmartNightSettings.minAltitudeDeg] tonight.
  final double usableWindowHours;

  /// Representative sub-exposure length from the exposure calculator.
  final double subExposureSecs;

  /// Filters included in the estimate (strategy + equipment profile).
  final List<String> filterNames;

  const TargetIntegrationPreview({
    required this.estimatedIntegrationHours,
    required this.usableWindowHours,
    required this.subExposureSecs,
    required this.filterNames,
  });
}

/// Errors the builder throws when an input is missing or invalid. The wizard
/// catches these and surfaces them as blocking error states rather than
/// skipping the rule.
class SmartNightBuildException implements Exception {
  final String message;
  const SmartNightBuildException(this.message);
  @override
  String toString() => 'SmartNightBuildException: $message';
}
