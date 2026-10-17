// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'flat_wizard_settings.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_FlatWizardGlobalSettings _$FlatWizardGlobalSettingsFromJson(
  Map<String, dynamic> json,
) => _FlatWizardGlobalSettings(
  histogramTarget: (json['histogramTarget'] as num?)?.toDouble() ?? 50.0,
  tolerancePercent: (json['tolerancePercent'] as num?)?.toDouble() ?? 10.0,
  minExposure: (json['minExposure'] as num?)?.toDouble() ?? 0.001,
  maxExposure: (json['maxExposure'] as num?)?.toDouble() ?? 30.0,
  frameCount: (json['frameCount'] as num?)?.toInt() ?? 30,
  gain: (json['gain'] as num?)?.toInt() ?? 0,
  binning: (json['binning'] as num?)?.toInt() ?? 1,
  savePath: json['savePath'] as String?,
  createDateSubfolder: json['createDateSubfolder'] as bool? ?? true,
  createFilterSubfolders: json['createFilterSubfolders'] as bool? ?? true,
  imageDownloadTimeoutSeconds:
      (json['imageDownloadTimeoutSeconds'] as num?)?.toInt() ?? 60,
  maxIterations: (json['maxIterations'] as num?)?.toInt() ?? 8,
);

Map<String, dynamic> _$FlatWizardGlobalSettingsToJson(
  _FlatWizardGlobalSettings instance,
) => <String, dynamic>{
  'histogramTarget': instance.histogramTarget,
  'tolerancePercent': instance.tolerancePercent,
  'minExposure': instance.minExposure,
  'maxExposure': instance.maxExposure,
  'frameCount': instance.frameCount,
  'gain': instance.gain,
  'binning': instance.binning,
  'savePath': instance.savePath,
  'createDateSubfolder': instance.createDateSubfolder,
  'createFilterSubfolders': instance.createFilterSubfolders,
  'imageDownloadTimeoutSeconds': instance.imageDownloadTimeoutSeconds,
  'maxIterations': instance.maxIterations,
};

_FlatFilterSettings _$FlatFilterSettingsFromJson(Map<String, dynamic> json) =>
    _FlatFilterSettings(
      filterName: json['filterName'] as String,
      filterPosition: (json['filterPosition'] as num).toInt(),
      enabled: json['enabled'] as bool? ?? true,
      histogramTargetOverride: (json['histogramTargetOverride'] as num?)
          ?.toDouble(),
      toleranceOverride: (json['toleranceOverride'] as num?)?.toDouble(),
      minExposureOverride: (json['minExposureOverride'] as num?)?.toDouble(),
      maxExposureOverride: (json['maxExposureOverride'] as num?)?.toDouble(),
      frameCountOverride: (json['frameCountOverride'] as num?)?.toInt(),
      suggestedExposure: (json['suggestedExposure'] as num?)?.toDouble(),
      calibratedExposure: (json['calibratedExposure'] as num?)?.toDouble(),
      capturedCount: (json['capturedCount'] as num?)?.toInt() ?? 0,
      currentAdu: (json['currentAdu'] as num?)?.toDouble(),
      status:
          $enumDecodeNullable(
            _$FilterCalibrationStatusEnumMap,
            json['status'],
          ) ??
          FilterCalibrationStatus.pending,
    );

Map<String, dynamic> _$FlatFilterSettingsToJson(_FlatFilterSettings instance) =>
    <String, dynamic>{
      'filterName': instance.filterName,
      'filterPosition': instance.filterPosition,
      'enabled': instance.enabled,
      'histogramTargetOverride': instance.histogramTargetOverride,
      'toleranceOverride': instance.toleranceOverride,
      'minExposureOverride': instance.minExposureOverride,
      'maxExposureOverride': instance.maxExposureOverride,
      'frameCountOverride': instance.frameCountOverride,
      'suggestedExposure': instance.suggestedExposure,
      'calibratedExposure': instance.calibratedExposure,
      'capturedCount': instance.capturedCount,
      'currentAdu': instance.currentAdu,
      'status': _$FilterCalibrationStatusEnumMap[instance.status]!,
    };

const _$FilterCalibrationStatusEnumMap = {
  FilterCalibrationStatus.pending: 'pending',
  FilterCalibrationStatus.calibrating: 'calibrating',
  FilterCalibrationStatus.calibrated: 'calibrated',
  FilterCalibrationStatus.capturing: 'capturing',
  FilterCalibrationStatus.complete: 'complete',
  FilterCalibrationStatus.partial: 'partial',
  FilterCalibrationStatus.failed: 'failed',
  FilterCalibrationStatus.skipped: 'skipped',
};

_FlatFilterPreset _$FlatFilterPresetFromJson(Map<String, dynamic> json) =>
    _FlatFilterPreset(
      name: json['name'] as String,
      filterNames: (json['filterNames'] as List<dynamic>)
          .map((e) => e as String)
          .toList(),
    );

Map<String, dynamic> _$FlatFilterPresetToJson(_FlatFilterPreset instance) =>
    <String, dynamic>{
      'name': instance.name,
      'filterNames': instance.filterNames,
    };
