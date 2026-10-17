// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'target_suggestion.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_TargetSuggestion _$TargetSuggestionFromJson(Map<String, dynamic> json) =>
    _TargetSuggestion(
      targetId: (json['targetId'] as num).toInt(),
      targetName: json['targetName'] as String,
      catalogId: json['catalogId'] as String?,
      raHours: (json['raHours'] as num).toDouble(),
      decDegrees: (json['decDegrees'] as num).toDouble(),
      totalScore: (json['totalScore'] as num).toDouble(),
      scoreBreakdown:
          (json['scoreBreakdown'] as Map<String, dynamic>?)?.map(
            (k, e) => MapEntry(k, (e as num).toDouble()),
          ) ??
          const <String, double>{},
      warnings: json['warnings'] == null
          ? const <TargetWarning>[]
          : const TargetWarningListConverter().fromJson(
              json['warnings'] as List,
            ),
      visibility: const TargetVisibilityInfoConverter().fromJson(
        json['visibility'] as Map<String, dynamic>,
      ),
      reasoning: json['reasoning'] as String? ?? '',
      dataProgress: (json['dataProgress'] as num?)?.toDouble() ?? 0.0,
      objectType: json['objectType'] as String?,
      magnitude: (json['magnitude'] as num?)?.toDouble(),
      sizeArcmin: (json['sizeArcmin'] as num?)?.toDouble(),
      constellation: json['constellation'] as String?,
      tags:
          (json['tags'] as List<dynamic>?)?.map((e) => e as String).toList() ??
          const <String>[],
    );

Map<String, dynamic> _$TargetSuggestionToJson(_TargetSuggestion instance) =>
    <String, dynamic>{
      'targetId': instance.targetId,
      'targetName': instance.targetName,
      'catalogId': instance.catalogId,
      'raHours': instance.raHours,
      'decDegrees': instance.decDegrees,
      'totalScore': instance.totalScore,
      'scoreBreakdown': instance.scoreBreakdown,
      'warnings': const TargetWarningListConverter().toJson(instance.warnings),
      'visibility': const TargetVisibilityInfoConverter().toJson(
        instance.visibility,
      ),
      'reasoning': instance.reasoning,
      'dataProgress': instance.dataProgress,
      'objectType': instance.objectType,
      'magnitude': instance.magnitude,
      'sizeArcmin': instance.sizeArcmin,
      'constellation': instance.constellation,
      'tags': instance.tags,
    };

_TargetSuggestionConfig _$TargetSuggestionConfigFromJson(
  Map<String, dynamic> json,
) => _TargetSuggestionConfig(
  minAltitude: (json['minAltitude'] as num?)?.toDouble() ?? 30.0,
  maxMoonDistance: (json['maxMoonDistance'] as num?)?.toDouble(),
  preferredObjectTypes:
      (json['preferredObjectTypes'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList() ??
      const <String>[],
  prioritizeIncomplete: json['prioritizeIncomplete'] as bool? ?? true,
  minScore: (json['minScore'] as num?)?.toDouble() ?? 50.0,
  sortMode:
      $enumDecodeNullable(_$SuggestionSortModeEnumMap, json['sortMode']) ??
      SuggestionSortMode.bestScore,
);

Map<String, dynamic> _$TargetSuggestionConfigToJson(
  _TargetSuggestionConfig instance,
) => <String, dynamic>{
  'minAltitude': instance.minAltitude,
  'maxMoonDistance': instance.maxMoonDistance,
  'preferredObjectTypes': instance.preferredObjectTypes,
  'prioritizeIncomplete': instance.prioritizeIncomplete,
  'minScore': instance.minScore,
  'sortMode': _$SuggestionSortModeEnumMap[instance.sortMode]!,
};

const _$SuggestionSortModeEnumMap = {
  SuggestionSortMode.bestScore: 'bestScore',
  SuggestionSortMode.highestAltitude: 'highestAltitude',
  SuggestionSortMode.nearestTransit: 'nearestTransit',
  SuggestionSortMode.leastDataCollected: 'leastDataCollected',
};
