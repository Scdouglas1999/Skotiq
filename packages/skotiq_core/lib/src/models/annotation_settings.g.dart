// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'annotation_settings.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_AnnotationSettings _$AnnotationSettingsFromJson(
  Map<String, dynamic> json,
) => _AnnotationSettings(
  enabled: json['enabled'] as bool? ?? true,
  magnitudeCutoff: (json['magnitudeCutoff'] as num?)?.toDouble() ?? 15.0,
  minMagnitude: (json['minMagnitude'] as num?)?.toDouble() ?? -5.0,
  visibleTypes:
      (json['visibleTypes'] as List<dynamic>?)
          ?.map((e) => $enumDecode(_$AnnotationObjectFilterEnumMap, e))
          .toSet() ??
      const {
        AnnotationObjectFilter.galaxies,
        AnnotationObjectFilter.nebulae,
        AnnotationObjectFilter.starClusters,
        AnnotationObjectFilter.planetaryNebulae,
      },
  showLabels: json['showLabels'] as bool? ?? true,
  showMagnitudes: json['showMagnitudes'] as bool? ?? false,
  fadeWhenNotHovering: json['fadeWhenNotHovering'] as bool? ?? true,
  hoverOpacity: (json['hoverOpacity'] as num?)?.toDouble() ?? 0.8,
  idleOpacity: (json['idleOpacity'] as num?)?.toDouble() ?? 0.2,
  fadeAnimationMs: (json['fadeAnimationMs'] as num?)?.toInt() ?? 400,
  clickToIdentify: json['clickToIdentify'] as bool? ?? true,
  clickSearchRadiusArcsec:
      (json['clickSearchRadiusArcsec'] as num?)?.toDouble() ?? 30.0,
  autoAnnotate: json['autoAnnotate'] as bool? ?? true,
  maxObjectsToDisplay: (json['maxObjectsToDisplay'] as num?)?.toInt() ?? 500,
  catalogBboxPaddingFraction:
      (json['catalogBboxPaddingFraction'] as num?)?.toDouble() ?? 0.05,
  compassEnabled: json['compassEnabled'] as bool? ?? true,
  scaleBarEnabled: json['scaleBarEnabled'] as bool? ?? true,
  gridType:
      $enumDecodeNullable(_$GridTypeEnumMap, json['gridType']) ?? GridType.none,
  showSolveResiduals: json['showSolveResiduals'] as bool? ?? false,
);

Map<String, dynamic> _$AnnotationSettingsToJson(_AnnotationSettings instance) =>
    <String, dynamic>{
      'enabled': instance.enabled,
      'magnitudeCutoff': instance.magnitudeCutoff,
      'minMagnitude': instance.minMagnitude,
      'visibleTypes': instance.visibleTypes
          .map((e) => _$AnnotationObjectFilterEnumMap[e]!)
          .toList(),
      'showLabels': instance.showLabels,
      'showMagnitudes': instance.showMagnitudes,
      'fadeWhenNotHovering': instance.fadeWhenNotHovering,
      'hoverOpacity': instance.hoverOpacity,
      'idleOpacity': instance.idleOpacity,
      'fadeAnimationMs': instance.fadeAnimationMs,
      'clickToIdentify': instance.clickToIdentify,
      'clickSearchRadiusArcsec': instance.clickSearchRadiusArcsec,
      'autoAnnotate': instance.autoAnnotate,
      'maxObjectsToDisplay': instance.maxObjectsToDisplay,
      'catalogBboxPaddingFraction': instance.catalogBboxPaddingFraction,
      'compassEnabled': instance.compassEnabled,
      'scaleBarEnabled': instance.scaleBarEnabled,
      'gridType': _$GridTypeEnumMap[instance.gridType]!,
      'showSolveResiduals': instance.showSolveResiduals,
    };

const _$AnnotationObjectFilterEnumMap = {
  AnnotationObjectFilter.galaxies: 'galaxies',
  AnnotationObjectFilter.nebulae: 'nebulae',
  AnnotationObjectFilter.starClusters: 'starClusters',
  AnnotationObjectFilter.planetaryNebulae: 'planetaryNebulae',
  AnnotationObjectFilter.stars: 'stars',
  AnnotationObjectFilter.other: 'other',
};

const _$GridTypeEnumMap = {
  GridType.none: 'none',
  GridType.pixel: 'pixel',
  GridType.celestial: 'celestial',
};

_AnnotationMarkerStyle _$AnnotationMarkerStyleFromJson(
  Map<String, dynamic> json,
) => _AnnotationMarkerStyle(
  galaxyColor: (json['galaxyColor'] as num?)?.toInt() ?? 0xFFFFD700,
  nebulaColor: (json['nebulaColor'] as num?)?.toInt() ?? 0xFFFF00FF,
  clusterColor: (json['clusterColor'] as num?)?.toInt() ?? 0xFF00FFFF,
  planetaryNebulaColor:
      (json['planetaryNebulaColor'] as num?)?.toInt() ?? 0xFF9400D3,
  starColor: (json['starColor'] as num?)?.toInt() ?? 0xFFFFFFFF,
  otherColor: (json['otherColor'] as num?)?.toInt() ?? 0xFF00FF00,
  strokeWidth: (json['strokeWidth'] as num?)?.toDouble() ?? 1.5,
  labelFontSize: (json['labelFontSize'] as num?)?.toDouble() ?? 12.0,
  scaleBySize: json['scaleBySize'] as bool? ?? true,
  minMarkerSize: (json['minMarkerSize'] as num?)?.toDouble() ?? 10.0,
  maxMarkerSize: (json['maxMarkerSize'] as num?)?.toDouble() ?? 100.0,
);

Map<String, dynamic> _$AnnotationMarkerStyleToJson(
  _AnnotationMarkerStyle instance,
) => <String, dynamic>{
  'galaxyColor': instance.galaxyColor,
  'nebulaColor': instance.nebulaColor,
  'clusterColor': instance.clusterColor,
  'planetaryNebulaColor': instance.planetaryNebulaColor,
  'starColor': instance.starColor,
  'otherColor': instance.otherColor,
  'strokeWidth': instance.strokeWidth,
  'labelFontSize': instance.labelFontSize,
  'scaleBySize': instance.scaleBySize,
  'minMarkerSize': instance.minMarkerSize,
  'maxMarkerSize': instance.maxMarkerSize,
};

_AnnotationPreset _$AnnotationPresetFromJson(Map<String, dynamic> json) =>
    _AnnotationPreset(
      name: json['name'] as String,
      visibleTypes: (json['visibleTypes'] as List<dynamic>)
          .map((e) => $enumDecode(_$AnnotationObjectFilterEnumMap, e))
          .toSet(),
      minMagnitude: (json['minMagnitude'] as num).toDouble(),
      magnitudeCutoff: (json['magnitudeCutoff'] as num).toDouble(),
      showLabels: json['showLabels'] as bool,
      showMagnitudes: json['showMagnitudes'] as bool,
      isBuiltIn: json['isBuiltIn'] as bool? ?? false,
    );

Map<String, dynamic> _$AnnotationPresetToJson(_AnnotationPreset instance) =>
    <String, dynamic>{
      'name': instance.name,
      'visibleTypes': instance.visibleTypes
          .map((e) => _$AnnotationObjectFilterEnumMap[e]!)
          .toList(),
      'minMagnitude': instance.minMagnitude,
      'magnitudeCutoff': instance.magnitudeCutoff,
      'showLabels': instance.showLabels,
      'showMagnitudes': instance.showMagnitudes,
      'isBuiltIn': instance.isBuiltIn,
    };

_CustomAnnotation _$CustomAnnotationFromJson(Map<String, dynamic> json) =>
    _CustomAnnotation(
      id: json['id'] as String,
      type: $enumDecode(_$CustomAnnotationTypeEnumMap, json['type']),
      x: (json['x'] as num).toDouble(),
      y: (json['y'] as num).toDouble(),
      x2: (json['x2'] as num?)?.toDouble(),
      y2: (json['y2'] as num?)?.toDouble(),
      radius: (json['radius'] as num?)?.toDouble(),
      label: json['label'] as String? ?? '',
      color: (json['color'] as num?)?.toInt() ?? 0xFFFF6B6B,
    );

Map<String, dynamic> _$CustomAnnotationToJson(_CustomAnnotation instance) =>
    <String, dynamic>{
      'id': instance.id,
      'type': _$CustomAnnotationTypeEnumMap[instance.type]!,
      'x': instance.x,
      'y': instance.y,
      'x2': instance.x2,
      'y2': instance.y2,
      'radius': instance.radius,
      'label': instance.label,
      'color': instance.color,
    };

const _$CustomAnnotationTypeEnumMap = {
  CustomAnnotationType.circle: 'circle',
  CustomAnnotationType.arrow: 'arrow',
  CustomAnnotationType.text: 'text',
};
