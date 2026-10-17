// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'auto_stretch_settings.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_AutoStretchSettings _$AutoStretchSettingsFromJson(Map<String, dynamic> json) =>
    _AutoStretchSettings(
      enabled: json['enabled'] as bool? ?? false,
      method:
          $enumDecodeNullable(_$AutoStretchMethodEnumMap, json['method']) ??
          AutoStretchMethod.stf,
      shadowClip: (json['shadowClip'] as num?)?.toDouble() ?? -2.8,
      highlightClip: (json['highlightClip'] as num?)?.toDouble() ?? -0.5,
      targetMedian: (json['targetMedian'] as num?)?.toDouble() ?? 0.25,
      linkedChannels: json['linkedChannels'] as bool? ?? true,
      gammaValue: (json['gammaValue'] as num?)?.toDouble() ?? 2.2,
    );

Map<String, dynamic> _$AutoStretchSettingsToJson(
  _AutoStretchSettings instance,
) => <String, dynamic>{
  'enabled': instance.enabled,
  'method': _$AutoStretchMethodEnumMap[instance.method]!,
  'shadowClip': instance.shadowClip,
  'highlightClip': instance.highlightClip,
  'targetMedian': instance.targetMedian,
  'linkedChannels': instance.linkedChannels,
  'gammaValue': instance.gammaValue,
};

const _$AutoStretchMethodEnumMap = {
  AutoStretchMethod.stf: 'stf',
  AutoStretchMethod.histogram: 'histogram',
  AutoStretchMethod.asinh: 'asinh',
  AutoStretchMethod.log: 'log',
  AutoStretchMethod.gamma: 'gamma',
};
