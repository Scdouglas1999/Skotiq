import '../sensor_specs/camera_sensor_database.dart';
import '../sensor_specs/camera_sensor_spec_resolver.dart';

/// Per-gain camera sensor values a user entered for one camera.
class CameraGainPoint {
  final int gain;
  final double readNoiseE;
  final double fullWellE;

  const CameraGainPoint({
    required this.gain,
    required this.readNoiseE,
    required this.fullWellE,
  });

  factory CameraGainPoint.fromJson(Map<String, dynamic> json) {
    return CameraGainPoint(
      gain: _intValue(json['gain'], 'gain'),
      readNoiseE: _doubleValue(json['readNoiseE'], 'readNoiseE'),
      fullWellE: _doubleValue(json['fullWellE'], 'fullWellE'),
    );
  }

  Map<String, dynamic> toJson() => {
    'gain': gain,
    'readNoiseE': readNoiseE,
    'fullWellE': fullWellE,
  };
}

/// One camera's sensor values as the USER entered them.
///
/// This is the top of the sensor-spec resolution chain and the only tier the
/// app writes on the user's behalf. The published specification database
/// ([kCuratedCameraSensors]) is a separate, lower tier; a row from it never
/// overwrites one of these.
class CameraHardwareSpec {
  final String model;
  final List<String> aliases;

  /// Only the fields the user actually set are present.
  ///
  /// A user who opens the dialog to correct a pixel size must not come away
  /// having also asserted a read noise. Every figure here is nullable so an
  /// override can claim one value and leave the rest of the chain — the
  /// published specification, or an honest caveat — to answer for the others.
  final double? pixelSizeMicrons;
  final double? qePeak;
  final int defaultGain;
  final List<CameraGainPoint> gainPoints;

  /// Sensor pixel count, when the user corrected it. Optional because the
  /// driver reports geometry reliably and most corrections are to the figures
  /// it does not report.
  final int? sensorWidthPx;
  final int? sensorHeightPx;

  const CameraHardwareSpec({
    required this.model,
    this.aliases = const [],
    this.pixelSizeMicrons,
    this.qePeak,
    required this.defaultGain,
    this.gainPoints = const [],
    this.sensorWidthPx,
    this.sensorHeightPx,
  });

  factory CameraHardwareSpec.fromJson(Map<String, dynamic> json) {
    // The key has to be there and has to be a list — a blob that does not even
    // have the shape is corrupt, and the planner says so. An EMPTY list is
    // different and legitimate: an override that corrects geometry only.
    final gainPointsJson = json['gainPoints'];
    if (gainPointsJson is! List) {
      throw const FormatException('Camera spec requires a gainPoints list');
    }
    final aliasesJson = json['aliases'];
    return CameraHardwareSpec(
      model: _stringValue(json['model'], 'model'),
      aliases: aliasesJson is List
          ? aliasesJson.map((value) => value.toString()).toList()
          : const [],
      pixelSizeMicrons: _optionalDoubleValue(json['pixelSizeMicrons']),
      qePeak: _optionalDoubleValue(json['qePeak']),
      defaultGain: _intValue(json['defaultGain'], 'defaultGain'),
      gainPoints: gainPointsJson
          .map(
            (value) => CameraGainPoint.fromJson(
              (value as Map).cast<String, dynamic>(),
            ),
          )
          .toList(),
      sensorWidthPx: _optionalIntValue(json['sensorWidthPx']),
      sensorHeightPx: _optionalIntValue(json['sensorHeightPx']),
    );
  }

  Map<String, dynamic> toJson() => {
    'model': model,
    'aliases': aliases,
    if (pixelSizeMicrons != null) 'pixelSizeMicrons': pixelSizeMicrons,
    if (qePeak != null) 'qePeak': qePeak,
    'defaultGain': defaultGain,
    'gainPoints': gainPoints.map((point) => point.toJson()).toList(),
    if (sensorWidthPx != null) 'sensorWidthPx': sensorWidthPx,
    if (sensorHeightPx != null) 'sensorHeightPx': sensorHeightPx,
  };

  /// Every name this spec answers to, normalised.
  Set<String> get matchKeys => {
    for (final name in [model, ...aliases])
      if (CameraSensorDatabase.normalize(name).isNotEmpty)
        CameraSensorDatabase.normalize(name),
  };

  /// The gain point at [gain], interpolated between the user's own points and
  /// clamped to the ends of what they entered. Null when they entered none.
  ///
  /// Interpolation is legitimate here in a way it is not for the published
  /// database: these points are a curve the user supplied, and the values
  /// between two of their own measurements are the best answer available.
  CameraGainPoint? gainPointFor(int gain) {
    if (gainPoints.isEmpty) return null;
    final points = [...gainPoints]..sort((a, b) => a.gain.compareTo(b.gain));
    for (final point in points) {
      if (point.gain == gain) return point;
    }
    if (gain <= points.first.gain) return points.first;
    if (gain >= points.last.gain) return points.last;
    for (var i = 0; i < points.length - 1; i++) {
      final lower = points[i];
      final upper = points[i + 1];
      if (gain > lower.gain && gain < upper.gain) {
        final t = (gain - lower.gain) / (upper.gain - lower.gain);
        return CameraGainPoint(
          gain: gain,
          readNoiseE: _lerp(lower.readNoiseE, upper.readNoiseE, t),
          fullWellE: _lerp(lower.fullWellE, upper.fullWellE, t),
        );
      }
    }
    return points.last;
  }

  static double _lerp(double a, double b, double t) => a + (b - a) * t;
}

/// The user's camera sensor overrides — tier (a) of the sensor-spec chain.
///
/// The values live in the `app_settings` row named by
/// [cameraOverridesSettingKey] and are written by the camera sensor specs
/// dialog. This service does two things with them: parse them, and decide
/// which one (if any) describes the camera in hand.
///
/// That decision is an EXACT normalised name match, never an approximate one.
/// The previous implementation matched on Levenshtein distance ≤ 3 plus a
/// six-character substring rule against a small built-in catalog, which
/// answered "ASI2400MC Pro" with the ASI2600MC's 3.76 µm pitch (the ASI2400 is
/// 5.94 µm) and "ASI183MM Pro" with the ASI533's (2.4 µm against 3.76 µm) —
/// silently, and into every image-scale and field-of-view figure in the app.
/// See [CameraSensorDatabase] for the same rule on the published database.
class HardwareSpecsService {
  static const cameraOverridesSettingKey =
      'smart_night.hardware.camera_overrides.v1';

  final List<CameraHardwareSpec> _cameraOverrides;

  const HardwareSpecsService({
    List<CameraHardwareSpec> cameraOverrides = const [],
  }) : _cameraOverrides = cameraOverrides;

  List<CameraHardwareSpec> get cameraOverrides =>
      List.unmodifiable(_cameraOverrides);

  HardwareSpecsService withCameraOverrides(
    List<CameraHardwareSpec> cameraOverrides,
  ) {
    return HardwareSpecsService(cameraOverrides: cameraOverrides);
  }

  static List<CameraHardwareSpec> cameraOverridesFromJson(Object? decoded) {
    if (decoded == null) return const [];
    if (decoded is! List) {
      throw const FormatException('Camera hardware overrides must be a list');
    }
    return decoded
        .map(
          (value) => CameraHardwareSpec.fromJson(
            (value as Map).cast<String, dynamic>(),
          ),
        )
        .toList();
  }

  /// The override that names this camera, or null.
  CameraHardwareSpec? overrideFor({String? cameraName, String? cameraId}) {
    final candidates = [cameraName, cameraId]
        .map(
          (value) => value == null ? '' : CameraSensorDatabase.normalize(value),
        )
        .where((value) => value.isNotEmpty);
    for (final candidate in candidates) {
      for (final spec in _cameraOverrides) {
        if (spec.matchKeys.contains(candidate)) return spec;
      }
    }
    return null;
  }

  /// The override for this camera in the shape the resolver consumes.
  UserSensorSpecOverrides overridesFor({
    String? cameraName,
    String? cameraId,
    int? gain,
  }) {
    final spec = overrideFor(cameraName: cameraName, cameraId: cameraId);
    if (spec == null) return UserSensorSpecOverrides.none;
    final point = spec.gainPointFor(gain ?? spec.defaultGain);
    return UserSensorSpecOverrides(
      pixelSizeMicrons: spec.pixelSizeMicrons,
      sensorWidthPx: spec.sensorWidthPx,
      sensorHeightPx: spec.sensorHeightPx,
      readNoiseE: point?.readNoiseE,
      fullWellE: point?.fullWellE,
      qePeakFraction: spec.qePeak,
    );
  }
}

String _stringValue(Object? value, String field) {
  if (value is String && value.trim().isNotEmpty) return value.trim();
  throw FormatException('Camera spec requires $field');
}

int _intValue(Object? value, String field) {
  final parsed = _optionalIntValue(value);
  if (parsed != null) return parsed;
  throw FormatException('Camera spec requires numeric $field');
}

int? _optionalIntValue(Object? value) {
  if (value is int) return value;
  if (value is num && value.isFinite) return value.round();
  if (value is String) return int.tryParse(value);
  return null;
}

double _doubleValue(Object? value, String field) {
  final parsed = _optionalDoubleValue(value);
  if (parsed != null) return parsed;
  throw FormatException('Camera spec requires numeric $field');
}

double? _optionalDoubleValue(Object? value) {
  if (value is num && value.isFinite) return value.toDouble();
  if (value is String) {
    final parsed = double.tryParse(value);
    if (parsed != null && parsed.isFinite) return parsed;
  }
  return null;
}
