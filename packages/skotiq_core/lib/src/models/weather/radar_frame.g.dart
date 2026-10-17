// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'radar_frame.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_RadarFrame _$RadarFrameFromJson(Map<String, dynamic> json) => _RadarFrame(
  timestamp: DateTime.parse(json['timestamp'] as String),
  tileUrlTemplate: json['tileUrlTemplate'] as String,
  north: (json['north'] as num).toDouble(),
  south: (json['south'] as num).toDouble(),
  east: (json['east'] as num).toDouble(),
  west: (json['west'] as num).toDouble(),
  opacity: (json['opacity'] as num?)?.toDouble() ?? 1.0,
  intensityGrid: (json['intensityGrid'] as List<dynamic>?)
      ?.map(
        (e) => (e as List<dynamic>).map((e) => (e as num).toDouble()).toList(),
      )
      .toList(),
  isNoData: json['isNoData'] as bool? ?? false,
  isForecast: json['isForecast'] as bool? ?? false,
  tileType:
      $enumDecodeNullable(_$RadarTileTypeEnumMap, json['tileType']) ??
      RadarTileType.xyz,
  wmsLayers: json['wmsLayers'] as String?,
  wmsAdditionalOptions: (json['wmsAdditionalOptions'] as Map<String, dynamic>?)
      ?.map((k, e) => MapEntry(k, e as String)),
);

Map<String, dynamic> _$RadarFrameToJson(_RadarFrame instance) =>
    <String, dynamic>{
      'timestamp': instance.timestamp.toIso8601String(),
      'tileUrlTemplate': instance.tileUrlTemplate,
      'north': instance.north,
      'south': instance.south,
      'east': instance.east,
      'west': instance.west,
      'opacity': instance.opacity,
      'intensityGrid': instance.intensityGrid,
      'isNoData': instance.isNoData,
      'isForecast': instance.isForecast,
      'tileType': _$RadarTileTypeEnumMap[instance.tileType]!,
      'wmsLayers': instance.wmsLayers,
      'wmsAdditionalOptions': instance.wmsAdditionalOptions,
    };

const _$RadarTileTypeEnumMap = {
  RadarTileType.xyz: 'xyz',
  RadarTileType.wms: 'wms',
};
