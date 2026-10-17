// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'phd2_models.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_Phd2StarImage _$Phd2StarImageFromJson(Map<String, dynamic> json) =>
    _Phd2StarImage(
      frame: (json['frame'] as num).toInt(),
      width: (json['width'] as num).toInt(),
      height: (json['height'] as num).toInt(),
      starX: (json['starX'] as num).toDouble(),
      starY: (json['starY'] as num).toDouble(),
      pixels: const Uint8ListConverter().fromJson(json['pixels'] as List<int>),
    );

Map<String, dynamic> _$Phd2StarImageToJson(_Phd2StarImage instance) =>
    <String, dynamic>{
      'frame': instance.frame,
      'width': instance.width,
      'height': instance.height,
      'starX': instance.starX,
      'starY': instance.starY,
      'pixels': const Uint8ListConverter().toJson(instance.pixels),
    };

_Phd2AlgoParam _$Phd2AlgoParamFromJson(Map<String, dynamic> json) =>
    _Phd2AlgoParam(
      name: json['name'] as String,
      value: (json['value'] as num).toDouble(),
    );

Map<String, dynamic> _$Phd2AlgoParamToJson(_Phd2AlgoParam instance) =>
    <String, dynamic>{'name': instance.name, 'value': instance.value};

_Phd2BrainParams _$Phd2BrainParamsFromJson(Map<String, dynamic> json) =>
    _Phd2BrainParams(
      raParamNames: (json['raParamNames'] as List<dynamic>)
          .map((e) => e as String)
          .toList(),
      decParamNames: (json['decParamNames'] as List<dynamic>)
          .map((e) => e as String)
          .toList(),
      raParams: (json['raParams'] as Map<String, dynamic>).map(
        (k, e) => MapEntry(k, (e as num).toDouble()),
      ),
      decParams: (json['decParams'] as Map<String, dynamic>).map(
        (k, e) => MapEntry(k, (e as num).toDouble()),
      ),
    );

Map<String, dynamic> _$Phd2BrainParamsToJson(_Phd2BrainParams instance) =>
    <String, dynamic>{
      'raParamNames': instance.raParamNames,
      'decParamNames': instance.decParamNames,
      'raParams': instance.raParams,
      'decParams': instance.decParams,
    };

_GuideErrorPoint _$GuideErrorPointFromJson(Map<String, dynamic> json) =>
    _GuideErrorPoint(
      raError: (json['raError'] as num).toDouble(),
      decError: (json['decError'] as num).toDouble(),
      timestamp: DateTime.parse(json['timestamp'] as String),
    );

Map<String, dynamic> _$GuideErrorPointToJson(_GuideErrorPoint instance) =>
    <String, dynamic>{
      'raError': instance.raError,
      'decError': instance.decError,
      'timestamp': instance.timestamp.toIso8601String(),
    };

_Phd2GuideStats _$Phd2GuideStatsFromJson(Map<String, dynamic> json) =>
    _Phd2GuideStats(
      rmsRa: (json['rmsRa'] as num?)?.toDouble() ?? 0.0,
      rmsDec: (json['rmsDec'] as num?)?.toDouble() ?? 0.0,
      rmsTotal: (json['rmsTotal'] as num?)?.toDouble() ?? 0.0,
      peakRa: (json['peakRa'] as num?)?.toDouble() ?? 0.0,
      peakDec: (json['peakDec'] as num?)?.toDouble() ?? 0.0,
      snr: (json['snr'] as num?)?.toDouble() ?? 0.0,
      starMass: (json['starMass'] as num?)?.toDouble() ?? 0.0,
      hfd: (json['hfd'] as num?)?.toDouble() ?? 0.0,
      starX: (json['starX'] as num?)?.toDouble() ?? 0.0,
      starY: (json['starY'] as num?)?.toDouble() ?? 0.0,
      pixelScale: (json['pixelScale'] as num?)?.toDouble() ?? 0.0,
      frameCount: (json['frameCount'] as num?)?.toInt() ?? 0,
      loopFrameCount: (json['loopFrameCount'] as num?)?.toInt() ?? 0,
    );

Map<String, dynamic> _$Phd2GuideStatsToJson(_Phd2GuideStats instance) =>
    <String, dynamic>{
      'rmsRa': instance.rmsRa,
      'rmsDec': instance.rmsDec,
      'rmsTotal': instance.rmsTotal,
      'peakRa': instance.peakRa,
      'peakDec': instance.peakDec,
      'snr': instance.snr,
      'starMass': instance.starMass,
      'hfd': instance.hfd,
      'starX': instance.starX,
      'starY': instance.starY,
      'pixelScale': instance.pixelScale,
      'frameCount': instance.frameCount,
      'loopFrameCount': instance.loopFrameCount,
    };

_Phd2CalibrationData _$Phd2CalibrationDataFromJson(Map<String, dynamic> json) =>
    _Phd2CalibrationData(
      isCalibrated: json['isCalibrated'] as bool? ?? false,
      calibratedAt: json['calibratedAt'] == null
          ? null
          : DateTime.parse(json['calibratedAt'] as String),
      raRate: (json['raRate'] as num?)?.toDouble(),
      decRate: (json['decRate'] as num?)?.toDouble(),
      rotationAngle: (json['rotationAngle'] as num?)?.toDouble(),
      decGuideMode: json['decGuideMode'] as String?,
    );

Map<String, dynamic> _$Phd2CalibrationDataToJson(
  _Phd2CalibrationData instance,
) => <String, dynamic>{
  'isCalibrated': instance.isCalibrated,
  'calibratedAt': instance.calibratedAt?.toIso8601String(),
  'raRate': instance.raRate,
  'decRate': instance.decRate,
  'rotationAngle': instance.rotationAngle,
  'decGuideMode': instance.decGuideMode,
};
