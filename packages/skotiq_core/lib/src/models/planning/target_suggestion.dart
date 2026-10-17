import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

part 'target_suggestion.freezed.dart';
part 'target_suggestion.g.dart';

/// How to sort target suggestions
enum SuggestionSortMode {
  /// Sort by overall score (highest first)
  bestScore,

  /// Sort by current altitude (highest first)
  highestAltitude,

  /// Sort by proximity to transit (closest first)
  nearestTransit,

  /// Sort by data collected (least first, prioritize incomplete targets)
  leastDataCollected,
}

/// JSON converter for TargetWarning from skotiq_planetarium
class TargetWarningConverter
    implements JsonConverter<TargetWarning, Map<String, dynamic>> {
  const TargetWarningConverter();

  @override
  TargetWarning fromJson(Map<String, dynamic> json) {
    return TargetWarning(
      type: WarningType.values.byName(json['type'] as String),
      severity: WarningSeverity.values.byName(json['severity'] as String),
      message: json['message'] as String,
      suggestion: json['suggestion'] as String?,
    );
  }

  @override
  Map<String, dynamic> toJson(TargetWarning object) {
    return {
      'type': object.type.name,
      'severity': object.severity.name,
      'message': object.message,
      'suggestion': object.suggestion,
    };
  }
}

/// JSON converter for `List<TargetWarning>`
class TargetWarningListConverter
    implements JsonConverter<List<TargetWarning>, List<dynamic>> {
  const TargetWarningListConverter();

  @override
  List<TargetWarning> fromJson(List<dynamic> json) {
    const converter = TargetWarningConverter();
    return json
        .map((e) => converter.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  List<dynamic> toJson(List<TargetWarning> object) {
    const converter = TargetWarningConverter();
    return object.map((e) => converter.toJson(e)).toList();
  }
}

/// JSON converter for TargetVisibilityInfo from skotiq_planetarium
class TargetVisibilityInfoConverter
    implements JsonConverter<TargetVisibilityInfo, Map<String, dynamic>> {
  const TargetVisibilityInfoConverter();

  @override
  TargetVisibilityInfo fromJson(Map<String, dynamic> json) {
    return TargetVisibilityInfo(
      currentAltitude: (json['currentAltitude'] as num).toDouble(),
      currentAzimuth: (json['currentAzimuth'] as num).toDouble(),
      transitAltitude: json['transitAltitude'] != null
          ? (json['transitAltitude'] as num).toDouble()
          : null,
      riseTime: json['riseTime'] != null
          ? DateTime.parse(json['riseTime'] as String)
          : null,
      transitTime: json['transitTime'] != null
          ? DateTime.parse(json['transitTime'] as String)
          : null,
      setTime: json['setTime'] != null
          ? DateTime.parse(json['setTime'] as String)
          : null,
      isCircumpolar: json['isCircumpolar'] as bool? ?? false,
      neverRises: json['neverRises'] as bool? ?? false,
      airmass: (json['airmass'] as num).toDouble(),
      moonDistance: (json['moonDistance'] as num).toDouble(),
      peakAltitude: json['peakAltitude'] != null
          ? (json['peakAltitude'] as num).toDouble()
          : null,
      peakAltitudeTime: json['peakAltitudeTime'] != null
          ? DateTime.parse(json['peakAltitudeTime'] as String)
          : null,
      hoursAboveMinAlt: json['hoursAboveMinAlt'] != null
          ? (json['hoursAboveMinAlt'] as num).toDouble()
          : null,
    );
  }

  @override
  Map<String, dynamic> toJson(TargetVisibilityInfo object) {
    return {
      'currentAltitude': object.currentAltitude,
      'currentAzimuth': object.currentAzimuth,
      'transitAltitude': object.transitAltitude,
      'riseTime': object.riseTime?.toIso8601String(),
      'transitTime': object.transitTime?.toIso8601String(),
      'setTime': object.setTime?.toIso8601String(),
      'isCircumpolar': object.isCircumpolar,
      'neverRises': object.neverRises,
      'airmass': object.airmass,
      'moonDistance': object.moonDistance,
      'peakAltitude': object.peakAltitude,
      'peakAltitudeTime': object.peakAltitudeTime?.toIso8601String(),
      'hoursAboveMinAlt': object.hoursAboveMinAlt,
    };
  }
}

/// A suggested target with scoring and analysis information
@freezed
abstract class TargetSuggestion with _$TargetSuggestion {
  const factory TargetSuggestion({
    /// Database target ID
    required int targetId,

    /// Display name of the target
    required String targetName,

    /// Catalog identifier (e.g., "NGC 7000", "M31")
    String? catalogId,

    /// Right Ascension in hours (0-24)
    required double raHours,

    /// Declination in degrees (-90 to +90)
    required double decDegrees,

    /// Overall score from 0-100
    required double totalScore,

    /// Breakdown of individual score components
    /// Keys: altitude, moonDistance, transitProximity, darkness, airmass
    @Default(<String, double>{}) Map<String, double> scoreBreakdown,

    /// Warnings about target conditions
    @TargetWarningListConverter()
    @Default(<TargetWarning>[])
    List<TargetWarning> warnings,

    /// Visibility information for this target
    @TargetVisibilityInfoConverter() required TargetVisibilityInfo visibility,

    /// Human-readable explanation of why this target is suggested
    @Default('') String reasoning,

    /// Progress of data collection for this target (0.0 to 1.0)
    /// 0.0 = no data collected, 1.0 = fully complete
    @Default(0.0) double dataProgress,

    /// Object type (e.g., "Galaxy", "Emission Nebula", "Open Cluster")
    String? objectType,

    /// Visual magnitude
    double? magnitude,

    /// Angular size in arcminutes
    double? sizeArcmin,

    /// Constellation abbreviation
    String? constellation,

    /// Informational tags (e.g., "Mosaic recommended")
    @Default(<String>[]) List<String> tags,
  }) = _TargetSuggestion;

  factory TargetSuggestion.fromJson(Map<String, dynamic> json) =>
      _$TargetSuggestionFromJson(json);
}

/// Configuration for target suggestion generation
@freezed
abstract class TargetSuggestionConfig with _$TargetSuggestionConfig {
  const factory TargetSuggestionConfig({
    /// Minimum altitude in degrees for targets to be considered
    @Default(30.0) double minAltitude,

    /// Maximum distance from moon in degrees (null = no limit)
    double? maxMoonDistance,

    /// Preferred object types to prioritize (e.g., ["Galaxy", "Nebula"])
    @Default(<String>[]) List<String> preferredObjectTypes,

    /// Whether to prioritize targets that need more data
    @Default(true) bool prioritizeIncomplete,

    /// Minimum score (0-100) for a target to be suggested
    @Default(50.0) double minScore,

    /// How to sort the suggestions
    @Default(SuggestionSortMode.bestScore) SuggestionSortMode sortMode,
  }) = _TargetSuggestionConfig;

  factory TargetSuggestionConfig.fromJson(Map<String, dynamic> json) =>
      _$TargetSuggestionConfigFromJson(json);
}
