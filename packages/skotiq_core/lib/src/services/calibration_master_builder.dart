import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;

/// What to build: one dark or bias master from raw frames on disk.
class CalibrationMasterBuildRequest {
  const CalibrationMasterBuildRequest({
    required this.kind,
    required this.framePaths,
    required this.outputPath,
    this.leakMinRiseAdu,
  });

  /// `dark` or `bias`.
  final String kind;
  final List<String> framePaths;
  final String outputPath;

  /// Rise over the group's opening frames, in ADU, that counts as a light
  /// leak. Null uses the native default.
  final double? leakMinRiseAdu;

  Map<String, dynamic> toJson() => {
    'kind': kind,
    'framePaths': framePaths,
    'outputPath': outputPath,
    if (leakMinRiseAdu != null) 'leakMinRiseAdu': leakMinRiseAdu,
  };
}

/// Level of one input frame, as the native builder measured it.
class CalibrationFrameLevel {
  const CalibrationFrameLevel({
    required this.path,
    required this.level,
    required this.noise,
  });

  final String path;
  final double level;
  final double noise;

  factory CalibrationFrameLevel.fromJson(Map<String, dynamic> json) =>
      CalibrationFrameLevel(
        path: json['path'] as String,
        level: (json['level'] as num).toDouble(),
        noise: (json['noise'] as num).toDouble(),
      );
}

/// A master the native builder wrote: an unsigned 16-bit winsorized
/// sigma-clipped mean with the acquisition keys in its header.
class CalibrationMasterBuildResult {
  const CalibrationMasterBuildResult({
    required this.outputPath,
    required this.kind,
    required this.width,
    required this.height,
    required this.frameCount,
    required this.leakingFrames,
    required this.frameLevels,
    required this.leakBaseline,
    required this.leakThreshold,
    required this.masterMean,
    required this.rejectionFraction,
    this.exposureSecs,
    this.gain,
    this.offset,
    this.binX,
    this.binY,
    this.ccdTempMean,
    this.setTemp,
  });

  final String outputPath;
  final String kind;
  final int width;
  final int height;

  /// Frames combined into the master.
  final int frameCount;

  /// Frames left out because they read brighter than the group's first ones.
  final List<String> leakingFrames;
  final List<CalibrationFrameLevel> frameLevels;
  final double leakBaseline;
  final double leakThreshold;
  final double masterMean;
  final double rejectionFraction;
  final double? exposureSecs;
  final int? gain;
  final int? offset;
  final int? binX;
  final int? binY;
  final double? ccdTempMean;
  final double? setTemp;

  factory CalibrationMasterBuildResult.fromJson(Map<String, dynamic> json) {
    double? d(String key) => (json[key] as num?)?.toDouble();
    int? i(String key) => (json[key] as num?)?.toInt();
    return CalibrationMasterBuildResult(
      outputPath: json['outputPath'] as String,
      kind: json['kind'] as String,
      width: (json['width'] as num).toInt(),
      height: (json['height'] as num).toInt(),
      frameCount: (json['frameCount'] as num).toInt(),
      leakingFrames: [
        for (final p in (json['leakingFrames'] as List? ?? const [])) '$p',
      ],
      frameLevels: [
        for (final l in (json['frameLevels'] as List? ?? const []))
          CalibrationFrameLevel.fromJson(Map<String, dynamic>.from(l as Map)),
      ],
      leakBaseline: (json['leakBaseline'] as num).toDouble(),
      leakThreshold: (json['leakThreshold'] as num).toDouble(),
      masterMean: (json['masterMean'] as num).toDouble(),
      rejectionFraction: (json['rejectionFraction'] as num).toDouble(),
      exposureSecs: d('exposureSecs'),
      gain: i('gain'),
      offset: i('offset'),
      binX: i('binX'),
      binY: i('binY'),
      ccdTempMean: d('ccdTempMean'),
      setTemp: d('setTemp'),
    );
  }
}

/// Builds one calibration master. The production implementation calls the
/// native builder, which reads the frames a band of rows at a time so memory
/// does not grow with the frame count; tests substitute a fake.
typedef CalibrationMasterBuild =
    Future<CalibrationMasterBuildResult> Function(
      CalibrationMasterBuildRequest request,
    );

Future<CalibrationMasterBuildResult> buildCalibrationMasterNative(
  CalibrationMasterBuildRequest request,
) async {
  final out = await bridge.apiBuildCalibrationMaster(
    argsJson: jsonEncode(request.toJson()),
  );
  return CalibrationMasterBuildResult.fromJson(
    Map<String, dynamic>.from(jsonDecode(out) as Map),
  );
}

final calibrationMasterBuildProvider = Provider<CalibrationMasterBuild>(
  (ref) => buildCalibrationMasterNative,
);
