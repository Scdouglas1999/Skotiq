// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'weather_settings.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_WeatherSettings _$WeatherSettingsFromJson(
  Map<String, dynamic> json,
) => _WeatherSettings(
  triggerDistanceKm: (json['triggerDistanceKm'] as num?)?.toDouble() ?? 30.0,
  cloudDensityThreshold:
      (json['cloudDensityThreshold'] as num?)?.toDouble() ?? 60.0,
  leadTimeMinutes: (json['leadTimeMinutes'] as num?)?.toInt() ?? 15,
  weatherSafetyEnabled: json['weatherSafetyEnabled'] as bool? ?? false,
  maxHumidityPercent: (json['maxHumidityPercent'] as num?)?.toDouble() ?? 90.0,
  maxWindSpeedKph: (json['maxWindSpeedKph'] as num?)?.toDouble() ?? 30.0,
  maxCloudCoverPercent:
      (json['maxCloudCoverPercent'] as num?)?.toDouble() ?? 80.0,
  autoParkEnabled: json['autoParkEnabled'] as bool? ?? true,
  autoResumeEnabled: json['autoResumeEnabled'] as bool? ?? false,
  preferredProvider:
      $enumDecodeNullable(
        _$RadarProviderTypeEnumMap,
        json['preferredProvider'],
      ) ??
      RadarProviderType.auto,
  refreshIntervalSeconds:
      (json['refreshIntervalSeconds'] as num?)?.toInt() ?? 300,
);

Map<String, dynamic> _$WeatherSettingsToJson(
  _WeatherSettings instance,
) => <String, dynamic>{
  'triggerDistanceKm': instance.triggerDistanceKm,
  'cloudDensityThreshold': instance.cloudDensityThreshold,
  'leadTimeMinutes': instance.leadTimeMinutes,
  'weatherSafetyEnabled': instance.weatherSafetyEnabled,
  'maxHumidityPercent': instance.maxHumidityPercent,
  'maxWindSpeedKph': instance.maxWindSpeedKph,
  'maxCloudCoverPercent': instance.maxCloudCoverPercent,
  'autoParkEnabled': instance.autoParkEnabled,
  'autoResumeEnabled': instance.autoResumeEnabled,
  'preferredProvider': _$RadarProviderTypeEnumMap[instance.preferredProvider]!,
  'refreshIntervalSeconds': instance.refreshIntervalSeconds,
};

const _$RadarProviderTypeEnumMap = {
  RadarProviderType.auto: 'auto',
  RadarProviderType.goesSatellite: 'goesSatellite',
  RadarProviderType.noaa: 'noaa',
  RadarProviderType.rainviewer: 'rainviewer',
  RadarProviderType.openmeteo: 'openmeteo',
  RadarProviderType.metno: 'metno',
};
