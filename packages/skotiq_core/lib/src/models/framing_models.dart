import 'package:skotiq_astro/skotiq_astro.dart';

import 'target/target_models.dart';

class FramingTarget {
  final String name;
  final String? catalogId;
  final double raHours;
  final double decDegrees;
  final TargetType? type;

  /// Catalog subtype retained for filter selection (e.g. emission vs reflection).
  final String? objectType;
  final double? magnitude;
  final double? sizeArcmin;
  final String? constellation;

  const FramingTarget({
    required this.name,
    this.catalogId,
    required this.raHours,
    required this.decDegrees,
    this.type,
    this.objectType,
    this.magnitude,
    this.sizeArcmin,
    this.constellation,
  });

  double get raDegrees => raHours * 15;

  factory FramingTarget.fromCelestialTarget(CelestialTarget t) {
    return FramingTarget(
      name: t.name,
      catalogId: t.catalogId,
      raHours: t.raHours,
      decDegrees: t.decDegrees,
      type: t.objectType,
      magnitude: t.magnitude,
      sizeArcmin: t.sizeArcmin,
      constellation: t.constellation,
    );
  }

  /// Serializes this target for single-key settings persistence
  /// (`framing.lastTarget`). Used to remember the last framed target across
  /// app restarts WITHOUT writing a row into the `targets` library table.
  Map<String, dynamic> toJson() => {
    'name': name,
    if (catalogId != null) 'catalogId': catalogId,
    'raHours': raHours,
    'decDegrees': decDegrees,
    if (type != null) 'type': type!.name,
    if (objectType != null) 'objectType': objectType,
    if (magnitude != null) 'magnitude': magnitude,
    if (sizeArcmin != null) 'sizeArcmin': sizeArcmin,
    if (constellation != null) 'constellation': constellation,
  };

  /// Reconstructs a target previously written by [toJson]. Returns null when
  /// the payload is missing required fields so the caller can fail closed
  /// rather than fabricate a bogus target.
  static FramingTarget? fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    final raHours = (json['raHours'] as num?)?.toDouble();
    final decDegrees = (json['decDegrees'] as num?)?.toDouble();
    if (name is! String ||
        name.isEmpty ||
        raHours == null ||
        decDegrees == null) {
      return null;
    }
    final typeName = json['type'] as String?;
    return FramingTarget(
      name: name,
      catalogId: json['catalogId'] as String?,
      objectType: json['objectType'] as String?,
      // Backward-compat: older payloads may have stored RA in degrees.
      raHours: _normalizeRaHoursMaybeDegrees(raHours),
      decDegrees: decDegrees,
      type: typeName != null
          ? TargetType.values.firstWhere(
              (t) => t.name == typeName,
              orElse: () => TargetType.other,
            )
          : null,
      magnitude: (json['magnitude'] as num?)?.toDouble(),
      sizeArcmin: (json['sizeArcmin'] as num?)?.toDouble(),
      constellation: json['constellation'] as String?,
    );
  }
}

double _normalizeRaHoursMaybeDegrees(double ra) {
  if (ra.isNaN || ra.isInfinite) return ra;

  // Normal case: already in hours.
  if (ra >= 0.0 && ra < 24.0) return ra;

  // Legacy bug / external sources: treat as degrees and convert to hours.
  var deg = ra % 360.0;
  if (deg < 0.0) deg += 360.0;
  return deg / 15.0;
}

class FramingEquipment {
  final String cameraName;
  final double sensorWidthMm;
  final double sensorHeightMm;
  final double pixelSizeMicrons;
  final int pixelsX;
  final int pixelsY;

  final String telescopeName;
  final double focalLengthMm;
  final double apertureMm;

  final double focalReducer;

  const FramingEquipment({
    required this.cameraName,
    required this.sensorWidthMm,
    required this.sensorHeightMm,
    required this.pixelSizeMicrons,
    required this.pixelsX,
    required this.pixelsY,
    required this.telescopeName,
    required this.focalLengthMm,
    required this.apertureMm,
    this.focalReducer = 1.0,
  });

  double get effectiveFocalLength => focalLengthMm * focalReducer;

  (double, double) get _fovDegrees => FOVCalculator.calculateFOV(
    sensorWidthMm: sensorWidthMm,
    sensorHeightMm: sensorHeightMm,
    focalLengthMm: effectiveFocalLength,
  );

  /// FOV width in degrees
  double get fovWidthDeg => _fovDegrees.$1;

  /// FOV height in degrees
  double get fovHeightDeg => _fovDegrees.$2;

  /// Image scale in arcsec/pixel
  double get imageScale => FOVCalculator.calculateImageScale(
    pixelSizeMicrons: pixelSizeMicrons,
    focalLengthMm: effectiveFocalLength,
  );

  double get focalRatio => effectiveFocalLength / apertureMm;
}

enum SurveySource {
  dss2Red('DSS2 Red', 'DSS2R'),
  dss2Blue('DSS2 Blue', 'DSS2B'),
  dss2IR('DSS2 IR', 'DSS2IR'),
  sdss('SDSS Color', 'SDSSg'),
  twomassJ('2MASS J', '2MASSJ'),
  twomassH('2MASS H', '2MASSH'),
  twomassK('2MASS K', '2MASSK'),
  wise12('WISE 12μm', 'WISE12');

  final String displayName;
  final String surveyCode;

  const SurveySource(this.displayName, this.surveyCode);
}

/// Configuration for a mosaic pattern in the framing assistant.
///
/// Distinct from `MosaicConfig` in `services/mosaic_service.dart`, which
/// describes mosaic geometry in arcminutes/degrees for sequence generation.
/// This UI-facing version is grid-based (columns/rows/overlapPercent).
class FramingMosaicConfig {
  final int columns;

  final int rows;

  /// Overlap percentage between panels (0-50%)
  final double overlapPercent;

  /// Whether to use a serpentine (snake) capture pattern
  final bool serpentine;

  final MosaicStartCorner startCorner;

  /// Custom panel rotation for each panel (null = use global rotation)
  final double? panelRotation;

  const FramingMosaicConfig({
    this.columns = 2,
    this.rows = 2,
    this.overlapPercent = 15.0,
    this.serpentine = true,
    this.startCorner = MosaicStartCorner.topLeft,
    this.panelRotation,
  });

  FramingMosaicConfig copyWith({
    int? columns,
    int? rows,
    double? overlapPercent,
    bool? serpentine,
    MosaicStartCorner? startCorner,
    double? panelRotation,
  }) {
    return FramingMosaicConfig(
      columns: columns ?? this.columns,
      rows: rows ?? this.rows,
      overlapPercent: overlapPercent ?? this.overlapPercent,
      serpentine: serpentine ?? this.serpentine,
      startCorner: startCorner ?? this.startCorner,
      panelRotation: panelRotation ?? this.panelRotation,
    );
  }

  int get totalPanels => columns * rows;

  /// Effective FOV multiplier accounting for overlap
  double get effectiveWidthMultiplier =>
      columns - (columns - 1) * (overlapPercent / 100);
  double get effectiveHeightMultiplier =>
      rows - (rows - 1) * (overlapPercent / 100);
}

