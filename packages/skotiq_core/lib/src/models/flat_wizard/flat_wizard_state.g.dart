// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'flat_wizard_state.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_AduMeasurement _$AduMeasurementFromJson(Map<String, dynamic> json) =>
    _AduMeasurement(
      exposure: (json['exposure'] as num).toDouble(),
      adu: (json['adu'] as num).toDouble(),
      timestamp: DateTime.parse(json['timestamp'] as String),
    );

Map<String, dynamic> _$AduMeasurementToJson(_AduMeasurement instance) =>
    <String, dynamic>{
      'exposure': instance.exposure,
      'adu': instance.adu,
      'timestamp': instance.timestamp.toIso8601String(),
    };

_SkyBrightnessMeasurement _$SkyBrightnessMeasurementFromJson(
  Map<String, dynamic> json,
) => _SkyBrightnessMeasurement(
  adu: (json['adu'] as num).toDouble(),
  exposureUsed: (json['exposureUsed'] as num).toDouble(),
  timestamp: DateTime.parse(json['timestamp'] as String),
);

Map<String, dynamic> _$SkyBrightnessMeasurementToJson(
  _SkyBrightnessMeasurement instance,
) => <String, dynamic>{
  'adu': instance.adu,
  'exposureUsed': instance.exposureUsed,
  'timestamp': instance.timestamp.toIso8601String(),
};

_FlatWizardState _$FlatWizardStateFromJson(
  Map<String, dynamic> json,
) => _FlatWizardState(
  mode:
      $enumDecodeNullable(_$FlatWizardModeEnumMap, json['mode']) ??
      FlatWizardMode.quick,
  globalSettings: json['globalSettings'] == null
      ? const FlatWizardGlobalSettings()
      : FlatWizardGlobalSettings.fromJson(
          json['globalSettings'] as Map<String, dynamic>,
        ),
  filterSettings:
      (json['filterSettings'] as List<dynamic>?)
          ?.map((e) => FlatFilterSettings.fromJson(e as Map<String, dynamic>))
          .toList() ??
      const [],
  filterPresets:
      (json['filterPresets'] as List<dynamic>?)
          ?.map((e) => FlatFilterPreset.fromJson(e as Map<String, dynamic>))
          .toList() ??
      const [],
  currentFilterIndex: (json['currentFilterIndex'] as num?)?.toInt() ?? 0,
  currentFrameIndex: (json['currentFrameIndex'] as num?)?.toInt() ?? 0,
  isCapturing: json['isCapturing'] as bool? ?? false,
  isExposing: json['isExposing'] as bool? ?? false,
  exposureStartTime: json['exposureStartTime'] == null
      ? null
      : DateTime.parse(json['exposureStartTime'] as String),
  currentExposureDuration: (json['currentExposureDuration'] as num?)
      ?.toDouble(),
  aduHistory:
      (json['aduHistory'] as List<dynamic>?)
          ?.map((e) => AduMeasurement.fromJson(e as Map<String, dynamic>))
          .toList() ??
      const [],
  skyBrightnessHistory:
      (json['skyBrightnessHistory'] as List<dynamic>?)
          ?.map(
            (e) => SkyBrightnessMeasurement.fromJson(e as Map<String, dynamic>),
          )
          .toList() ??
      const [],
  skyAduRate: (json['skyAduRate'] as num?)?.toDouble(),
  twilightMode:
      $enumDecodeNullable(_$TwilightModeEnumMap, json['twilightMode']) ??
      TwilightMode.dusk,
  lastImagePath: json['lastImagePath'] as String?,
  lastImageData: const RuntimeOnlyValueConverter().fromJson(
    json['lastImageData'],
  ),
  errorMessage: json['errorMessage'] as String?,
  warningMessage: json['warningMessage'] as String?,
  statusMessage: json['statusMessage'] as String?,
  showAduGraph: json['showAduGraph'] as bool? ?? true,
  showExposureTimeline: json['showExposureTimeline'] as bool? ?? true,
  showSkyBrightness: json['showSkyBrightness'] as bool? ?? true,
  showFilterCards: json['showFilterCards'] as bool? ?? true,
  showHistogramOverlay: json['showHistogramOverlay'] as bool? ?? false,
);

Map<String, dynamic> _$FlatWizardStateToJson(_FlatWizardState instance) =>
    <String, dynamic>{
      'mode': _$FlatWizardModeEnumMap[instance.mode]!,
      'globalSettings': instance.globalSettings,
      'filterSettings': instance.filterSettings,
      'filterPresets': instance.filterPresets,
      'currentFilterIndex': instance.currentFilterIndex,
      'currentFrameIndex': instance.currentFrameIndex,
      'isCapturing': instance.isCapturing,
      'isExposing': instance.isExposing,
      'exposureStartTime': instance.exposureStartTime?.toIso8601String(),
      'currentExposureDuration': instance.currentExposureDuration,
      'aduHistory': instance.aduHistory,
      'skyBrightnessHistory': instance.skyBrightnessHistory,
      'skyAduRate': instance.skyAduRate,
      'twilightMode': _$TwilightModeEnumMap[instance.twilightMode]!,
      'lastImagePath': instance.lastImagePath,
      'lastImageData': const RuntimeOnlyValueConverter().toJson(
        instance.lastImageData,
      ),
      'errorMessage': instance.errorMessage,
      'warningMessage': instance.warningMessage,
      'statusMessage': instance.statusMessage,
      'showAduGraph': instance.showAduGraph,
      'showExposureTimeline': instance.showExposureTimeline,
      'showSkyBrightness': instance.showSkyBrightness,
      'showFilterCards': instance.showFilterCards,
      'showHistogramOverlay': instance.showHistogramOverlay,
    };

const _$FlatWizardModeEnumMap = {
  FlatWizardMode.quick: 'quick',
  FlatWizardMode.batch: 'batch',
  FlatWizardMode.skyFlats: 'skyFlats',
};

const _$TwilightModeEnumMap = {
  TwilightMode.dawn: 'dawn',
  TwilightMode.dusk: 'dusk',
};
