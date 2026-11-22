import 'dart:convert';

import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;

/// The fewest frames a calibration master is built from.
const int calibrationMasterMinFrames = 2;

/// How a calibration master's file name spells what it does not know. The
/// calibration backlog writes `gx`/`ox` for an unstated gain or offset and
/// stamps seconds; end-of-night calibration leaves them out, adds the read
/// mode and stamps minutes.
class CalibrationMasterNameStyle {
  const CalibrationMasterNameStyle._({
    required this.unstatedAsX,
    required this.stampSeconds,
  });

  static const backlog = CalibrationMasterNameStyle._(
    unstatedAsX: true,
    stampSeconds: true,
  );
  static const endOfNight = CalibrationMasterNameStyle._(
    unstatedAsX: false,
    stampSeconds: false,
  );

  final bool unstatedAsX;
  final bool stampSeconds;
}

/// A number as a master file name spells it: whole numbers bare, else up to
/// three decimals with `p` for the point (`0p5`).
String calibrationMasterNameNumber(double value) =>
    value == value.roundToDouble()
    ? value.toStringAsFixed(0)
    : value
          .toStringAsFixed(3)
          .replaceFirst(RegExp(r'0+$'), '')
          .replaceAll('.', 'p');

/// The file name of a master of [kind] (`dark`, `bias` or `flat`) built at
/// [builtAt]: `MasterDark_90s_g76_o15_m10C_bin1_20261025-090000.fits`.
String calibrationMasterFileName({
  required String kind,
  required CalibrationMasterNameStyle style,
  required DateTime builtAt,
  required double exposureSeconds,
  required int? gain,
  required int? offset,
  required int binX,
  required double? temperatureC,
  String? filter,
  String? readMode,
}) {
  final head = switch (kind) {
    'bias' => 'MasterBias',
    'flat' =>
      'MasterFlat_${(filter ?? 'NoFilter').replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}',
    _ => 'MasterDark_${calibrationMasterNameNumber(exposureSeconds)}s',
  };
  String part(String tag, int? value) =>
      value != null ? '_$tag$value' : (style.unstatedAsX ? '_${tag}x' : '');
  final rounded = temperatureC?.round();
  final temp = rounded == null
      ? 'notemp'
      : (rounded < 0 ? 'm${-rounded}C' : 'p${rounded}C');
  final mode = readMode == null
      ? ''
      : '_${readMode.replaceAll(RegExp(r'[^A-Za-z0-9-]'), '')}';
  String two(int v) => v.toString().padLeft(2, '0');
  final t = builtAt;
  final stamp =
      '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}'
      '${style.stampSeconds ? two(t.second) : ''}';
  return '$head${part('g', gain)}${part('o', offset)}_${temp}_bin$binX$mode'
      '_$stamp.fits';
}

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
  final String out;
  try {
    out = await bridge.apiBuildCalibrationMaster(
      argsJson: jsonEncode(request.toJson()),
    );
  } on bridge.SkotiqError_InvalidInput catch (e) {
    throw CalibrationMasterRefused(e.field0);
  }
  return CalibrationMasterBuildResult.fromJson(
    Map<String, dynamic>.from(jsonDecode(out) as Map),
  );
}

/// The frames cannot make one master: too few, unreadable, disagreeing on how
/// they were taken, or leaking light. Nothing was written; [reason] says which.
class CalibrationMasterRefused implements Exception {
  const CalibrationMasterRefused(this.reason);

  final String reason;

  @override
  String toString() => reason;
}
