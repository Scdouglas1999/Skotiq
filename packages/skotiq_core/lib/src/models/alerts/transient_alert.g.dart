// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'transient_alert.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_TransientAlert _$TransientAlertFromJson(Map<String, dynamic> json) =>
    _TransientAlert(
      id: json['id'] as String,
      name: json['name'] as String,
      type: $enumDecode(_$TransientTypeEnumMap, json['type']),
      raHours: (json['raHours'] as num).toDouble(),
      decDegrees: (json['decDegrees'] as num).toDouble(),
      magnitude: (json['magnitude'] as num?)?.toDouble(),
      peakMagnitude: (json['peakMagnitude'] as num?)?.toDouble(),
      discoveryTime: DateTime.parse(json['discoveryTime'] as String),
      lastUpdated: DateTime.parse(json['lastUpdated'] as String),
      source: $enumDecode(_$TransientSourceEnumMap, json['source']),
      sourceUrl: json['sourceUrl'] as String?,
      priority: (json['priority'] as num?)?.toInt() ?? 5,
      notes: json['notes'] as String?,
      classification: json['classification'] as String?,
      state:
          $enumDecodeNullable(_$TransientAlertStateEnumMap, json['state']) ??
          TransientAlertState.newAlert,
    );

Map<String, dynamic> _$TransientAlertToJson(_TransientAlert instance) =>
    <String, dynamic>{
      'id': instance.id,
      'name': instance.name,
      'type': _$TransientTypeEnumMap[instance.type]!,
      'raHours': instance.raHours,
      'decDegrees': instance.decDegrees,
      'magnitude': instance.magnitude,
      'peakMagnitude': instance.peakMagnitude,
      'discoveryTime': instance.discoveryTime.toIso8601String(),
      'lastUpdated': instance.lastUpdated.toIso8601String(),
      'source': _$TransientSourceEnumMap[instance.source]!,
      'sourceUrl': instance.sourceUrl,
      'priority': instance.priority,
      'notes': instance.notes,
      'classification': instance.classification,
      'state': _$TransientAlertStateEnumMap[instance.state]!,
    };

const _$TransientTypeEnumMap = {
  TransientType.nova: 'nova',
  TransientType.supernova: 'supernova',
  TransientType.cataclysmic: 'cataclysmic',
  TransientType.comet: 'comet',
  TransientType.asteroid: 'asteroid',
  TransientType.variableStar: 'variableStar',
  TransientType.gammaRayBurst: 'gammaRayBurst',
  TransientType.other: 'other',
};

const _$TransientSourceEnumMap = {
  TransientSource.aavso: 'aavso',
  TransientSource.tns: 'tns',
  TransientSource.mpec: 'mpec',
  TransientSource.cbat: 'cbat',
  TransientSource.manual: 'manual',
};

const _$TransientAlertStateEnumMap = {
  TransientAlertState.newAlert: 'newAlert',
  TransientAlertState.acknowledged: 'acknowledged',
  TransientAlertState.queued: 'queued',
  TransientAlertState.observed: 'observed',
  TransientAlertState.dismissed: 'dismissed',
};

_TransientAlertSettings _$TransientAlertSettingsFromJson(
  Map<String, dynamic> json,
) => _TransientAlertSettings(
  enabledSources:
      (json['enabledSources'] as List<dynamic>?)
          ?.map((e) => $enumDecode(_$TransientSourceEnumMap, e))
          .toSet() ??
      const {TransientSource.tns, TransientSource.manual},
  magnitudeThreshold: (json['magnitudeThreshold'] as num?)?.toDouble() ?? 15.0,
  typesToMonitor:
      (json['typesToMonitor'] as List<dynamic>?)
          ?.map((e) => $enumDecode(_$TransientTypeEnumMap, e))
          .toSet() ??
      const {
        TransientType.nova,
        TransientType.supernova,
        TransientType.cataclysmic,
        TransientType.comet,
        TransientType.asteroid,
        TransientType.variableStar,
        TransientType.gammaRayBurst,
        TransientType.other,
      },
  notifyOnNew: json['notifyOnNew'] as bool? ?? true,
  autoQueueBright: json['autoQueueBright'] as bool? ?? false,
  autoQueueMagnitude: (json['autoQueueMagnitude'] as num?)?.toDouble() ?? 10.0,
  tnsApiKey: json['tnsApiKey'] as String?,
);

Map<String, dynamic> _$TransientAlertSettingsToJson(
  _TransientAlertSettings instance,
) => <String, dynamic>{
  'enabledSources': instance.enabledSources
      .map((e) => _$TransientSourceEnumMap[e]!)
      .toList(),
  'magnitudeThreshold': instance.magnitudeThreshold,
  'typesToMonitor': instance.typesToMonitor
      .map((e) => _$TransientTypeEnumMap[e]!)
      .toList(),
  'notifyOnNew': instance.notifyOnNew,
  'autoQueueBright': instance.autoQueueBright,
  'autoQueueMagnitude': instance.autoQueueMagnitude,
  'tnsApiKey': instance.tnsApiKey,
};
